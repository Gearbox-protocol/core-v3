// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import "../../../interfaces/IAddressProviderV3.sol";
import {ACL} from "@gearbox-protocol/core-v2/contracts/core/ACL.sol";

import {AccountFactory} from "@gearbox-protocol/core-v2/contracts/core/AccountFactory.sol";
import {ICreditAccount} from "@gearbox-protocol/core-v2/contracts/interfaces/ICreditAccount.sol";
import {
    ICreditManagerV3,
    ICreditManagerV3Events,
    ClosureAction,
    CollateralTokenData,
    ManageDebtAction,
    CollateralDebtData
} from "../../../interfaces/ICreditManagerV3.sol";

import {IPriceOracleV2, IPriceOracleV2Ext} from "@gearbox-protocol/core-v2/contracts/interfaces/IPriceOracleV2.sol";
import {IWithdrawalManagerV3} from "../../../interfaces/IWithdrawalManagerV3.sol";

import {CreditManagerV3} from "../../../credit/CreditManagerV3.sol";

import {IPoolService} from "@gearbox-protocol/core-v2/contracts/interfaces/IPoolService.sol";

import {IWETH} from "@gearbox-protocol/core-v2/contracts/interfaces/external/IWETH.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "../../mocks/token/ERC20Mock.sol";
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";

// LIBS & TRAITS
import {BitMask, UNDERLYING_TOKEN_MASK} from "../../../libraries/BitMask.sol";
// TESTS

import "../../lib/constants.sol";
import {BalanceHelper} from "../../helpers/BalanceHelper.sol";

import "forge-std/console.sol";

// EXCEPTIONS

// MOCKS
import {PriceFeedMock} from "../../mocks/oracles/PriceFeedMock.sol";
import {PoolV3} from "../../../pool/PoolV3.sol";
import {TargetContractMock} from "../../mocks/core/TargetContractMock.sol";
import {ERC20ApproveRestrictedRevert, ERC20ApproveRestrictedFalse} from "../../mocks/token/ERC20ApproveRestricted.sol";

// SUITES
import {TokensTestSuite} from "../../suites/TokensTestSuite.sol";
import {Tokens} from "../../config/Tokens.sol";
import {CreditManagerTestSuite} from "../../suites/CreditManagerTestSuite.sol";

import {CreditConfig} from "../../config/CreditConfig.sol";

// EXCEPTIONS
import "../../../interfaces/IExceptions.sol";

/// @title AddressRepository
/// @notice Stores addresses of deployed contracts
contract CreditManagerIntegrationTest is Test, ICreditManagerV3Events, BalanceHelper {
    using BitMask for uint256;

    CreditManagerTestSuite cms;

    IAddressProviderV3 addressProvider;
    IWETH wethToken;

    AccountFactory af;
    CreditManagerV3 creditManager;
    PoolV3 pool;
    IPriceOracleV2 priceOracle;
    IWithdrawalManagerV3 withdrawalManager;
    ACL acl;
    address underlying;

    CreditConfig creditConfig;

    function setUp() public {
        tokenTestSuite = new TokensTestSuite();

        tokenTestSuite.topUpWETH{value: 100 * WAD}();
        _connectCreditManagerSuite(Tokens.DAI);
    }

    ///
    /// HELPERS

    function _connectCreditManagerSuite(Tokens t) internal {
        creditConfig = new CreditConfig(tokenTestSuite, t);
        cms = new CreditManagerTestSuite(creditConfig,  false, 1);

        acl = cms.acl();

        addressProvider = cms.addressProvider();
        af = cms.af();

        pool = cms.pool();
        withdrawalManager = cms.withdrawalManager();

        creditManager = cms.creditManager();

        priceOracle = IPriceOracleV2(creditManager.priceOracle());
        underlying = creditManager.underlying();
    }

    /// @dev Opens credit account for testing management functions
    function _openCreditAccount()
        internal
        returns (
            uint256 borrowedAmount,
            uint256 cumulativeIndexLastUpdate,
            uint256 cumulativeIndexAtClose,
            address creditAccount
        )
    {
        return cms.openCreditAccount();
    }

    function _addAndEnableTokens(address creditAccount, uint256 numTokens, uint256 balance) internal {
        for (uint256 i = 0; i < numTokens; i++) {
            ERC20Mock t = new ERC20Mock("new token", "nt", 18);
            PriceFeedMock pf = new PriceFeedMock(10**8, 8);

            vm.startPrank(CONFIGURATOR);
            creditManager.addToken(address(t));
            IPriceOracleV2Ext(address(priceOracle)).addPriceFeed(address(t), address(pf));
            creditManager.setCollateralTokenData(address(t), 8000, 8000, type(uint40).max, 0);
            vm.stopPrank();

            t.mint(creditAccount, balance);

            // creditManager.checkAndEnableToken(address(t));
        }
    }

    function _getRandomBits(uint256 ones, uint256 zeros, uint256 randomValue)
        internal
        pure
        returns (bool[] memory result, uint256 breakPoint)
    {
        if ((ones + zeros) == 0) {
            result = new bool[](0);
            breakPoint = 0;
            return (result, breakPoint);
        }

        uint256 onesCurrent = ones;
        uint256 zerosCurrent = zeros;

        result = new bool[](ones + zeros);
        uint256 i = 0;

        while (onesCurrent + zerosCurrent > 0) {
            uint256 rand = uint256(keccak256(abi.encodePacked(randomValue))) % (onesCurrent + zerosCurrent);
            if (rand < onesCurrent) {
                result[i] = true;
                onesCurrent--;
            } else {
                result[i] = false;
                zerosCurrent--;
            }

            i++;
        }

        if (ones > 0) {
            uint256 breakpointCounter = (uint256(keccak256(abi.encodePacked(randomValue))) % (ones)) + 1;

            for (uint256 j = 0; j < result.length; j++) {
                if (result[j]) {
                    breakpointCounter--;
                }

                if (breakpointCounter == 0) {
                    breakPoint = j;
                    break;
                }
            }
        }
    }

    function _baseFullCollateralCheck(address creditAccount) internal {
        // TODO: CHANGE
        creditManager.fullCollateralCheck(creditAccount, 0, new uint256[](0), 10000);
    }

    ///
    ///  OPEN CREDIT ACCOUNT
    ///

    /// @dev I:[CM-1]: openCreditAccount transfers_tokens_from_pool
    function test_I_CM_01_openCreditAccount_transfers_tokens_from_pool() public {
        address expectedCreditAccount =
            AccountFactory(addressProvider.getAddressOrRevert(AP_ACCOUNT_FACTORY, NO_VERSION_CONTROL)).head();

        uint256 blockAtOpen = block.number;
        uint256 cumulativeAtOpen = pool.calcLinearCumulative_RAY();
        // pool.setCumulativeIndexNow(cumulativeAtOpen);

        // Existing address case
        address creditAccount = creditManager.openCreditAccount(DAI_ACCOUNT_AMOUNT, USER);
        assertEq(creditAccount, expectedCreditAccount, "Incorrecct credit account address");

        (uint256 debt, uint256 cumulativeIndexLastUpdate,,,,,,) = creditManager.creditAccountInfo(creditAccount);

        assertEq(debt, DAI_ACCOUNT_AMOUNT, "Incorrect borrowed amount set in CA");
        assertEq(cumulativeIndexLastUpdate, cumulativeAtOpen, "Incorrect cumulativeIndexLastUpdate set in CA");

        assertEq(ICreditAccount(creditAccount).since(), blockAtOpen, "Incorrect since set in CA");

        expectBalance(Tokens.DAI, creditAccount, DAI_ACCOUNT_AMOUNT);
        // assertEq(pool.lendAmount(), DAI_ACCOUNT_AMOUNT, "Incorrect DAI_ACCOUNT_AMOUNT in Pool call");
        // assertEq(pool.lendAccount(), creditAccount, "Incorrect credit account in lendCreditAccount call");
        // assertEq(creditManager.creditAccounts(USER), creditAccount, "Credit account is not associated with user");
        assertEq(creditManager.enabledTokensMaskOf(creditAccount), 0, "Incorrect enabled token mask");

        console.log(address(pool));
        console.log(creditManager.pool());
        console.log(pool.expectedLiquidity());
    }

    //
    // CLOSE CREDIT ACCOUNT
    //

    /// @dev I:[CM-9]: closeCreditAccount returns account to the end of AF1s
    /// remove borrower from creditAccounts mapping
    function test_I_CM_09_close_credit_account_updates_pool_correctly() public {
        (uint256 borrowedAmount,,, address creditAccount) = _openCreditAccount();

        assertTrue(
            creditAccount
                != AccountFactory(addressProvider.getAddressOrRevert(AP_ACCOUNT_FACTORY, NO_VERSION_CONTROL)).tail(),
            "credit account is already in tail!"
        );

        // Transfer additional borrowedAmount. After that underluying token balance = 2 * borrowedAmount
        tokenTestSuite.mint(Tokens.DAI, creditAccount, borrowedAmount);

        // Increase block number cause it's forbidden to close credit account in the same block
        vm.roll(block.number + 1);

        CollateralDebtData memory collateralDebtData;
        collateralDebtData.debt = DAI_ACCOUNT_AMOUNT;

        creditManager.closeCreditAccount({
            creditAccount: creditAccount,
            closureAction: ClosureAction.CLOSE_ACCOUNT,
            collateralDebtData: collateralDebtData,
            payer: USER,
            to: USER,
            skipTokensMask: 0,
            convertToETH: false
        });

        assertEq(
            creditAccount,
            AccountFactory(addressProvider.getAddressOrRevert(AP_ACCOUNT_FACTORY, NO_VERSION_CONTROL)).tail(),
            "credit account is not in accountFactory tail!"
        );

        vm.expectRevert(CreditAccountDoesNotExistException.selector);
        creditManager.getBorrowerOrRevert(creditAccount);
    }

    /// @dev I:[CM-10]: closeCreditAccount returns undelying tokens if credit account balance > amounToPool
    ///
    /// This test covers the case:
    /// Closure type: CLOSURE
    /// Underlying balance: > amountToPool
    /// Send all assets: false
    ///
    function test_I_CM_10_close_credit_account_returns_underlying_token_if_not_liquidated() public {
        (
            uint256 borrowedAmount,
            uint256 cumulativeIndexLastUpdate,
            uint256 cumulativeIndexAtClose,
            address creditAccount
        ) = _openCreditAccount();

        uint256 poolBalanceBefore = tokenTestSuite.balanceOf(Tokens.DAI, address(pool));

        // Transfer additional borrowedAmount. After that underluying token balance = 2 * borrowedAmount
        tokenTestSuite.mint(Tokens.DAI, creditAccount, borrowedAmount);

        uint256 interestAccrued = (borrowedAmount * cumulativeIndexAtClose) / cumulativeIndexLastUpdate - borrowedAmount;

        (uint16 feeInterest,,,,) = creditManager.fees();

        uint256 profit = (interestAccrued * feeInterest) / PERCENTAGE_FACTOR;

        uint256 amountToPool = borrowedAmount + interestAccrued + profit;

        vm.expectCall(
            address(pool), abi.encodeWithSelector(IPoolService.repayCreditAccount.selector, borrowedAmount, profit, 0)
        );

        {
            CollateralDebtData memory collateralDebtData;
            collateralDebtData.debt = DAI_ACCOUNT_AMOUNT;
            collateralDebtData.accruedInterest = interestAccrued;
            collateralDebtData.accruedFees = profit;
            collateralDebtData.enabledTokensMask = UNDERLYING_TOKEN_MASK;

            (uint256 remainingFunds, uint256 loss) = creditManager.closeCreditAccount({
                creditAccount: creditAccount,
                closureAction: ClosureAction.CLOSE_ACCOUNT,
                collateralDebtData: collateralDebtData,
                payer: USER,
                to: FRIEND,
                skipTokensMask: 0,
                convertToETH: false
            });

            assertEq(remainingFunds, 0, "Remaining funds is not zero!");

            assertEq(loss, 0, "Loss is not zero");
        }

        expectBalance(Tokens.DAI, creditAccount, 1);

        expectBalance(Tokens.DAI, address(pool), poolBalanceBefore + amountToPool);

        expectBalance(Tokens.DAI, FRIEND, 2 * borrowedAmount - amountToPool - 1, "Incorrect amount were paid back");
    }

    /// @dev I:[CM-11]: closeCreditAccount sets correct values and transfers tokens from pool
    ///
    /// This test covers the case:
    /// Closure type: CLOSURE
    /// Underlying balance: < amountToPool
    /// Send all assets: false
    ///
    function test_I_CM_11_close_credit_account_charges_caller_if_underlying_token_not_enough() public {
        (
            uint256 borrowedAmount,
            uint256 cumulativeIndexLastUpdate,
            uint256 cumulativeIndexAtClose,
            address creditAccount
        ) = _openCreditAccount();

        uint256 poolBalanceBefore = tokenTestSuite.balanceOf(Tokens.DAI, address(pool));

        // Transfer funds to USER account to be able to cover extra cost
        tokenTestSuite.mint(Tokens.DAI, USER, borrowedAmount);

        uint256 interestAccrued = (borrowedAmount * cumulativeIndexAtClose) / cumulativeIndexLastUpdate - borrowedAmount;

        (uint16 feeInterest,,,,) = creditManager.fees();

        uint256 profit = (interestAccrued * feeInterest) / PERCENTAGE_FACTOR;

        uint256 amountToPool = borrowedAmount + interestAccrued + profit;

        vm.expectCall(
            address(pool), abi.encodeWithSelector(IPoolService.repayCreditAccount.selector, borrowedAmount, profit, 0)
        );
        {
            CollateralDebtData memory collateralDebtData;
            collateralDebtData.debt = borrowedAmount;
            collateralDebtData.accruedInterest = interestAccrued;
            collateralDebtData.accruedFees = profit;
            collateralDebtData.enabledTokensMask = UNDERLYING_TOKEN_MASK;

            (uint256 remainingFunds, uint256 loss) = creditManager.closeCreditAccount({
                creditAccount: creditAccount,
                closureAction: ClosureAction.CLOSE_ACCOUNT,
                collateralDebtData: collateralDebtData,
                payer: USER,
                to: FRIEND,
                skipTokensMask: 0,
                convertToETH: false
            });

            assertEq(remainingFunds, 0, "Remaining funds is not zero!");

            assertEq(loss, 0, "Loss is not zero");
        }

        expectBalance(Tokens.DAI, creditAccount, 1, "Credit account balance != 1");

        expectBalance(Tokens.DAI, address(pool), poolBalanceBefore + amountToPool);

        expectBalance(Tokens.DAI, USER, 2 * borrowedAmount - amountToPool - 1, "Incorrect amount were paid back");

        expectBalance(Tokens.DAI, FRIEND, 0, "Incorrect amount were paid back");
    }

    /// @dev I:[CM-12]: closeCreditAccount sets correct values and transfers tokens from pool
    ///
    /// This test covers the case:
    /// Closure type: LIQUIDATION / LIQUIDATION_EXPIRED
    /// Underlying balance: > amountToPool
    /// Send all assets: false
    /// Remaining funds: 0
    ///
    function test_I_CM_12_close_credit_account_charges_caller_if_underlying_token_not_enough() public {
        for (uint256 i = 0; i < 2; i++) {
            uint256 friendBalanceBefore = tokenTestSuite.balanceOf(Tokens.DAI, FRIEND);

            ClosureAction action = i == 1 ? ClosureAction.LIQUIDATE_EXPIRED_ACCOUNT : ClosureAction.LIQUIDATE_ACCOUNT;
            uint256 interestAccrued;
            uint256 borrowedAmount;
            address creditAccount;

            {
                uint256 cumulativeIndexLastUpdate;
                uint256 cumulativeIndexAtClose;
                (borrowedAmount, cumulativeIndexLastUpdate, cumulativeIndexAtClose, creditAccount) =
                    _openCreditAccount();

                interestAccrued = (borrowedAmount * cumulativeIndexAtClose) / cumulativeIndexLastUpdate - borrowedAmount;
            }

            uint256 poolBalanceBefore = tokenTestSuite.balanceOf(Tokens.DAI, address(pool));
            uint256 discount;

            {
                (,, uint16 liquidationDiscount,, uint16 liquidationDiscountExpired) = creditManager.fees();
                discount = action == ClosureAction.LIQUIDATE_ACCOUNT ? liquidationDiscount : liquidationDiscountExpired;
            }

            // uint256 totalValue = borrowedAmount;
            uint256 amountToPool = (borrowedAmount * discount) / PERCENTAGE_FACTOR;

            CollateralDebtData memory collateralDebtData;
            collateralDebtData.debt = borrowedAmount;
            collateralDebtData.accruedInterest = interestAccrued;
            collateralDebtData.accruedFees = 0;
            collateralDebtData.totalValue = borrowedAmount;
            collateralDebtData.enabledTokensMask = UNDERLYING_TOKEN_MASK;
            {
                uint256 loss = borrowedAmount + interestAccrued - amountToPool;

                vm.expectCall(
                    address(pool),
                    abi.encodeWithSelector(IPoolService.repayCreditAccount.selector, borrowedAmount, 0, loss)
                );
            }

            (uint256 remainingFunds,) = creditManager.closeCreditAccount({
                creditAccount: creditAccount,
                closureAction: action,
                collateralDebtData: collateralDebtData,
                payer: LIQUIDATOR,
                to: FRIEND,
                skipTokensMask: 0,
                convertToETH: false
            });

            assertEq(remainingFunds, 0, "Remaining funds is not zero!");

            expectBalance(Tokens.DAI, creditAccount, 1, "Credit account balance != 1");

            expectBalance(Tokens.DAI, address(pool), poolBalanceBefore + amountToPool);

            expectBalance(
                Tokens.DAI,
                FRIEND,
                friendBalanceBefore + (borrowedAmount * (PERCENTAGE_FACTOR - discount)) / PERCENTAGE_FACTOR
                    - (i == 2 ? 0 : 1),
                "Incorrect amount were paid to liqiudator friend address"
            );
        }
    }

    /// @dev I:[CM-13]: openCreditAccount sets correct values and transfers tokens from pool
    ///
    /// This test covers the case:
    /// Closure type: LIQUIDATION / LIQUIDATION_EXPIRED
    /// Underlying balance: < amountToPool
    /// Send all assets: false
    /// Remaining funds: >0
    ///

    function test_I_CM_13_close_credit_account_charges_caller_if_underlying_token_not_enough() public {
        for (uint256 i = 0; i < 2; i++) {
            setUp();
            uint256 borrowedAmount;
            address creditAccount;

            uint256 expectedRemainingFunds = 100 * WAD;

            uint256 profit;
            uint256 amountToPool;
            uint256 totalValue;
            uint256 interestAccrued;
            {
                uint256 cumulativeIndexLastUpdate;
                uint256 cumulativeIndexAtClose;
                (borrowedAmount, cumulativeIndexLastUpdate, cumulativeIndexAtClose, creditAccount) =
                    _openCreditAccount();

                interestAccrued = (borrowedAmount * cumulativeIndexAtClose) / cumulativeIndexLastUpdate - borrowedAmount;

                uint16 feeInterest;
                uint16 feeLiquidation;
                uint16 liquidationDiscount;

                {
                    (feeInterest,,,,) = creditManager.fees();
                }

                {
                    uint16 feeLiquidationNormal;
                    uint16 feeLiquidationExpired;

                    (, feeLiquidationNormal,, feeLiquidationExpired,) = creditManager.fees();

                    feeLiquidation = (i == 0 || i == 2) ? feeLiquidationNormal : feeLiquidationExpired;
                }

                {
                    uint16 liquidationDiscountNormal;
                    uint16 liquidationDiscountExpired;

                    (feeInterest,, liquidationDiscountNormal,, liquidationDiscountExpired) = creditManager.fees();

                    liquidationDiscount = i == 1 ? liquidationDiscountExpired : liquidationDiscountNormal;
                }

                uint256 profitInterest = (interestAccrued * feeInterest) / PERCENTAGE_FACTOR;

                amountToPool = borrowedAmount + interestAccrued + profitInterest;

                totalValue = ((amountToPool + expectedRemainingFunds) * PERCENTAGE_FACTOR)
                    / (liquidationDiscount - feeLiquidation);

                uint256 profitLiquidation = (totalValue * feeLiquidation) / PERCENTAGE_FACTOR;

                amountToPool += profitLiquidation;

                profit = profitInterest + profitLiquidation;
            }

            uint256 poolBalanceBefore = tokenTestSuite.balanceOf(Tokens.DAI, address(pool));

            tokenTestSuite.mint(Tokens.DAI, LIQUIDATOR, totalValue);
            expectBalance(Tokens.DAI, USER, 0, "USER has non-zero balance");
            expectBalance(Tokens.DAI, FRIEND, 0, "FRIEND has non-zero balance");
            expectBalance(Tokens.DAI, LIQUIDATOR, totalValue, "LIQUIDATOR has incorrect initial balance");

            expectBalance(Tokens.DAI, creditAccount, borrowedAmount, "creditAccount has incorrect initial balance");

            uint256 remainingFunds;

            {
                uint256 loss;

                (uint16 feeInterest,,,,) = creditManager.fees();

                CollateralDebtData memory collateralDebtData;
                collateralDebtData.debt = borrowedAmount;
                collateralDebtData.accruedInterest = interestAccrued;
                collateralDebtData.accruedFees = (interestAccrued * feeInterest) / PERCENTAGE_FACTOR;
                collateralDebtData.totalValue = totalValue;
                collateralDebtData.enabledTokensMask = UNDERLYING_TOKEN_MASK;

                vm.expectCall(
                    address(pool),
                    abi.encodeWithSelector(IPoolService.repayCreditAccount.selector, borrowedAmount, profit, 0)
                );

                (remainingFunds, loss) = creditManager.closeCreditAccount({
                    creditAccount: creditAccount,
                    closureAction: i == 1 ? ClosureAction.LIQUIDATE_EXPIRED_ACCOUNT : ClosureAction.LIQUIDATE_ACCOUNT,
                    collateralDebtData: collateralDebtData,
                    payer: LIQUIDATOR,
                    to: FRIEND,
                    skipTokensMask: 0,
                    convertToETH: false
                });

                assertLe(expectedRemainingFunds - remainingFunds, 2, "Incorrect remaining funds");

                assertEq(loss, 0, "Loss can't be positive with remaining funds");
            }

            {
                expectBalance(Tokens.DAI, creditAccount, 1, "Credit account balance != 1");
                expectBalance(Tokens.DAI, USER, remainingFunds, "USER get incorrect amount as remaning funds");

                expectBalance(Tokens.DAI, address(pool), poolBalanceBefore + amountToPool, "INCORRECT POOL BALANCE");
            }

            expectBalance(
                Tokens.DAI,
                LIQUIDATOR,
                totalValue + borrowedAmount - amountToPool - remainingFunds - 1,
                "Incorrect amount were paid to lqiudaidator"
            );
        }
    }

    /// @dev I:[CM-14]: closeCreditAccount sends assets depends on sendAllAssets flag
    ///
    /// This test covers the case:
    /// Closure type: LIQUIDATION
    /// Underlying balance: < amountToPool
    /// Send all assets: false
    /// Remaining funds: >0
    ///

    function test_I_CM_14_close_credit_account_with_nonzero_skipTokenMask_sends_correct_tokens() public {
        (uint256 borrowedAmount,,, address creditAccount) = _openCreditAccount();

        tokenTestSuite.mint(Tokens.DAI, creditAccount, borrowedAmount);
        tokenTestSuite.mint(Tokens.WETH, creditAccount, WETH_EXCHANGE_AMOUNT);

        tokenTestSuite.mint(Tokens.USDC, creditAccount, USDC_EXCHANGE_AMOUNT);

        tokenTestSuite.mint(Tokens.LINK, creditAccount, LINK_EXCHANGE_AMOUNT);

        uint256 wethTokenMask = creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.WETH));
        uint256 usdcTokenMask = creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.USDC));
        uint256 linkTokenMask = creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.LINK));

        CollateralDebtData memory collateralDebtData;
        collateralDebtData.debt = borrowedAmount;
        collateralDebtData.accruedInterest = 0;
        collateralDebtData.accruedFees = 0;
        collateralDebtData.enabledTokensMask = wethTokenMask | usdcTokenMask | linkTokenMask;

        creditManager.closeCreditAccount({
            creditAccount: creditAccount,
            closureAction: ClosureAction.CLOSE_ACCOUNT,
            collateralDebtData: collateralDebtData,
            payer: USER,
            to: FRIEND,
            skipTokensMask: wethTokenMask | usdcTokenMask,
            convertToETH: false
        });

        expectBalance(Tokens.WETH, FRIEND, 0);
        expectBalance(Tokens.WETH, creditAccount, WETH_EXCHANGE_AMOUNT);

        expectBalance(Tokens.USDC, FRIEND, 0);
        expectBalance(Tokens.USDC, creditAccount, USDC_EXCHANGE_AMOUNT);

        expectBalance(Tokens.LINK, FRIEND, LINK_EXCHANGE_AMOUNT - 1);
    }

    /// @dev I:[CM-16]: closeCreditAccount sends ETH for WETH creditManger to borrower
    /// CASE: CLOSURE
    /// Underlying token: WETH
    function test_I_CM_16_close_weth_credit_account_sends_eth_to_borrower() public {
        // It takes "clean" address which doesn't holds any assets

        _connectCreditManagerSuite(Tokens.WETH);

        /// CLOSURE CASE
        (
            uint256 borrowedAmount,
            uint256 cumulativeIndexLastUpdate,
            uint256 cumulativeIndexAtClose,
            address creditAccount
        ) = _openCreditAccount();

        // Transfer additional borrowedAmount. After that underluying token balance = 2 * borrowedAmount
        tokenTestSuite.mint(Tokens.WETH, creditAccount, borrowedAmount);

        uint256 interestAccrued = (borrowedAmount * cumulativeIndexAtClose) / cumulativeIndexLastUpdate - borrowedAmount;

        // creditManager.closeCreditAccount(USER, ClosureAction.CLOSE_ACCOUNT, 0, USER, USER, 0, true);

        // creditManager.closeCreditAccount(
        //     creditAccount, ClosureAction.CLOSE_ACCOUNT, 0, USER, USER, 1, 0, borrowedAmount + interestAccrued, true
        // );

        (uint16 feeInterest,,,,) = creditManager.fees();
        uint256 profit = (interestAccrued * feeInterest) / PERCENTAGE_FACTOR;

        CollateralDebtData memory collateralDebtData;
        collateralDebtData.debt = borrowedAmount;
        collateralDebtData.accruedInterest = interestAccrued;
        collateralDebtData.accruedFees = profit;
        collateralDebtData.enabledTokensMask = UNDERLYING_TOKEN_MASK;

        creditManager.closeCreditAccount({
            creditAccount: creditAccount,
            closureAction: ClosureAction.CLOSE_ACCOUNT,
            collateralDebtData: collateralDebtData,
            payer: USER,
            to: USER,
            skipTokensMask: 0,
            convertToETH: true
        });

        expectBalance(Tokens.WETH, creditAccount, 1);

        uint256 amountToPool = borrowedAmount + interestAccrued + profit;

        assertEq(
            withdrawalManager.immediateWithdrawals(cms.creditFacade(), tokenTestSuite.addressOf(Tokens.WETH)),
            2 * borrowedAmount - amountToPool - 1,
            "Incorrect amount deposited to withdrawalManager"
        );
    }

    /// @dev I:[CM-17]: closeCreditAccount sends ETH for WETH creditManger to borrower
    /// CASE: CLOSURE
    /// Underlying token: DAI
    function test_I_CM_17_close_dai_credit_account_sends_eth_to_borrower() public {
        /// CLOSURE CASE
        (uint256 borrowedAmount,,, address creditAccount) = _openCreditAccount();

        // Transfer additional borrowedAmount. After that underluying token balance = 2 * borrowedAmount
        tokenTestSuite.mint(Tokens.DAI, creditAccount, borrowedAmount);

        // Adds WETH to test how it would be converted
        tokenTestSuite.mint(Tokens.WETH, creditAccount, WETH_EXCHANGE_AMOUNT);

        uint256 wethTokenMask = creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.WETH));
        uint256 daiTokenMask = creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.DAI));

        CollateralDebtData memory collateralDebtData;
        collateralDebtData.debt = borrowedAmount;
        collateralDebtData.accruedInterest = 0;
        collateralDebtData.accruedFees = 0;
        collateralDebtData.enabledTokensMask = wethTokenMask | daiTokenMask;

        creditManager.closeCreditAccount({
            creditAccount: creditAccount,
            closureAction: ClosureAction.CLOSE_ACCOUNT,
            collateralDebtData: collateralDebtData,
            payer: USER,
            to: USER,
            skipTokensMask: 0,
            convertToETH: true
        });

        expectBalance(Tokens.WETH, creditAccount, 1);

        assertEq(
            withdrawalManager.immediateWithdrawals(cms.creditFacade(), tokenTestSuite.addressOf(Tokens.WETH)),
            WETH_EXCHANGE_AMOUNT - 1,
            "Incorrect amount deposited to withdrawalManager"
        );
    }

    /// @dev I:[CM-18]: closeCreditAccount sends ETH for WETH creditManger to borrower
    /// CASE: LIQUIDATION
    function test_I_CM_18_close_credit_account_sends_eth_to_liquidator_and_weth_to_borrower() public {
        /// Store USER ETH balance

        // uint256 userBalanceBefore = tokenTestSuite.balanceOf(Tokens.WETH, USER);

        (,, uint16 liquidationDiscount,,) = creditManager.fees();

        // It takes "clean" address which doesn't holds any assets

        _connectCreditManagerSuite(Tokens.WETH);

        /// CLOSURE CASE
        (uint256 borrowedAmount,,, address creditAccount) = _openCreditAccount();

        // Transfer additional borrowedAmount. After that underluying token balance = 2 * borrowedAmount
        tokenTestSuite.mint(Tokens.WETH, creditAccount, borrowedAmount);

        uint256 totalValue = borrowedAmount * 2;

        uint256 wethTokenMask = creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.WETH));
        uint256 daiTokenMask = creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.DAI));

        CollateralDebtData memory collateralDebtData;
        collateralDebtData.debt = borrowedAmount;
        collateralDebtData.accruedInterest = 0;
        collateralDebtData.accruedFees = 0;
        collateralDebtData.totalValue = totalValue;
        collateralDebtData.enabledTokensMask = wethTokenMask | daiTokenMask;

        creditManager.closeCreditAccount({
            creditAccount: creditAccount,
            closureAction: ClosureAction.LIQUIDATE_ACCOUNT,
            collateralDebtData: collateralDebtData,
            payer: LIQUIDATOR,
            to: FRIEND,
            skipTokensMask: 0,
            convertToETH: true
        });

        // checks that no eth were sent to USER account
        expectEthBalance(USER, 0);

        expectBalance(Tokens.WETH, creditAccount, 1, "Credit account balance != 1");

        // expectBalance(Tokens.WETH, USER, userBalanceBefore + remainingFunds, "Incorrect amount were paid back");

        assertEq(
            withdrawalManager.immediateWithdrawals(cms.creditFacade(), tokenTestSuite.addressOf(Tokens.WETH)),
            (totalValue * (PERCENTAGE_FACTOR - liquidationDiscount)) / PERCENTAGE_FACTOR,
            "Incorrect amount were paid to liqiudator friend address"
        );
    }

    /// @dev I:[CM-19]: closeCreditAccount sends ETH for WETH creditManger to borrower
    /// CASE: LIQUIDATION
    /// Underlying token: DAI
    function test_I_CM_19_close_dai_credit_account_sends_eth_to_liquidator() public {
        /// CLOSURE CASE
        (uint256 borrowedAmount,,, address creditAccount) = _openCreditAccount();
        // creditManager.transferAccountOwnership(creditAccount, address(this));

        // Transfer additional borrowedAmount. After that underluying token balance = 2 * borrowedAmount
        tokenTestSuite.mint(Tokens.DAI, creditAccount, borrowedAmount);

        // Adds WETH to test how it would be converted
        tokenTestSuite.mint(Tokens.WETH, creditAccount, WETH_EXCHANGE_AMOUNT);

        // creditManager.transferAccountOwnership(creditAccount, USER);
        uint256 wethTokenMask = creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.WETH));
        uint256 daiTokenMask = creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.DAI));

        CollateralDebtData memory collateralDebtData;
        collateralDebtData.debt = borrowedAmount;
        collateralDebtData.accruedInterest = 0;
        collateralDebtData.accruedFees = 0;
        collateralDebtData.totalValue = borrowedAmount;
        collateralDebtData.enabledTokensMask = wethTokenMask | daiTokenMask;

        creditManager.closeCreditAccount({
            creditAccount: creditAccount,
            closureAction: ClosureAction.LIQUIDATE_ACCOUNT,
            collateralDebtData: collateralDebtData,
            payer: LIQUIDATOR,
            to: FRIEND,
            skipTokensMask: 0,
            convertToETH: true
        });

        expectBalance(Tokens.WETH, creditAccount, 1);

        assertEq(
            withdrawalManager.immediateWithdrawals(cms.creditFacade(), tokenTestSuite.addressOf(Tokens.WETH)),
            WETH_EXCHANGE_AMOUNT - 1,
            "Incorrect amount were paid to liqiudator friend address"
        );
    }

    //
    // MANAGE DEBT
    //

    /// @dev I:[CM-20]: manageDebt correctly increases debt
    function test_I_CM_20_manageDebt_correctly_increases_debt(uint128 amount) public {
        (uint256 borrowedAmount, uint256 cumulativeIndexLastUpdate,, address creditAccount) = cms.openCreditAccount(1);

        tokenTestSuite.mint(Tokens.DAI, address(pool), amount);

        // pool.setCumulativeIndexNow(cumulativeIndexLastUpdate * 2);

        // uint256 expectedNewCulumativeIndex =
        //     (2 * cumulativeIndexLastUpdate * (borrowedAmount + amount)) / (2 * borrowedAmount + amount);

        (uint256 newBorrowedAmount,,) =
            creditManager.manageDebt(creditAccount, amount, 1, ManageDebtAction.INCREASE_DEBT);

        assertEq(newBorrowedAmount, borrowedAmount + amount, "Incorrect returned newBorrowedAmount");

        // assertLe(
        //     (ICreditAccount(creditAccount).cumulativeIndexLastUpdate() * (10 ** 6)) / expectedNewCulumativeIndex,
        //     10 ** 6,
        //     "Incorrect cumulative index"
        // );

        (uint256 debt,,,,,,,) = creditManager.creditAccountInfo(creditAccount);
        assertEq(debt, newBorrowedAmount, "Incorrect borrowedAmount");

        expectBalance(Tokens.DAI, creditAccount, newBorrowedAmount, "Incorrect balance on credit account");

        // assertEq(pool.lendAmount(), amount, "Incorrect lend amount");

        // assertEq(pool.lendAccount(), creditAccount, "Incorrect lend account");
    }

    /// @dev I:[CM-21]: manageDebt correctly decreases debt
    function test_I_CM_21_manageDebt_correctly_decreases_debt(uint128 amount) public {
        // tokenTestSuite.mint(Tokens.DAI, address(pool), (uint256(type(uint128).max) * 14) / 10);

        // (uint256 borrowedAmount, uint256 cumulativeIndexLastUpdate, uint256 cumulativeIndexNow, address creditAccount) =
        //     cms.openCreditAccount((uint256(type(uint128).max) * 14) / 10);

        // (,, uint256 totalDebt) = creditManager.calcAccruedInterestAndFees(creditAccount);

        // uint256 expectedInterestAndFees;
        // uint256 expectedBorrowAmount;
        // if (amount >= totalDebt - borrowedAmount) {
        //     expectedInterestAndFees = 0;
        //     expectedBorrowAmount = totalDebt - amount;
        // } else {
        //     expectedInterestAndFees = totalDebt - borrowedAmount - amount;
        //     expectedBorrowAmount = borrowedAmount;
        // }

        // (uint256 newBorrowedAmount,) =
        //     creditManager.manageDebt(creditAccount, amount, 1, ManageDebtAction.DECREASE_DEBT);

        // assertEq(newBorrowedAmount, expectedBorrowAmount, "Incorrect returned newBorrowedAmount");

        // if (amount >= totalDebt - borrowedAmount) {
        //     (,, uint256 newTotalDebt) = creditManager.calcAccruedInterestAndFees(creditAccount);

        //     assertEq(newTotalDebt, newBorrowedAmount, "Incorrect new interest");
        // } else {
        //     (,, uint256 newTotalDebt) = creditManager.calcAccruedInterestAndFees(creditAccount);

        //     assertLt(
        //         (RAY * (newTotalDebt - newBorrowedAmount)) / expectedInterestAndFees - RAY,
        //         10000,
        //         "Incorrect new interest"
        //     );
        // }
        // uint256 cumulativeIndexLastUpdateAfter;
        // {
        //     uint256 debt;
        //     (debt, cumulativeIndexLastUpdateAfter,,,,) = creditManager.creditAccountInfo(creditAccount);

        //     assertEq(debt, newBorrowedAmount, "Incorrect borrowedAmount");
        // }

        // expectBalance(Tokens.DAI, creditAccount, borrowedAmount - amount, "Incorrect balance on credit account");

        // if (amount >= totalDebt - borrowedAmount) {
        //     assertEq(cumulativeIndexLastUpdateAfter, cumulativeIndexNow, "Incorrect cumulativeIndexLastUpdate");
        // } else {
        //     CreditManagerTestInternal cmi = new CreditManagerTestInternal(
        //         creditManager.poolService(), address(withdrawalManager)
        //     );

        //     {
        //         (uint256 feeInterest,,,,) = creditManager.fees();
        //         amount = uint128((uint256(amount) * PERCENTAGE_FACTOR) / (PERCENTAGE_FACTOR + feeInterest));
        //     }

        //     assertEq(
        //         cumulativeIndexLastUpdateAfter,
        //         cmi.calcNewCumulativeIndex(borrowedAmount, amount, cumulativeIndexNow, cumulativeIndexLastUpdate, false),
        //         "Incorrect cumulativeIndexLastUpdate"
        //     );
        // }
    }

    //
    // ADD COLLATERAL
    //

    //
    // APPROVE CREDIT ACCOUNT
    //

    /// @dev I:[CM-25A]: approveCreditAccount reverts if the token is not added
    function test_I_CM_25A_approveCreditAccount_reverts_if_the_token_is_not_added() public {
        (,,, address creditAccount) = _openCreditAccount();
        creditManager.setActiveCreditAccount(creditAccount);

        vm.prank(CONFIGURATOR);
        creditManager.setContractAllowance(ADAPTER, DUMB_ADDRESS);

        vm.expectRevert(TokenNotAllowedException.selector);

        vm.prank(ADAPTER);
        creditManager.approveCreditAccount(DUMB_ADDRESS, 100);
    }

    /// @dev I:[CM-26]: approveCreditAccount approves with desired allowance
    function test_I_CM_26_approveCreditAccount_approves_with_desired_allowance() public {
        (,,, address creditAccount) = _openCreditAccount();
        creditManager.setActiveCreditAccount(creditAccount);

        vm.prank(CONFIGURATOR);
        creditManager.setContractAllowance(ADAPTER, DUMB_ADDRESS);

        // Case, when current allowance > Allowance_THRESHOLD
        tokenTestSuite.approve(Tokens.DAI, creditAccount, DUMB_ADDRESS, 200);

        address dai = tokenTestSuite.addressOf(Tokens.DAI);

        vm.prank(ADAPTER);
        creditManager.approveCreditAccount(dai, DAI_EXCHANGE_AMOUNT);

        expectAllowance(Tokens.DAI, creditAccount, DUMB_ADDRESS, DAI_EXCHANGE_AMOUNT);
    }

    /// @dev I:[CM-27A]: approveCreditAccount works for ERC20 that revert if allowance > 0 before approve
    function test_I_CM_27A_approveCreditAccount_works_for_ERC20_with_approve_restrictions() public {
        (,,, address creditAccount) = _openCreditAccount();
        creditManager.setActiveCreditAccount(creditAccount);

        vm.prank(CONFIGURATOR);
        creditManager.setContractAllowance(ADAPTER, DUMB_ADDRESS);

        address approveRevertToken = address(new ERC20ApproveRestrictedRevert());

        vm.prank(CONFIGURATOR);
        creditManager.addToken(approveRevertToken);

        vm.prank(ADAPTER);
        creditManager.approveCreditAccount(approveRevertToken, DAI_EXCHANGE_AMOUNT);

        vm.prank(ADAPTER);
        creditManager.approveCreditAccount(approveRevertToken, 2 * DAI_EXCHANGE_AMOUNT);

        expectAllowance(approveRevertToken, creditAccount, DUMB_ADDRESS, 2 * DAI_EXCHANGE_AMOUNT);
    }

    // /// @dev I:[CM-27B]: approveCreditAccount works for ERC20 that returns false if allowance > 0 before approve
    function test_I_CM_27B_approveCreditAccount_works_for_ERC20_with_approve_restrictions() public {
        (,,, address creditAccount) = _openCreditAccount();
        creditManager.setActiveCreditAccount(creditAccount);

        address approveFalseToken = address(new ERC20ApproveRestrictedFalse());

        vm.prank(CONFIGURATOR);
        creditManager.addToken(approveFalseToken);

        vm.prank(CONFIGURATOR);
        creditManager.setContractAllowance(ADAPTER, DUMB_ADDRESS);

        vm.prank(ADAPTER);
        creditManager.approveCreditAccount(approveFalseToken, DAI_EXCHANGE_AMOUNT);

        vm.prank(ADAPTER);
        creditManager.approveCreditAccount(approveFalseToken, 2 * DAI_EXCHANGE_AMOUNT);

        expectAllowance(approveFalseToken, creditAccount, DUMB_ADDRESS, 2 * DAI_EXCHANGE_AMOUNT);
    }

    //
    // EXECUTE ORDER
    //

    /// @dev I:[CM-29]: execute calls credit account method and emit event
    function test_I_CM_29_execute_calls_credit_account_method_and_emit_event() public {
        (,,, address creditAccount) = _openCreditAccount();
        creditManager.setActiveCreditAccount(creditAccount);

        TargetContractMock targetMock = new TargetContractMock();

        vm.prank(CONFIGURATOR);
        creditManager.setContractAllowance(ADAPTER, address(targetMock));

        bytes memory callData = bytes("Hello, world!");

        // stack trace check
        vm.expectCall(creditAccount, abi.encodeWithSignature("execute(address,bytes)", address(targetMock), callData));
        vm.expectCall(address(targetMock), callData);

        vm.prank(ADAPTER);
        creditManager.execute(callData);

        assertEq0(targetMock.callData(), callData, "Incorrect calldata");
    }

    // /// @dev I:[CM-64]: closeCreditAccount reverts when attempting to liquidate while paused,
    // /// and the payer is not set as emergency liquidator

    // function test_I_CM_64_closeCreditAccount_reverts_when_paused_and_liquidator_not_privileged() public {
    //     vm.prank(CONFIGURATOR);
    //     creditManager.pause();

    //     vm.expectRevert("Pausable: paused");
    //     // creditManager.closeCreditAccount(USER, ClosureAction.LIQUIDATE_ACCOUNT, 0, LIQUIDATOR, FRIEND, 0, false);
    // }

    // /// @dev I:[CM-65]: Emergency liquidator can't close an account instead of liquidating

    // function test_I_CM_65_closeCreditAccount_reverts_when_paused_and_liquidator_tries_to_close() public {
    //     vm.startPrank(CONFIGURATOR);
    //     creditManager.pause();
    //     creditManager.addEmergencyLiquidator(LIQUIDATOR);
    //     vm.stopPrank();

    //     vm.expectRevert("Pausable: paused");
    //     // creditManager.closeCreditAccount(USER, ClosureAction.CLOSE_ACCOUNT, 0, LIQUIDATOR, FRIEND, 0, false);
    // }

    /// @dev I:[CM-66]: calcNewCumulativeIndex works correctly for various values
    function test_I_CM_66_calcNewCumulativeIndex_is_correct(
        uint128 borrowedAmount,
        uint256 indexAtOpen,
        uint256 indexNow,
        uint128 delta,
        bool isIncrease
    ) public {
        // vm.assume(borrowedAmount > 100);
        // vm.assume(uint256(borrowedAmount) + uint256(delta) <= 2 ** 128 - 1);

        // indexNow = indexNow < RAY ? indexNow + RAY : indexNow;
        // indexAtOpen = indexAtOpen < RAY ? indexAtOpen + RAY : indexNow;

        // vm.assume(indexNow <= 100 * RAY);
        // vm.assume(indexNow >= indexAtOpen);
        // vm.assume(indexNow - indexAtOpen < 10 * RAY);

        // uint256 interest = uint256((borrowedAmount * indexNow) / indexAtOpen - borrowedAmount);

        // vm.assume(interest > 1);

        // if (!isIncrease && (delta > interest)) delta %= uint128(interest);

        // CreditManagerTestInternal cmi = new CreditManagerTestInternal(
        //     creditManager.poolService(), address(withdrawalManager)
        // );

        // if (isIncrease) {
        //     uint256 newIndex = CreditLogic.calcNewCumulativeIndex(borrowedAmount, delta, indexNow, indexAtOpen, true);

        //     uint256 newInterestError = ((borrowedAmount + delta) * indexNow) / newIndex - (borrowedAmount + delta)
        //         - ((borrowedAmount * indexNow) / indexAtOpen - borrowedAmount);

        //     uint256 newTotalDebt = ((borrowedAmount + delta) * indexNow) / newIndex;

        //     assertLe((RAY * newInterestError) / newTotalDebt, 10000, "Interest error is larger than 10 ** -23");
        // } else {
        //     uint256 newIndex = cmi.calcNewCumulativeIndex(borrowedAmount, delta, indexNow, indexAtOpen, false);

        //     uint256 newTotalDebt = ((borrowedAmount * indexNow) / newIndex);
        //     uint256 newInterestError = newTotalDebt - borrowedAmount - (interest - delta);

        //     emit log_uint(indexNow);
        //     emit log_uint(indexAtOpen);
        //     emit log_uint(interest);
        //     emit log_uint(delta);
        //     emit log_uint(interest - delta);
        //     emit log_uint(newTotalDebt);
        //     emit log_uint(borrowedAmount);
        //     emit log_uint(newInterestError);

        //     assertLe((RAY * newInterestError) / newTotalDebt, 10000, "Interest error is larger than 10 ** -23");
        // }
    }

    /// @dev I:[CM-68]: fullCollateralCheck checks tokens in correct order
    function test_I_CM_68_fullCollateralCheck_is_evaluated_in_order_of_hints() public {
        (uint256 borrowedAmount, uint256 cumulativeIndexLastUpdate, uint256 cumulativeIndexNow, address creditAccount) =
            _openCreditAccount();

        uint256 daiBalance = tokenTestSuite.balanceOf(Tokens.DAI, creditAccount);

        tokenTestSuite.burn(Tokens.DAI, creditAccount, daiBalance);

        uint256 borrowAmountWithInterest = borrowedAmount * cumulativeIndexNow / cumulativeIndexLastUpdate;
        uint256 interestAccured = borrowAmountWithInterest - borrowedAmount;

        (uint256 feeInterest,,,,) = creditManager.fees();

        uint256 amountToRepay = (
            ((borrowAmountWithInterest + interestAccured * feeInterest / PERCENTAGE_FACTOR) * (10 ** 8))
                * PERCENTAGE_FACTOR / tokenTestSuite.prices(Tokens.DAI)
                / creditManager.liquidationThresholds(tokenTestSuite.addressOf(Tokens.DAI))
        ) + WAD;

        tokenTestSuite.mint(Tokens.DAI, creditAccount, amountToRepay);

        tokenTestSuite.mint(Tokens.USDC, creditAccount, USDC_ACCOUNT_AMOUNT);
        tokenTestSuite.mint(Tokens.USDT, creditAccount, 10);
        tokenTestSuite.mint(Tokens.LINK, creditAccount, 10);

        // creditManager.checkAndEnableToken(tokenTestSuite.addressOf(Tokens.USDC));
        // creditManager.checkAndEnableToken(tokenTestSuite.addressOf(Tokens.USDT));
        // creditManager.checkAndEnableToken(tokenTestSuite.addressOf(Tokens.LINK));

        uint256[] memory collateralHints = new uint256[](2);
        collateralHints[0] = creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.USDT));
        collateralHints[1] = creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.LINK));

        vm.expectCall(tokenTestSuite.addressOf(Tokens.USDT), abi.encodeCall(IERC20.balanceOf, (creditAccount)));
        vm.expectCall(tokenTestSuite.addressOf(Tokens.LINK), abi.encodeCall(IERC20.balanceOf, (creditAccount)));

        uint256 enabledTokensMap = 1 | creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.USDC))
            | creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.USDT))
            | creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.LINK));

        creditManager.fullCollateralCheck(creditAccount, enabledTokensMap, collateralHints, PERCENTAGE_FACTOR);

        // assertEq(cmi.fullCheckOrder(0), tokenTestSuite.addressOf(Tokens.USDT), "Token order incorrect");

        // assertEq(cmi.fullCheckOrder(1), tokenTestSuite.addressOf(Tokens.LINK), "Token order incorrect");

        // assertEq(cmi.fullCheckOrder(2), tokenTestSuite.addressOf(Tokens.DAI), "Token order incorrect");

        // assertEq(cmi.fullCheckOrder(3), tokenTestSuite.addressOf(Tokens.USDC), "Token order incorrect");
    }

    /// @dev I:[CM-70]: fullCollateralCheck reverts when an illegal mask is passed in collateralHints
    function test_I_CM_70_fullCollateralCheck_reverts_for_illegal_mask_in_hints() public {
        (,,, address creditAccount) = _openCreditAccount();

        vm.expectRevert(TokenNotAllowedException.selector);

        uint256[] memory ch = new uint256[](1);
        ch[0] = 3;

        uint256 enabledTokensMap = 1;

        creditManager.fullCollateralCheck(creditAccount, enabledTokensMap, ch, PERCENTAGE_FACTOR);
    }
}
