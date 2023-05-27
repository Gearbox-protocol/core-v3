// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import "../../../interfaces/IAddressProviderV3.sol";
import {ACL} from "@gearbox-protocol/core-v2/contracts/core/ACL.sol";

import {AccountFactory} from "@gearbox-protocol/core-v2/contracts/core/AccountFactory.sol";
import {
    ICreditManagerV3,
    ICreditManagerV3Events,
    ClosureAction,
    CollateralTokenData,
    ManageDebtAction,
    CollateralCalcTask,
    CollateralDebtData
} from "../../../interfaces/ICreditManagerV3.sol";
import {IPoolQuotaKeeper, AccountQuota} from "../../../interfaces/IPoolQuotaKeeper.sol";
import {IPriceOracleV2, IPriceOracleV2Ext} from "@gearbox-protocol/core-v2/contracts/interfaces/IPriceOracle.sol";

import {CreditManagerV3} from "../../../credit/CreditManagerV3.sol";
import {UNDERLYING_TOKEN_MASK} from "../../../libraries/BitMask.sol";

import {IWETH} from "@gearbox-protocol/core-v2/contracts/interfaces/external/IWETH.sol";

import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/PercentageMath.sol";
import {CreditLogic} from "../../../libraries/CreditLogic.sol";

// TESTS
import "../../lib/constants.sol";

import {BalanceHelper} from "../../helpers/BalanceHelper.sol";

// MOCKS

import {PoolMock} from "../../mocks//pool/PoolMock.sol";
import {PoolQuotaKeeper} from "../../../pool/PoolQuotaKeeper.sol";

// SUITES
import {TokensTestSuite} from "../../suites/TokensTestSuite.sol";
import {Tokens} from "../../config/Tokens.sol";
import {CreditManagerTestSuite} from "../../suites/CreditManagerTestSuite.sol";

import {CreditConfig} from "../../config/CreditConfig.sol";

// EXCEPTIONS
import "../../../interfaces/IExceptions.sol";

contract CreditManagerQuotasTest is Test, ICreditManagerV3Events, BalanceHelper {
    using CreditLogic for CollateralDebtData;

    CreditManagerTestSuite cms;

    IAddressProviderV3 addressProvider;
    IWETH wethToken;

    AccountFactory af;
    CreditManagerV3 creditManager;
    PoolMock poolMock;
    PoolQuotaKeeper poolQuotaKeeper;
    IPriceOracleV2 priceOracle;
    ACL acl;
    address underlying;

    CreditConfig creditConfig;

    function setUp() public {
        tokenTestSuite = new TokensTestSuite();

        tokenTestSuite.topUpWETH{value: 100 * WAD}();
        _connectCreditManagerSuite(Tokens.DAI, false);
    }

    ///
    /// HELPERS

    function _connectCreditManagerSuite(Tokens t, bool internalSuite) internal {
        creditConfig = new CreditConfig(tokenTestSuite, t);
        cms = new CreditManagerTestSuite(creditConfig, internalSuite, true, 1);

        acl = cms.acl();

        addressProvider = cms.addressProvider();
        af = cms.af();

        poolMock = cms.poolMock();
        poolQuotaKeeper = cms.poolQuotaKeeper();

        creditManager = cms.creditManager();

        priceOracle = IPriceOracleV2(creditManager.priceOracle());
        underlying = creditManager.underlying();
    }

    function _addQuotedToken(address token, uint16 rate, uint96 limit) internal {
        cms.makeTokenQuoted(token, rate, limit);
    }

    // function _addManyLimitedTokens(uint256 numTokens, uint96 quota)
    //     internal
    //     returns (QuotaUpdate[] memory quotaChanges)
    // {
    //     quotaChanges = new QuotaUpdate[](numTokens);

    //     for (uint256 i = 0; i < numTokens; i++) {
    //         ERC20Mock t = new ERC20Mock("new token", "nt", 18);
    //         PriceFeedMock pf = new PriceFeedMock(10**8, 8);

    //         vm.startPrank(CONFIGURATOR);
    //         creditManager.addToken(address(t));
    //         IPriceOracleV2Ext(address(priceOracle)).addPriceFeed(address(t), address(pf));
    //         creditManager.setCollateralTokenData(address(t), 8000, 8000, type(uint40).max, 0);
    //         vm.stopPrank();

    //         _addQuotedToken(address(t), 100, type(uint96).max);

    //         quotaChanges[i] = QuotaUpdate({token: address(t), quotaChange: int96(quota)});
    //     }
    // }

    ///
    ///
    ///  TESTS
    ///
    ///

    /// @dev I:[CMQ-1]: constructor correctly sets supportsQuotas based on pool
    function test_I_CMQ_01_constructor_correctly_sets_quota_related_params() public {
        assertTrue(creditManager.supportsQuotas(), "Credit Manager does not support quotas");
    }

    /// @dev I:[CMQ-2]: setQuotedMask works correctly
    function test_I_CMQ_02_setQuotedMask_works_correctly() public {
        _addQuotedToken(tokenTestSuite.addressOf(Tokens.LINK), 10_00, uint96(1_000_000 * WAD));

        uint256 usdcMask = creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.USDC));
        uint256 linkMask = creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.LINK));

        uint256 quotedTokensMask = creditManager.quotedTokensMask();

        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditManager.setQuotedMask(quotedTokensMask | usdcMask);

        vm.prank(CONFIGURATOR);
        creditManager.setQuotedMask(quotedTokensMask | usdcMask);

        assertEq(creditManager.quotedTokensMask(), usdcMask | linkMask, "New limited mask is incorrect");
    }

    /// @dev I:[CMQ-3]: updateQuotas works correctly
    function test_I_CMQ_03_updateQuotas_works_correctly() public {
        _addQuotedToken(tokenTestSuite.addressOf(Tokens.LINK), 10_00, uint96(1_000_000 * WAD));
        _addQuotedToken(tokenTestSuite.addressOf(Tokens.USDT), 500, uint96(1_000_000 * WAD));

        (,,, address creditAccount) = cms.openCreditAccount();

        (,, uint256 cumulativeQuotaInterest,,,,,) = creditManager.creditAccountInfo(creditAccount);

        assertEq(cumulativeQuotaInterest, 1, "SETUP: Cumulative quota interest was not updated correctly");

        {
            address link = tokenTestSuite.addressOf(Tokens.LINK);
            vm.expectRevert(CallerNotCreditFacadeException.selector);
            vm.prank(FRIEND);
            creditManager.updateQuota({creditAccount: creditAccount, token: link, quotaChange: 100_000});
        }

        vm.expectCall(
            address(poolQuotaKeeper),
            abi.encodeCall(
                IPoolQuotaKeeper.updateQuota, (creditAccount, tokenTestSuite.addressOf(Tokens.LINK), 100_000)
            )
        );

        uint256 linkMask = creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.LINK));

        (uint256 tokensToEnable, uint256 tokensToDisable) = creditManager.updateQuota({
            creditAccount: creditAccount,
            token: tokenTestSuite.addressOf(Tokens.LINK),
            quotaChange: 100_000
        });

        assertEq(tokensToEnable, linkMask, "Incorrect tokensToEnble");
        assertEq(tokensToDisable, 0, "Incorrect tokensToDisable");

        vm.warp(block.timestamp + 365 days);

        (tokensToEnable, tokensToDisable) = creditManager.updateQuota({
            creditAccount: creditAccount,
            token: tokenTestSuite.addressOf(Tokens.LINK),
            quotaChange: -100_000
        });
        assertEq(tokensToEnable, 0, "Incorrect tokensToEnable");
        assertEq(tokensToDisable, linkMask, "Incorrect tokensToDisable");

        (,, cumulativeQuotaInterest,,,,,) = creditManager.creditAccountInfo(creditAccount);

        assertEq(
            cumulativeQuotaInterest,
            (100000 * 1000) / PERCENTAGE_FACTOR + 1,
            "Cumulative quota interest was not updated correctly"
        );

        {
            address usdc = tokenTestSuite.addressOf(Tokens.USDC);
            vm.expectRevert(TokenIsNotQuotedException.selector);
            creditManager.updateQuota({creditAccount: creditAccount, token: usdc, quotaChange: 100_000});
        }
    }

    /// @dev I:[CMQ-4]: Quotas are handled correctly on debt decrease: amount < quota interest case
    function test_I_CMQ_04_quotas_are_handled_correctly_at_repayment_partial_case() public {
        _addQuotedToken(tokenTestSuite.addressOf(Tokens.LINK), 10_00, uint96(1_000_000 * WAD));
        _addQuotedToken(tokenTestSuite.addressOf(Tokens.USDT), 500, uint96(1_000_000 * WAD));

        (,,, address creditAccount) = cms.openCreditAccount();
        tokenTestSuite.mint(Tokens.DAI, creditAccount, DAI_ACCOUNT_AMOUNT * 2);

        uint256 enabledTokensMask = UNDERLYING_TOKEN_MASK;

        (uint256 tokensToEnable,) = creditManager.updateQuota({
            creditAccount: creditAccount,
            token: tokenTestSuite.addressOf(Tokens.LINK),
            quotaChange: 100_000
        });

        enabledTokensMask |= tokensToEnable;

        (tokensToEnable,) = creditManager.updateQuota({
            creditAccount: creditAccount,
            token: tokenTestSuite.addressOf(Tokens.USDT),
            quotaChange: 200_000
        });

        enabledTokensMask |= tokensToEnable;

        creditManager.fullCollateralCheck(creditAccount, enabledTokensMask, new uint256[](0), 10_000);

        vm.warp(block.timestamp + 365 days);

        (uint16 feeInterest,,,,) = creditManager.fees();

        uint256 amountRepaid = 15000;

        uint256 expectedQuotaInterestRepaid = (amountRepaid * PERCENTAGE_FACTOR) / (PERCENTAGE_FACTOR + feeInterest);

        CollateralDebtData memory cdd1 =
            creditManager.calcDebtAndCollateral(creditAccount, CollateralCalcTask.DEBT_ONLY);

        creditManager.manageDebt(creditAccount, amountRepaid, enabledTokensMask, ManageDebtAction.DECREASE_DEBT);

        CollateralDebtData memory cdd2 =
            creditManager.calcDebtAndCollateral(creditAccount, CollateralCalcTask.DEBT_ONLY);

        assertEq(
            cdd1.accruedInterest, cdd2.accruedInterest + expectedQuotaInterestRepaid, "Interest updated incorrectly"
        );

        assertEq(
            cdd1.accruedFees, cdd2.accruedFees + amountRepaid - expectedQuotaInterestRepaid, "Fees updated incorrectly"
        );
    }

    /// @dev I:[CMQ-5]: Quotas are handled correctly on debt decrease: amount >= quota interest case
    function test_I_CMQ_05_quotas_are_handled_correctly_at_repayment_full_case() public {
        _addQuotedToken(tokenTestSuite.addressOf(Tokens.LINK), 1000, uint96(1_000_000 * WAD));
        _addQuotedToken(tokenTestSuite.addressOf(Tokens.USDT), 500, uint96(1_000_000 * WAD));

        (,,, address creditAccount) = cms.openCreditAccount();
        tokenTestSuite.mint(Tokens.DAI, creditAccount, DAI_ACCOUNT_AMOUNT * 2);

        uint256 enabledTokensMask = UNDERLYING_TOKEN_MASK;

        (uint256 tokensToEnable,) = creditManager.updateQuota({
            creditAccount: creditAccount,
            token: tokenTestSuite.addressOf(Tokens.LINK),
            quotaChange: 100_000
        });

        enabledTokensMask |= tokensToEnable;

        (tokensToEnable,) = creditManager.updateQuota({
            creditAccount: creditAccount,
            token: tokenTestSuite.addressOf(Tokens.USDT),
            quotaChange: 200_000
        });

        enabledTokensMask |= tokensToEnable;

        creditManager.fullCollateralCheck(creditAccount, enabledTokensMask, new uint256[](0), 10_000);

        vm.warp(block.timestamp + 365 days);

        uint256 amountRepaid = 35000;

        CollateralDebtData memory cdd1 =
            creditManager.calcDebtAndCollateral(creditAccount, CollateralCalcTask.DEBT_ONLY);

        creditManager.manageDebt(creditAccount, amountRepaid, enabledTokensMask, ManageDebtAction.DECREASE_DEBT);

        CollateralDebtData memory cdd2 =
            creditManager.calcDebtAndCollateral(creditAccount, CollateralCalcTask.DEBT_ONLY);

        assertEq(cdd2.cumulativeQuotaInterest, 0, "Interest updated incorrectly");

        assertEq(cdd1.calcTotalDebt(), cdd2.calcTotalDebt() + amountRepaid, "Total debt updated incorrectly");
    }

    /// @dev I:[CMQ-6]: Quotas are disabled on closing an account
    function test_I_CMQ_06_quotas_are_disabled_on_close_account_and_all_quota_fees_are_repaid() public {
        _addQuotedToken(tokenTestSuite.addressOf(Tokens.LINK), 10_00, uint96(1_000_000 * WAD));
        _addQuotedToken(tokenTestSuite.addressOf(Tokens.USDT), 5_00, uint96(1_000_000 * WAD));

        (
            uint256 borrowedAmount,
            uint256 cumulativeIndexLastUpdate,
            uint256 cumulativeIndexAtClose,
            address creditAccount
        ) = cms.openCreditAccount();

        tokenTestSuite.mint(Tokens.DAI, creditAccount, DAI_ACCOUNT_AMOUNT * 2);

        uint256 enabledTokensMask = UNDERLYING_TOKEN_MASK;
        (uint256 tokensToEnable,) = creditManager.updateQuota({
            creditAccount: creditAccount,
            token: tokenTestSuite.addressOf(Tokens.LINK),
            quotaChange: int96(uint96(100 * WAD))
        });
        enabledTokensMask |= tokensToEnable;

        (tokensToEnable,) = creditManager.updateQuota({
            creditAccount: creditAccount,
            token: tokenTestSuite.addressOf(Tokens.USDT),
            quotaChange: int96(uint96(200 * WAD))
        });
        enabledTokensMask |= tokensToEnable;

        creditManager.fullCollateralCheck(creditAccount, enabledTokensMask, new uint256[](0), 10_000);

        (uint16 feeInterest,,,,) = creditManager.fees();

        uint256 interestAccured = (borrowedAmount * cumulativeIndexAtClose / cumulativeIndexLastUpdate - borrowedAmount)
            * (PERCENTAGE_FACTOR + feeInterest) / PERCENTAGE_FACTOR;

        uint256 expectedQuotasInterest = (100 * WAD * 10_00 / PERCENTAGE_FACTOR + 200 * WAD * 5_00 / PERCENTAGE_FACTOR)
            * (PERCENTAGE_FACTOR + feeInterest) / PERCENTAGE_FACTOR;

        vm.warp(block.timestamp + 365 days);

        tokenTestSuite.mint(Tokens.DAI, creditAccount, borrowedAmount);

        uint256 poolBalanceBefore = tokenTestSuite.balanceOf(Tokens.DAI, address(poolMock));

        creditManager.closeCreditAccount(
            creditAccount,
            ClosureAction.CLOSE_ACCOUNT,
            creditManager.calcDebtAndCollateral(creditAccount, CollateralCalcTask.DEBT_ONLY),
            USER,
            USER,
            0,
            false
        );

        expectBalance(
            Tokens.DAI,
            address(poolMock),
            poolBalanceBefore + borrowedAmount + interestAccured + expectedQuotasInterest,
            "Incorrect pool balance"
        );

        (uint96 quota, uint192 cumulativeIndexLU) =
            poolQuotaKeeper.getQuota(creditAccount, tokenTestSuite.addressOf(Tokens.LINK));

        assertEq(uint256(quota), 1, "Quota was not set to 0");

        (quota, cumulativeIndexLU) = poolQuotaKeeper.getQuota(creditAccount, tokenTestSuite.addressOf(Tokens.USDT));
        assertEq(uint256(quota), 1, "Quota was not set to 0");
    }

    /// @dev I:[CMQ-07]: calcDebtAndCollateral correctly counts quota interest
    function test_I_CMQ_07_calcDebtAndCollateral_correctly_includes_quota_interest(uint96 quotaLink, uint96 quotaUsdt)
        public
    {
        _addQuotedToken(tokenTestSuite.addressOf(Tokens.LINK), 10_00, uint96(1_000_000 * WAD));
        _addQuotedToken(tokenTestSuite.addressOf(Tokens.USDT), 500, uint96(1_000_000 * WAD));

        (
            uint256 borrowedAmount,
            uint256 cumulativeIndexLastUpdate,
            uint256 cumulativeIndexAtClose,
            address creditAccount
        ) = cms.openCreditAccount();

        vm.assume(quotaLink < type(uint96).max / 2);
        vm.assume(quotaUsdt < type(uint96).max / 2);

        tokenTestSuite.mint(Tokens.DAI, creditAccount, DAI_ACCOUNT_AMOUNT * 2);

        uint256 enabledTokensMask = UNDERLYING_TOKEN_MASK;
        (uint256 tokensToEnable,) = creditManager.updateQuota({
            creditAccount: creditAccount,
            token: tokenTestSuite.addressOf(Tokens.LINK),
            quotaChange: int96(quotaLink)
        });
        enabledTokensMask |= tokensToEnable;

        (tokensToEnable,) = creditManager.updateQuota({
            creditAccount: creditAccount,
            token: tokenTestSuite.addressOf(Tokens.USDT),
            quotaChange: int96(quotaUsdt)
        });
        enabledTokensMask |= tokensToEnable;

        creditManager.fullCollateralCheck(creditAccount, enabledTokensMask, new uint256[](0), 10_000);

        vm.warp(block.timestamp + 60 * 60 * 24 * 365);

        (uint16 feeInterest,,,,) = creditManager.fees();

        quotaLink = quotaLink > uint96(1_000_000 * WAD) ? uint96(1_000_000 * WAD) : quotaLink;
        quotaUsdt = quotaUsdt > uint96(1_000_000 * WAD) ? uint96(1_000_000 * WAD) : quotaUsdt;

        uint256 expectedTotalDebt = (borrowedAmount * cumulativeIndexAtClose) / cumulativeIndexLastUpdate;
        expectedTotalDebt += (quotaLink * 1000) / PERCENTAGE_FACTOR;
        expectedTotalDebt += (quotaUsdt * 500) / PERCENTAGE_FACTOR;
        expectedTotalDebt += (expectedTotalDebt - borrowedAmount) * feeInterest / PERCENTAGE_FACTOR;

        CollateralDebtData memory cdd1 =
            creditManager.calcDebtAndCollateral(creditAccount, CollateralCalcTask.DEBT_ONLY);

        uint256 diff = cdd1.calcTotalDebt() > expectedTotalDebt
            ? cdd1.calcTotalDebt() - expectedTotalDebt
            : expectedTotalDebt - cdd1.calcTotalDebt();

        emit log_uint(expectedTotalDebt);
        emit log_uint(cdd1.calcTotalDebt());

        assertLe(diff, 1, "Total debt updated incorrectly");
    }

    /// @dev I:[CMQ-08]: Credit Manager zeroes limits on quoted tokens upon incurring a loss
    function test_I_CMQ_08_creditManager_triggers_limit_zeroing_on_loss() public {
        _addQuotedToken(tokenTestSuite.addressOf(Tokens.LINK), 10_00, uint96(1_000_000 * WAD));
        _addQuotedToken(tokenTestSuite.addressOf(Tokens.USDT), 500, uint96(1_000_000 * WAD));

        (,,, address creditAccount) = cms.openCreditAccount();

        tokenTestSuite.mint(Tokens.DAI, creditAccount, DAI_ACCOUNT_AMOUNT * 2);

        uint256 enabledTokensMap = UNDERLYING_TOKEN_MASK;

        (uint256 tokensToEnable,) = creditManager.updateQuota({
            creditAccount: creditAccount,
            token: tokenTestSuite.addressOf(Tokens.LINK),
            quotaChange: int96(uint96(100 * WAD))
        });
        enabledTokensMap |= tokensToEnable;

        (tokensToEnable,) = creditManager.updateQuota({
            creditAccount: creditAccount,
            token: tokenTestSuite.addressOf(Tokens.USDT),
            quotaChange: int96(uint96(200 * WAD))
        });
        enabledTokensMap |= tokensToEnable;

        creditManager.fullCollateralCheck(creditAccount, enabledTokensMap, new uint256[](0), 10_000);

        address[] memory quotedTokens = new address[](creditManager.maxEnabledTokens());

        quotedTokens[0] = tokenTestSuite.addressOf(Tokens.USDT);
        quotedTokens[1] = tokenTestSuite.addressOf(Tokens.LINK);

        CollateralDebtData memory cdd =
            creditManager.calcDebtAndCollateral(creditAccount, CollateralCalcTask.DEBT_COLLATERAL_CANCEL_WITHDRAWALS);
        cdd.totalValue = 0;

        vm.expectCall(
            address(poolQuotaKeeper), abi.encodeCall(IPoolQuotaKeeper.removeQuotas, (creditAccount, quotedTokens, true))
        );

        creditManager.closeCreditAccount(creditAccount, ClosureAction.LIQUIDATE_ACCOUNT, cdd, USER, USER, 0, false);

        for (uint256 i = 0; i < quotedTokens.length; ++i) {
            if (quotedTokens[i] == address(0)) continue;

            (, uint96 limit,,) = poolQuotaKeeper.totalQuotaParams(quotedTokens[i]);

            assertEq(limit, 1, "Limit was not zeroed");
        }
    }
}
