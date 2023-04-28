// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.10;

import {IAddressProvider} from "@gearbox-protocol/core-v2/contracts/interfaces/IAddressProvider.sol";
import {ACL} from "@gearbox-protocol/core-v2/contracts/core/ACL.sol";

import {AccountFactory} from "@gearbox-protocol/core-v2/contracts/core/AccountFactory.sol";
import {ICreditAccount} from "@gearbox-protocol/core-v2/contracts/interfaces/ICreditAccount.sol";
import {
    ICreditManagerV3,
    ICreditManagerV3Events,
    ClosureAction,
    CollateralTokenData,
    ManageDebtAction
} from "../../../interfaces/ICreditManagerV3.sol";
import {IPoolQuotaKeeper, QuotaUpdate, TokenLT, AccountQuota} from "../../../interfaces/IPoolQuotaKeeper.sol";
import {IPriceOracleV2, IPriceOracleV2Ext} from "@gearbox-protocol/core-v2/contracts/interfaces/IPriceOracle.sol";

import {CreditManagerV3} from "../../../credit/CreditManagerV3.sol";

import {IPoolService} from "@gearbox-protocol/core-v2/contracts/interfaces/IPoolService.sol";

import {IWETH} from "@gearbox-protocol/core-v2/contracts/interfaces/external/IWETH.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "@gearbox-protocol/core-v2/contracts/test/mocks/token/ERC20Mock.sol";
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/PercentageMath.sol";

// TESTS
import "../../lib/constants.sol";

import {BalanceHelper} from "../../helpers/BalanceHelper.sol";

// MOCKS
import {PriceFeedMock} from "@gearbox-protocol/core-v2/contracts/test/mocks/oracles/PriceFeedMock.sol";
import {PoolServiceMock} from "../../mocks/pool/PoolServiceMock.sol";
import {PoolQuotaKeeper} from "../../../pool/PoolQuotaKeeper.sol";
import {TargetContractMock} from "@gearbox-protocol/core-v2/contracts/test/mocks/adapters/TargetContractMock.sol";

// SUITES
import {TokensTestSuite} from "../../suites/TokensTestSuite.sol";
import {Tokens} from "../../config/Tokens.sol";
import {CreditManagerTestSuite} from "../../suites/CreditManagerTestSuite.sol";
import {CreditManagerTestInternal} from "../../mocks/credit/CreditManagerTestInternal.sol";

import {CreditConfig} from "../../config/CreditConfig.sol";

// EXCEPTIONS
import "../../../interfaces/IExceptions.sol";

import "forge-std/console.sol";

contract CreditManagerQuotasTest is DSTest, ICreditManagerV3Events, BalanceHelper {
    CheatCodes evm = CheatCodes(HEVM_ADDRESS);

    CreditManagerTestSuite cms;

    IAddressProvider addressProvider;
    IWETH wethToken;

    AccountFactory af;
    CreditManagerV3 creditManager;
    PoolServiceMock poolMock;
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
        cms = new CreditManagerTestSuite(creditConfig, internalSuite, true);

        acl = cms.acl();

        addressProvider = cms.addressProvider();
        af = cms.af();

        poolMock = cms.poolMock();
        poolQuotaKeeper = cms.poolQuotaKeeper();

        creditManager = cms.creditManager();

        priceOracle = creditManager.priceOracle();
        underlying = creditManager.underlying();
    }

    function _addQuotedToken(address token, uint16 rate, uint96 limit) internal {
        cms.makeTokenLimited(token, rate, limit);
    }

    function _addManyLimitedTokens(uint256 numTokens, uint96 quota)
        internal
        returns (QuotaUpdate[] memory quotaChanges)
    {
        quotaChanges = new QuotaUpdate[](numTokens);

        for (uint256 i = 0; i < numTokens; i++) {
            ERC20Mock t = new ERC20Mock("new token", "nt", 18);
            PriceFeedMock pf = new PriceFeedMock(10**8, 8);

            evm.startPrank(CONFIGURATOR);
            creditManager.addToken(address(t));
            IPriceOracleV2Ext(address(priceOracle)).addPriceFeed(address(t), address(pf));
            creditManager.setLiquidationThreshold(address(t), 8000);
            evm.stopPrank();

            _addQuotedToken(address(t), 100, type(uint96).max);

            quotaChanges[i] = QuotaUpdate({token: address(t), quotaChange: int96(quota)});
        }
    }

    ///
    ///
    ///  TESTS
    ///
    ///

    /// @dev [CMQ-1]: constructor correctly sets supportsQuotas based on pool
    function test_CMQ_01_constructor_correctly_sets_quota_related_params() public {
        assertTrue(creditManager.supportsQuotas(), "Credit Manager does not support quotas");
    }

    /// @dev [CMQ-2]: setQuotedMask works correctly
    function test_CMQ_02_setQuotedMask_works_correctly() public {
        _addQuotedToken(tokenTestSuite.addressOf(Tokens.LINK), 10_00, uint96(1_000_000 * WAD));

        uint256 usdcMask = creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.USDC));
        uint256 linkMask = creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.LINK));

        uint256 quotedTokenMask = creditManager.quotedTokenMask();

        evm.expectRevert(CallerNotConfiguratorException.selector);
        creditManager.setQuotedMask(quotedTokenMask | usdcMask);

        evm.prank(CONFIGURATOR);
        creditManager.setQuotedMask(quotedTokenMask | usdcMask);

        assertEq(creditManager.quotedTokenMask(), usdcMask | linkMask, "New limited mask is incorrect");
    }

    /// @dev [CMQ-3]: updateQuotas works correctly
    function test_CMQ_03_updateQuotas_works_correctly() public {
        _addQuotedToken(tokenTestSuite.addressOf(Tokens.LINK), 10_00, uint96(1_000_000 * WAD));
        _addQuotedToken(tokenTestSuite.addressOf(Tokens.USDT), 500, uint96(1_000_000 * WAD));

        (,,, address creditAccount) = cms.openCreditAccount();

        assertEq(
            creditManager.cumulativeQuotaInterest(creditAccount),
            1,
            "SETUP: Cumulative quota interest was not updated correctly"
        );

        QuotaUpdate[] memory quotaUpdates = new QuotaUpdate[](2);
        quotaUpdates[0] = QuotaUpdate({token: tokenTestSuite.addressOf(Tokens.LINK), quotaChange: 100_000});
        quotaUpdates[1] = QuotaUpdate({token: tokenTestSuite.addressOf(Tokens.USDT), quotaChange: 200_000});

        evm.expectRevert(CallerNotCreditFacadeException.selector);
        evm.prank(FRIEND);
        creditManager.updateQuotas(creditAccount, quotaUpdates);

        evm.expectCall(
            address(poolQuotaKeeper), abi.encodeCall(IPoolQuotaKeeper.updateQuotas, (creditAccount, quotaUpdates))
        );

        uint256 linkMask = creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.LINK));
        uint256 usdtMask = creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.USDT));

        (uint256 tokensToEnable, uint256 tokensToDisable) = creditManager.updateQuotas(creditAccount, quotaUpdates);

        assertEq(tokensToEnable, linkMask | usdtMask, "Incorrect tokensToEnble");
        assertEq(tokensToDisable, 0, "Incorrect tokensToDisable");
        // expectTokenIsEnabled(creditAccount, Tokens.LINK, true);
        // expectTokenIsEnabled(creditAccount, Tokens.USDT, true);

        evm.warp(block.timestamp + 365 days);

        quotaUpdates[0] = QuotaUpdate({token: tokenTestSuite.addressOf(Tokens.LINK), quotaChange: -100_000});
        quotaUpdates[1] = QuotaUpdate({token: tokenTestSuite.addressOf(Tokens.USDT), quotaChange: -100_000});

        (tokensToEnable, tokensToDisable) = creditManager.updateQuotas(creditAccount, quotaUpdates);

        // expectTokenIsEnabled(creditAccount, Tokens.LINK, false);
        // expectTokenIsEnabled(creditAccount, Tokens.USDT, true);

        assertEq(tokensToEnable, 0, "Incorrect tokensToEnable");
        assertEq(tokensToDisable, linkMask, "Incorrect tokensToDisable");

        assertEq(
            creditManager.cumulativeQuotaInterest(creditAccount),
            (100000 * 1000 + 200000 * 500) / PERCENTAGE_FACTOR + 1,
            "Cumulative quota interest was not updated correctly"
        );

        quotaUpdates[0] = QuotaUpdate({token: tokenTestSuite.addressOf(Tokens.USDC), quotaChange: -100000});

        evm.expectRevert(TokenIsNotQuotedException.selector);
        creditManager.updateQuotas(creditAccount, quotaUpdates);
    }

    /// @dev [CMQ-4]: Quotas are handled correctly on debt decrease: amount < quota interest case
    function test_CMQ_04_quotas_are_handled_correctly_at_repayment_partial_case() public {
        _addQuotedToken(tokenTestSuite.addressOf(Tokens.LINK), 10_00, uint96(1_000_000 * WAD));
        _addQuotedToken(tokenTestSuite.addressOf(Tokens.USDT), 500, uint96(1_000_000 * WAD));

        (,,, address creditAccount) = cms.openCreditAccount();
        tokenTestSuite.mint(Tokens.DAI, creditAccount, DAI_ACCOUNT_AMOUNT * 2);

        QuotaUpdate[] memory quotaUpdates = new QuotaUpdate[](2);
        quotaUpdates[0] =
            QuotaUpdate({token: tokenTestSuite.addressOf(Tokens.LINK), quotaChange: int96(uint96(100 * WAD))});
        quotaUpdates[1] =
            QuotaUpdate({token: tokenTestSuite.addressOf(Tokens.USDT), quotaChange: int96(uint96(200 * WAD))});

        evm.expectCall(
            address(poolQuotaKeeper), abi.encodeCall(IPoolQuotaKeeper.updateQuotas, (creditAccount, quotaUpdates))
        );

        (uint256 tokensToEnable,) = creditManager.updateQuotas(creditAccount, quotaUpdates);

        /// We use fullCollateralCheck to update enabledTokenMask

        creditManager.fullCollateralCheck(
            creditAccount, tokensToEnable | UNDERLYING_TOKEN_MASK, new uint256[](0), 10_000
        );

        evm.warp(block.timestamp + 365 days);

        (uint16 feeInterest,,,,) = creditManager.fees();

        uint256 amountRepaid = (PERCENTAGE_FACTOR + feeInterest) * WAD / 1_000;

        uint256 expectedQuotaInterestRepaid = (amountRepaid * PERCENTAGE_FACTOR) / (PERCENTAGE_FACTOR + feeInterest);

        (, uint256 totalDebtBefore, uint256 totalDebtBeforeFee) =
            creditManager.calcCreditAccountAccruedInterest(creditAccount);

        creditManager.manageDebt(
            creditAccount, amountRepaid, tokensToEnable | UNDERLYING_TOKEN_MASK, ManageDebtAction.DECREASE_DEBT
        );

        console.log("CU: ", creditManager.cumulativeQuotaInterest(creditAccount));

        // assertEq(
        //     creditManager.cumulativeQuotaInterest(creditAccount),
        //     20 * WAD - expectedQuotaInterestRepaid,
        //     "Cumulative quota interest was not updated correctly"
        // );

        (, uint256 totalDebtAfter, uint256 totalDebtAfterFee) =
            creditManager.calcCreditAccountAccruedInterest(creditAccount);

        assertEq(totalDebtAfter, totalDebtBefore - expectedQuotaInterestRepaid, "Debt updated incorrectly");

        assertEq(totalDebtAfterFee, totalDebtBeforeFee - amountRepaid, "Debt updated incorrectly");
    }

    /// @dev [CMQ-5]: Quotas are handled correctly on debt decrease: amount >= quota interest case
    function test_CMQ_05_quotas_are_handled_correctly_at_repayment_full_case() public {
        _addQuotedToken(tokenTestSuite.addressOf(Tokens.LINK), 1000, uint96(1_000_000 * WAD));
        _addQuotedToken(tokenTestSuite.addressOf(Tokens.USDT), 500, uint96(1_000_000 * WAD));

        (,,, address creditAccount) = cms.openCreditAccount();
        tokenTestSuite.mint(Tokens.DAI, creditAccount, DAI_ACCOUNT_AMOUNT * 2);

        QuotaUpdate[] memory quotaUpdates = new QuotaUpdate[](2);
        quotaUpdates[0] =
            QuotaUpdate({token: tokenTestSuite.addressOf(Tokens.LINK), quotaChange: int96(uint96(100 * WAD))});
        quotaUpdates[1] =
            QuotaUpdate({token: tokenTestSuite.addressOf(Tokens.USDT), quotaChange: int96(uint96(200 * WAD))});

        evm.expectCall(
            address(poolQuotaKeeper), abi.encodeCall(IPoolQuotaKeeper.updateQuotas, (creditAccount, quotaUpdates))
        );

        (uint256 tokensToEnable,) = creditManager.updateQuotas(creditAccount, quotaUpdates);

        creditManager.fullCollateralCheck(
            creditAccount, tokensToEnable | UNDERLYING_TOKEN_MASK, new uint256[](0), 10_000
        );

        evm.warp(block.timestamp + 365 days);

        uint256 amountRepaid = 35 * WAD;

        (,, uint256 totalDebtBefore) = creditManager.calcCreditAccountAccruedInterest(creditAccount);

        creditManager.manageDebt(
            creditAccount, amountRepaid, tokensToEnable | UNDERLYING_TOKEN_MASK, ManageDebtAction.DECREASE_DEBT
        );

        assertEq(
            creditManager.cumulativeQuotaInterest(creditAccount),
            1,
            "Cumulative quota interest was not updated correctly"
        );

        (,, uint256 totalDebtAfter) = creditManager.calcCreditAccountAccruedInterest(creditAccount);

        assertEq(totalDebtAfter, totalDebtBefore - amountRepaid, "Debt updated incorrectly");
    }

    /// @dev [CMQ-6]: Quotas are disabled on closing an account
    function test_CMQ_06_quotas_are_disabled_on_close_account_and_all_quota_fees_are_repaid() public {
        _addQuotedToken(tokenTestSuite.addressOf(Tokens.LINK), 10_00, uint96(1_000_000 * WAD));
        _addQuotedToken(tokenTestSuite.addressOf(Tokens.USDT), 5_00, uint96(1_000_000 * WAD));

        (uint256 borrowedAmount, uint256 cumulativeIndexAtOpen, uint256 cumulativeIndexAtClose, address creditAccount) =
            cms.openCreditAccount();

        tokenTestSuite.mint(Tokens.DAI, creditAccount, DAI_ACCOUNT_AMOUNT * 2);

        QuotaUpdate[] memory quotaUpdates = new QuotaUpdate[](2);
        quotaUpdates[0] =
            QuotaUpdate({token: tokenTestSuite.addressOf(Tokens.LINK), quotaChange: int96(uint96(100 * WAD))});
        quotaUpdates[1] =
            QuotaUpdate({token: tokenTestSuite.addressOf(Tokens.USDT), quotaChange: int96(uint96(200 * WAD))});

        evm.expectCall(
            address(poolQuotaKeeper), abi.encodeCall(IPoolQuotaKeeper.updateQuotas, (creditAccount, quotaUpdates))
        );

        (uint256 tokensToEnable,) = creditManager.updateQuotas(creditAccount, quotaUpdates);

        creditManager.fullCollateralCheck(
            creditAccount, tokensToEnable | UNDERLYING_TOKEN_MASK, new uint256[](0), 10_000
        );

        (uint16 feeInterest,,,,) = creditManager.fees();

        uint256 interestAccured = (borrowedAmount * cumulativeIndexAtClose / cumulativeIndexAtOpen - borrowedAmount)
            * (PERCENTAGE_FACTOR + feeInterest) / PERCENTAGE_FACTOR;

        uint256 expectedQuotasInterest = (100 * WAD * 10_00 / PERCENTAGE_FACTOR + 200 * WAD * 5_00 / PERCENTAGE_FACTOR)
            * (PERCENTAGE_FACTOR + feeInterest) / PERCENTAGE_FACTOR;

        evm.warp(block.timestamp + 365 days);

        tokenTestSuite.mint(Tokens.DAI, creditAccount, borrowedAmount);

        uint256 poolBalanceBefore = tokenTestSuite.balanceOf(Tokens.DAI, address(poolMock));

        ///       address borrower,
        // ClosureAction closureActionType,
        // uint256 totalValue,
        // address payer,
        // address to,
        // uint256 enabledTokenMask,
        // uint256 skipTokensMask,
        // uint256 borrowedAmountWithInterest,
        // bool convertWETH

        (, uint256 borrowedAmountWithInterest,) = creditManager.calcCreditAccountAccruedInterest(creditAccount);

        creditManager.closeCreditAccount(
            USER,
            ClosureAction.CLOSE_ACCOUNT,
            0,
            USER,
            USER,
            tokensToEnable | UNDERLYING_TOKEN_MASK,
            0,
            borrowedAmountWithInterest,
            false
        );

        expectBalance(
            Tokens.DAI,
            address(poolMock),
            poolBalanceBefore + borrowedAmount + interestAccured + expectedQuotasInterest,
            "Incorrect pool balance"
        );

        AccountQuota memory quota =
            poolQuotaKeeper.getQuota(address(creditManager), creditAccount, tokenTestSuite.addressOf(Tokens.LINK));

        assertEq(uint256(quota.quota), 1, "Quota was not set to 0");
        // assertEq(uint256(quota.cumulativeIndexLU), 0, "Cumulative index was not updated");

        quota = poolQuotaKeeper.getQuota(address(creditManager), creditAccount, tokenTestSuite.addressOf(Tokens.USDT));
        assertEq(uint256(quota.quota), 1, "Quota was not set to 0");
        // assertEq(uint256(quota.cumulativeIndexLU), 0, "Cumulative index was not updated");
    }

    // /// @dev [CMQ-7] enableToken, disableToken and changeEnabledTokens do nothing for limited tokens
    // function test_CMQ_07_enable_disable_changeEnabled_do_nothing_for_limited_tokens() public {
    //     _addQuotedToken(tokenTestSuite.addressOf(Tokens.LINK), 10_00, uint96(1_000_000 * WAD));
    //     (,,, address creditAccount) = cms.openCreditAccount();
    //     creditManager.transferAccountOwnership(USER, address(this));

    //     // creditManager.checkAndEnableToken(tokenTestSuite.addressOf(Tokens.LINK));
    //     expectTokenIsEnabled(creditAccount, Tokens.LINK, false);

    //     creditManager.changeEnabledTokens(creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.LINK)), 0);
    //     expectTokenIsEnabled(creditAccount, Tokens.LINK, false);

    //     QuotaUpdate[] memory quotaUpdates = new QuotaUpdate[](1);
    //     quotaUpdates[0] =
    //         QuotaUpdate({token: tokenTestSuite.addressOf(Tokens.LINK), quotaChange: int96(uint96(100 * WAD))});

    //     creditManager.updateQuotas(creditAccount, quotaUpdates);

    //     creditManager.disableToken(tokenTestSuite.addressOf(Tokens.LINK));
    //     expectTokenIsEnabled(creditAccount, Tokens.LINK, true);

    //     creditManager.changeEnabledTokens(0, creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.LINK)));
    //     expectTokenIsEnabled(creditAccount, Tokens.LINK, true);
    // }

    /// @dev [CMQ-8]: fullCollateralCheck fuzzing test with quotas
    function test_CMQ_08_fullCollateralCheck_fuzzing_test_quotas(
        uint128 borrowedAmount,
        uint128 daiBalance,
        uint128 usdcBalance,
        uint128 linkBalance,
        uint128 wethBalance,
        uint96 usdcQuota,
        uint96 linkQuota,
        bool enableWETH,
        uint16 minHealthFactor
    ) public {
        _connectCreditManagerSuite(Tokens.DAI, true);

        _addQuotedToken(tokenTestSuite.addressOf(Tokens.LINK), 10_00, uint96(1_000_000 * WAD));
        _addQuotedToken(tokenTestSuite.addressOf(Tokens.USDC), 500, uint96(1_000_000 * WAD));

        evm.assume(borrowedAmount > WAD);
        evm.assume(usdcQuota < type(uint96).max / 2);
        evm.assume(linkQuota < type(uint96).max / 2);
        evm.assume(minHealthFactor >= 10_000);

        console.log("ba", borrowedAmount);
        // uint128 daiBalance,
        // uint128 usdcBalance,
        // uint128 linkBalance,
        // uint128 wethBalance,
        // uint96 usdcQuota,
        // uint96 linkQuota,
        // bool enableWETH,
        // uint16 minHealthFactor)

        tokenTestSuite.mint(Tokens.DAI, address(poolMock), borrowedAmount);

        (,,, address creditAccount) = cms.openCreditAccount(borrowedAmount);
        creditManager.transferAccountOwnership(USER, address(this));

        if (daiBalance > borrowedAmount) {
            tokenTestSuite.mint(Tokens.DAI, creditAccount, daiBalance - borrowedAmount);
        } else {
            tokenTestSuite.burn(Tokens.DAI, creditAccount, borrowedAmount - daiBalance);
        }

        expectBalance(Tokens.DAI, creditAccount, daiBalance);

        uint256 tokensToEnable;

        {
            QuotaUpdate[] memory quotaUpdates = new QuotaUpdate[](2);
            quotaUpdates[0] =
                QuotaUpdate({token: tokenTestSuite.addressOf(Tokens.LINK), quotaChange: int96(uint96(linkQuota))});
            quotaUpdates[1] =
                QuotaUpdate({token: tokenTestSuite.addressOf(Tokens.USDC), quotaChange: int96(uint96(usdcQuota))});

            (tokensToEnable,) = creditManager.updateQuotas(creditAccount, quotaUpdates);
        }

        uint256 enabledTokensMap = tokensToEnable | UNDERLYING_TOKEN_MASK;
        if (enableWETH) {
            enabledTokensMap |= creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.WETH));
        }

        CreditManagerTestInternal(address(creditManager)).setEnabledTokenMask(creditAccount, enabledTokensMap);

        tokenTestSuite.mint(Tokens.WETH, creditAccount, wethBalance);
        tokenTestSuite.mint(Tokens.USDC, creditAccount, usdcBalance);
        tokenTestSuite.mint(Tokens.LINK, creditAccount, linkBalance);

        uint256 twvUSD = (
            tokenTestSuite.balanceOf(Tokens.DAI, creditAccount) * tokenTestSuite.prices(Tokens.DAI)
                * creditConfig.lt(Tokens.DAI)
        ) / WAD;

        {
            uint256 valueUsdc =
                (tokenTestSuite.balanceOf(Tokens.USDC, creditAccount) * tokenTestSuite.prices(Tokens.USDC)) / (10 ** 6);

            uint256 quotaUsdc = usdcQuota > 1_000_000 * WAD ? 1_000_000 * WAD : usdcQuota;

            quotaUsdc = (quotaUsdc * tokenTestSuite.prices(Tokens.DAI)) / WAD;

            uint256 tvIncrease = valueUsdc < quotaUsdc ? valueUsdc : quotaUsdc;

            twvUSD += tvIncrease * creditConfig.lt(Tokens.USDC);
        }

        {
            uint256 valueLink =
                (tokenTestSuite.balanceOf(Tokens.LINK, creditAccount) * tokenTestSuite.prices(Tokens.LINK)) / WAD;

            uint256 quotaLink = linkQuota > 1_000_000 * WAD ? 1_000_000 * WAD : linkQuota;

            quotaLink = (quotaLink * tokenTestSuite.prices(Tokens.DAI)) / WAD;

            uint256 tvIncrease = valueLink < quotaLink ? valueLink : quotaLink;

            twvUSD += tvIncrease * creditConfig.lt(Tokens.LINK);
        }

        twvUSD += !enableWETH
            ? 0
            : (
                tokenTestSuite.balanceOf(Tokens.WETH, creditAccount) * tokenTestSuite.prices(Tokens.WETH)
                    * creditConfig.lt(Tokens.WETH)
            ) / WAD;

        (,, uint256 borrowedAmountWithInterestAndFees) = creditManager.calcCreditAccountAccruedInterest(creditAccount);

        uint256 debtUSD = (borrowedAmountWithInterestAndFees * minHealthFactor * tokenTestSuite.prices(Tokens.DAI))
            / PERCENTAGE_FACTOR / WAD;

        twvUSD /= PERCENTAGE_FACTOR;

        bool shouldRevert = twvUSD < debtUSD;

        if (shouldRevert) {
            evm.expectRevert(NotEnoughCollateralException.selector);
        }

        creditManager.fullCollateralCheck(creditAccount, enabledTokensMap, new uint256[](0), minHealthFactor);
    }

    /// @dev [CMQ-9]: fullCollateralCheck does not check non-limited tokens if limited are enough to cover debt
    function test_CMQ_09_fullCollateralCheck_skips_normal_tokens_if_limited_tokens_cover_debt() public {
        _addQuotedToken(tokenTestSuite.addressOf(Tokens.LINK), 10_00, uint96(1_000_000 * WAD));
        _addQuotedToken(tokenTestSuite.addressOf(Tokens.USDC), 500, uint96(1_000_000 * WAD));

        tokenTestSuite.mint(Tokens.DAI, address(poolMock), 1_250_000 * WAD);

        (,,, address creditAccount) = cms.openCreditAccount(1_250_000 * WAD);
        creditManager.transferAccountOwnership(USER, address(this));

        uint256 tokenToEnable;

        {
            QuotaUpdate[] memory quotaUpdates = new QuotaUpdate[](2);
            quotaUpdates[0] =
                QuotaUpdate({token: tokenTestSuite.addressOf(Tokens.LINK), quotaChange: int96(uint96(1_000_000 * WAD))});
            quotaUpdates[1] =
                QuotaUpdate({token: tokenTestSuite.addressOf(Tokens.USDC), quotaChange: int96(uint96(1_000_000 * WAD))});

            (tokenToEnable,) = creditManager.updateQuotas(creditAccount, quotaUpdates);
        }

        tokenTestSuite.mint(Tokens.USDC, creditAccount, RAY);
        tokenTestSuite.mint(Tokens.LINK, creditAccount, RAY);

        evm.prank(CONFIGURATOR);
        creditManager.addToken(DUMB_ADDRESS);

        // creditManager.checkAndEnableToken(DUMB_ADDRESS);

        uint256 revertMask = creditManager.getTokenMaskOrRevert(DUMB_ADDRESS);

        uint256[] memory collateralHints = new uint256[](1);
        collateralHints[0] = revertMask;

        uint256 enableTokenMask = tokenToEnable | revertMask | UNDERLYING_TOKEN_MASK;

        creditManager.fullCollateralCheck(creditAccount, enableTokenMask, collateralHints, 10000);
    }

    /// @dev [CMQ-10]: calcCreditAccountAccruedInterest correctly counts quota interest
    function test_CMQ_10_calcCreditAccountAccruedInterest_correctly_includes_quota_interest(
        uint96 quotaLink,
        uint96 quotaUsdt
    ) public {
        _connectCreditManagerSuite(Tokens.DAI, true);

        _addQuotedToken(tokenTestSuite.addressOf(Tokens.LINK), 10_00, uint96(1_000_000 * WAD));
        _addQuotedToken(tokenTestSuite.addressOf(Tokens.USDT), 500, uint96(1_000_000 * WAD));

        (uint256 borrowedAmount, uint256 cumulativeIndexAtOpen, uint256 cumulativeIndexAtClose, address creditAccount) =
            cms.openCreditAccount();

        evm.assume(quotaLink < type(uint96).max / 2);
        evm.assume(quotaUsdt < type(uint96).max / 2);

        QuotaUpdate[] memory quotaUpdates = new QuotaUpdate[](2);
        quotaUpdates[0] =
            QuotaUpdate({token: tokenTestSuite.addressOf(Tokens.LINK), quotaChange: int96(uint96(quotaLink))});
        quotaUpdates[1] =
            QuotaUpdate({token: tokenTestSuite.addressOf(Tokens.USDT), quotaChange: int96(uint96(quotaUsdt))});

        quotaLink = quotaLink > 1_000_000 * WAD ? uint96(1_000_000 * WAD) : quotaLink;
        quotaUsdt = quotaUsdt > 1_000_000 * WAD ? uint96(1_000_000 * WAD) : quotaUsdt;

        evm.expectCall(
            address(poolQuotaKeeper), abi.encodeCall(IPoolQuotaKeeper.updateQuotas, (creditAccount, quotaUpdates))
        );

        (uint256 tokensToEnable,) = creditManager.updateQuotas(creditAccount, quotaUpdates);

        uint256 enabledTokensMap = tokensToEnable | UNDERLYING_TOKEN_MASK;

        CreditManagerTestInternal(address(creditManager)).setEnabledTokenMask(creditAccount, enabledTokensMap);

        evm.warp(block.timestamp + 60 * 60 * 24 * 365);

        (,, uint256 totalDebt) = creditManager.calcCreditAccountAccruedInterest(creditAccount);

        uint256 expectedTotalDebt = (borrowedAmount * cumulativeIndexAtClose) / cumulativeIndexAtOpen;
        expectedTotalDebt += (quotaLink * 1000 + quotaUsdt * 500) / PERCENTAGE_FACTOR;

        (uint16 feeInterest,,,,) = creditManager.fees();

        expectedTotalDebt += ((expectedTotalDebt - borrowedAmount) * feeInterest) / PERCENTAGE_FACTOR;

        uint256 diff = expectedTotalDebt > totalDebt ? expectedTotalDebt - totalDebt : totalDebt - expectedTotalDebt;

        assertLe(diff, 2, "Total debt not equal");
    }

    // [DEPRECIATED]: We test that after full collateral
    // /// @dev [CMQ-11]: updateQuotas reverts on too many enabled tokens
    // function test_CMQ_11_updateQuotas_reverts_on_too_many_tokens_enabled() public {
    //     (,,, address creditAccount) = cms.openCreditAccount();

    //     uint256 maxTokens = creditManager.maxAllowedEnabledTokenLength();

    //     QuotaUpdate[] memory quotaUpdates = _addManyLimitedTokens(maxTokens + 1, 100);

    //     evm.expectRevert(TooManyEnabledTokensException.selector);
    //     creditManager.updateQuotas(creditAccount, quotaUpdates);
    // }

    /// @dev [CMQ-12]: Credit Manager zeroes limits on quoted tokens upon incurring a loss
    function test_CMQ_12_creditManager_triggers_limit_zeroing_on_loss() public {
        _addQuotedToken(tokenTestSuite.addressOf(Tokens.LINK), 10_00, uint96(1_000_000 * WAD));
        _addQuotedToken(tokenTestSuite.addressOf(Tokens.USDT), 500, uint96(1_000_000 * WAD));

        (,,, address creditAccount) = cms.openCreditAccount();

        QuotaUpdate[] memory quotaUpdates = new QuotaUpdate[](2);

        quotaUpdates[0] =
            QuotaUpdate({token: tokenTestSuite.addressOf(Tokens.LINK), quotaChange: int96(uint96(100 * WAD))});
        quotaUpdates[1] =
            QuotaUpdate({token: tokenTestSuite.addressOf(Tokens.USDT), quotaChange: int96(uint96(200 * WAD))});
        (uint256 tokensToEnable,) = creditManager.updateQuotas(creditAccount, quotaUpdates);

        uint256 enabledTokensMap = tokensToEnable | UNDERLYING_TOKEN_MASK;

        TokenLT[] memory quotedTokens = new TokenLT[](creditManager.maxAllowedEnabledTokenLength() + 1);

        quotedTokens[1] = TokenLT({
            token: tokenTestSuite.addressOf(Tokens.LINK),
            lt: creditManager.liquidationThresholds(tokenTestSuite.addressOf(Tokens.LINK))
        });

        quotedTokens[0] = TokenLT({
            token: tokenTestSuite.addressOf(Tokens.USDT),
            lt: creditManager.liquidationThresholds(tokenTestSuite.addressOf(Tokens.USDT))
        });

        evm.expectCall(address(poolQuotaKeeper), abi.encodeCall(IPoolQuotaKeeper.setLimitsToZero, (quotedTokens)));

        creditManager.closeCreditAccount(
            USER,
            ClosureAction.LIQUIDATE_ACCOUNT,
            DAI_ACCOUNT_AMOUNT,
            USER,
            USER,
            enabledTokensMap,
            0,
            DAI_ACCOUNT_AMOUNT,
            false
        );

        for (uint256 i = 0; i < quotedTokens.length; ++i) {
            if (quotedTokens[i].token == address(0)) continue;

            (, uint96 limit,,) = poolQuotaKeeper.totalQuotaParams(quotedTokens[i].token);

            assertEq(limit, 1, "Limit was not zeroed");
        }
    }
}
