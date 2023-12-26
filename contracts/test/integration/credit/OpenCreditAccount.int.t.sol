// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import "../../../interfaces/IAddressProviderV3.sol";

import {IDegenNFTV2} from "@gearbox-protocol/core-v2/contracts/interfaces/IDegenNFTV2.sol";

import {AccountFactory} from "@gearbox-protocol/core-v2/contracts/core/AccountFactory.sol";
import {ICreditAccount} from "@gearbox-protocol/core-v2/contracts/interfaces/ICreditAccount.sol";
import {
    ICreditManagerV3,
    ICreditManagerV3Events,
    CollateralTokenData,
    ManageDebtAction,
    CollateralDebtData
} from "../../../interfaces/ICreditManagerV3.sol";

import "../../../interfaces/ICreditFacadeV3.sol";

import {PERCENTAGE_FACTOR, SECONDS_PER_YEAR} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";

// LIBS & TRAITS
import {BitMask, UNDERLYING_TOKEN_MASK} from "../../../libraries/BitMask.sol";

// TESTS
import {IntegrationTestHelper} from "../../helpers/IntegrationTestHelper.sol";
import "../../lib/constants.sol";

// SUITES
import {Tokens} from "@gearbox-protocol/sdk-gov/contracts/Tokens.sol";

// EXCEPTIONS
import "../../../interfaces/IExceptions.sol";

import {MultiCallBuilder} from "../../lib/MultiCallBuilder.sol";

uint16 constant REFERRAL_CODE = 23;
uint256 constant WETH_TEST_AMOUNT = 5 * WAD;

contract OpenCreditAccountIntegrationTest is IntegrationTestHelper, ICreditFacadeV3Events {
    using BitMask for uint256;

    /// @dev I:[OCA-1]: openCreditAccount transfers_tokens_from_pool
    function test_I_OCA_01_openCreditAccount_transfers_tokens_from_pool() public creditTest {
        address expectedCreditAccount =
            AccountFactory(addressProvider.getAddressOrRevert(AP_ACCOUNT_FACTORY, NO_VERSION_CONTROL)).head();

        uint256 blockAtOpen = block.number;
        uint256 cumulativeAtOpen = pool.baseInterestIndex();
        // pool.setCumulativeIndexNow(cumulativeAtOpen);

        tokenTestSuite.mint(Tokens.DAI, USER, DAI_ACCOUNT_AMOUNT);
        tokenTestSuite.approve(Tokens.DAI, USER, address(creditManager));

        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (DAI_ACCOUNT_AMOUNT))
            }),
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(
                    ICreditFacadeV3Multicall.addCollateral, (tokenTestSuite.addressOf(Tokens.DAI), DAI_ACCOUNT_AMOUNT / 2)
                    )
            })
        );

        // Existing address case
        vm.prank(USER);
        address creditAccount = creditFacade.openCreditAccount(USER, calls, 0);

        assertEq(creditAccount, expectedCreditAccount, "Incorrecct credit account address");

        (uint256 debt, uint256 cumulativeIndexLastUpdate,,,,,,) = creditManager.creditAccountInfo(creditAccount);

        assertEq(debt, DAI_ACCOUNT_AMOUNT, "Incorrect borrowed amount set in CA");
        assertEq(cumulativeIndexLastUpdate, cumulativeAtOpen, "Incorrect cumulativeIndexLastUpdate set in CA");

        assertEq(ICreditAccount(creditAccount).since(), blockAtOpen, "Incorrect since set in CA");

        expectBalance(Tokens.DAI, creditAccount, DAI_ACCOUNT_AMOUNT + DAI_ACCOUNT_AMOUNT / 2);
        // assertEq(pool.lendAmount(), DAI_ACCOUNT_AMOUNT, "Incorrect DAI_ACCOUNT_AMOUNT in Pool call");
        // assertEq(pool.lendAccount(), creditAccount, "Incorrect credit account in lendCreditAccount call");
        // assertEq(creditManager.creditAccounts(USER), creditAccount, "Credit account is not associated with user");
        assertEq(
            creditManager.enabledTokensMaskOf(creditAccount), UNDERLYING_TOKEN_MASK, "Incorrect enabled token mask"
        );
    }

    /// @dev I:[OCA-2]: openCreditAccount reverts if user has no NFT for degen mode
    function test_I_OCA_02_openCreditAccount_reverts_for_non_whitelisted_account() public withDegenNFT creditTest {
        (uint256 minDebt,) = creditFacade.debtLimits();

        vm.expectRevert(InsufficientBalanceException.selector);

        vm.prank(FRIEND);
        creditFacade.openCreditAccount(
            FRIEND,
            MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (minDebt))
                }),
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.addCollateral, (underlying, DAI_ACCOUNT_AMOUNT / 4))
                })
            ),
            0
        );
    }

    /// @dev I:[OCA-3]: openCreditAccount opens account and burns token
    function test_I_OCA_03_openCreditAccount_burns_token_in_whitelisted_mode() public withDegenNFT creditTest {
        IDegenNFTV2 degenNFT = IDegenNFTV2(creditFacade.degenNFT());

        uint256 startingBalance = degenNFT.balanceOf(USER);

        vm.prank(CONFIGURATOR);
        degenNFT.mint(USER, 2);

        expectBalance(address(degenNFT), USER, startingBalance + 2);

        _openTestCreditAccount();

        expectBalance(address(degenNFT), USER, startingBalance + 1);
    }

    // // /// @dev I:[OCA-4]: openCreditAccount sets correct values
    // function test_I_OCA_04_openCreditAccount_sets_correct_values() public {
    //     uint16 LEVERAGE = 300; // x3

    //     address expectedCreditAccount =
    //         AccountFactory(addressProvider.getAddressOrRevert(AP_ACCOUNT_FACTORY, NO_VERSION_CONTROL)).head();

    //     vm.prank(FRIEND);
    //     creditFacade.approveAccountTransfer(USER, true);

    //     vm.expectCall(
    //         address(creditManager),
    //         abi.encodeCall(
    //             "openCreditAccount(uint256,address)", (DAI_ACCOUNT_AMOUNT * LEVERAGE) / LEVERAGE_DECIMALS, FRIEND
    //         )
    //     );

    //     vm.expectEmit(true, true, false, true);
    //     emit OpenCreditAccount(
    //         FRIEND, expectedCreditAccount, (DAI_ACCOUNT_AMOUNT * LEVERAGE) / LEVERAGE_DECIMALS, REFERRAL_CODE
    //     );

    //     vm.expectCall(
    //         address(creditManager),
    //         abi.encodeCall(
    //             "addCollateral(address,address,address,uint256)",
    //             USER,
    //             expectedCreditAccount,
    //             underlying,
    //             DAI_ACCOUNT_AMOUNT
    //         )
    //     );

    //     vm.expectEmit(true, true, false, true);
    //     emit AddCollateral(creditAccount, FRIEND, underlying, DAI_ACCOUNT_AMOUNT);

    //     vm.prank(USER);
    //     creditFacade.openCreditAccount(DAI_ACCOUNT_AMOUNT, FRIEND, LEVERAGE, REFERRAL_CODE);
    // }

    /// @dev I:[OCA-5]: openCreditAccount and openCreditAccount reverts when debt increase is forbidden
    function test_I_OCA_05_openCreditAccount_reverts_if_borrowing_forbidden() public creditTest {
        (uint256 minDebt,) = creditFacade.debtLimits();

        vm.prank(CONFIGURATOR);
        creditConfigurator.forbidBorrowing();

        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (minDebt))
            }),
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.addCollateral, (underlying, DAI_ACCOUNT_AMOUNT / 4))
            })
        );

        vm.expectRevert(BorrowedBlockLimitException.selector);
        vm.prank(USER);
        creditFacade.openCreditAccount(USER, calls, 0);
    }

    /// @dev I:[OCA-6]: openCreditAccount runs operations in correct order
    function test_I_OCA_06_openCreditAccount_runs_operations_in_correct_order() public creditTest {
        RevocationPair[] memory revocations = new RevocationPair[](1);

        revocations[0] = RevocationPair({spender: address(this), token: underlying});

        tokenTestSuite.mint(Tokens.DAI, USER, WAD);
        tokenTestSuite.approve(Tokens.DAI, USER, address(creditManager));

        address expectedCreditAccountAddress = accountFactory.head();

        MultiCall[] memory calls = MultiCallBuilder.build(
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (DAI_ACCOUNT_AMOUNT))
            }),
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.addCollateral, (underlying, DAI_ACCOUNT_AMOUNT))
            }),
            MultiCall({
                target: address(creditFacade),
                callData: abi.encodeCall(ICreditFacadeV3Multicall.revokeAdapterAllowances, (revocations))
            })
        );

        // EXPECTED STACK TRACE & EVENTS

        vm.expectCall(address(creditManager), abi.encodeCall(ICreditManagerV3.openCreditAccount, (FRIEND)));

        vm.expectEmit(true, true, false, true);
        emit OpenCreditAccount(expectedCreditAccountAddress, FRIEND, USER, REFERRAL_CODE);

        vm.expectEmit(true, false, false, false);
        emit StartMultiCall({creditAccount: expectedCreditAccountAddress, caller: USER});

        vm.expectCall(
            address(creditManager),
            abi.encodeCall(
                ICreditManagerV3.addCollateral, (USER, expectedCreditAccountAddress, underlying, DAI_ACCOUNT_AMOUNT)
            )
        );

        vm.expectEmit(true, true, false, true);
        emit AddCollateral(expectedCreditAccountAddress, underlying, DAI_ACCOUNT_AMOUNT);

        vm.expectCall(
            address(creditManager),
            abi.encodeCall(ICreditManagerV3.revokeAdapterAllowances, (expectedCreditAccountAddress, revocations))
        );

        vm.expectEmit(false, false, false, true);
        emit FinishMultiCall();

        vm.expectCall(
            address(creditManager),
            abi.encodeCall(
                ICreditManagerV3.fullCollateralCheck,
                (expectedCreditAccountAddress, 1, new uint256[](0), PERCENTAGE_FACTOR, false)
            )
        );

        vm.prank(USER);
        creditFacade.openCreditAccount(FRIEND, calls, REFERRAL_CODE);
    }

    /// @dev I:[OCA-7]: openCreditAccount cant open credit account with hf <1;
    function test_I_OCA_07_openCreditAccount_cant_open_credit_account_with_hf_less_one(uint256 amount, uint8 token1)
        public
        creditTest
    {
        amount = bound(amount, 10000, DAI_ACCOUNT_AMOUNT);
        token1 = uint8(bound(token1, 1, creditManager.collateralTokensCount() - 1));

        tokenTestSuite.mint(Tokens.DAI, address(creditManager.pool()), type(uint96).max);

        vm.prank(CONFIGURATOR);
        creditConfigurator.setMaxDebtPerBlockMultiplier(type(uint8).max);

        vm.prank(CONFIGURATOR);
        creditConfigurator.setMinDebtLimit(1);

        vm.prank(CONFIGURATOR);
        creditConfigurator.setMaxDebtLimit(type(uint96).max);

        (address collateral,) = creditManager.collateralTokenByMask(1 << token1);

        tokenTestSuite.mint(collateral, USER, type(uint96).max);

        tokenTestSuite.approve(collateral, USER, address(creditManager));

        uint256 lt = creditManager.liquidationThresholds(collateral);

        uint256 twvUSD = priceOracle.convertToUSD(amount * lt, collateral)
            + priceOracle.convertToUSD(DAI_ACCOUNT_AMOUNT * DEFAULT_UNDERLYING_LT, underlying);

        uint256 borrowedAmountUSD = priceOracle.convertToUSD(DAI_ACCOUNT_AMOUNT * PERCENTAGE_FACTOR, underlying);

        bool shouldRevert = twvUSD < borrowedAmountUSD;

        if (shouldRevert) {
            vm.expectRevert(NotEnoughCollateralException.selector);
        }

        vm.prank(USER);
        creditFacade.openCreditAccount(
            USER,
            MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (DAI_ACCOUNT_AMOUNT))
                }),
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.addCollateral, (collateral, amount))
                })
            ),
            REFERRAL_CODE
        );
    }

    /// @dev I:[OCA-11]: openCreditAccount no longer works if the CreditFacadeV3 is expired
    function test_I_OCA_11_openCreditAccount_reverts_on_expired_CreditFacade() public expirableCase creditTest {
        vm.warp(block.timestamp + 1);

        vm.expectRevert(NotAllowedAfterExpirationException.selector);

        vm.prank(USER);
        creditFacade.openCreditAccount(
            USER,
            MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (DAI_ACCOUNT_AMOUNT))
                }),
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.addCollateral, (underlying, DAI_ACCOUNT_AMOUNT / 4))
                })
            ),
            0
        );
    }

    /// @dev I:[OCA-12]: openCreditAccount correctly wraps ETH
    function test_I_OCA_12_openCreditAccount_correctly_wraps_ETH() public creditTest {
        /// - openCreditAccount

        _prepareForWETHTest();

        vm.prank(USER);
        creditFacade.openCreditAccount{value: WETH_TEST_AMOUNT}(
            USER,
            MultiCallBuilder.build(
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (DAI_ACCOUNT_AMOUNT))
                }),
                MultiCall({
                    target: address(creditFacade),
                    callData: abi.encodeCall(ICreditFacadeV3Multicall.addCollateral, (underlying, DAI_ACCOUNT_AMOUNT / 4))
                })
            ),
            0
        );
        _checkForWETHTest();
    }

    /// @dev I:[OCA-13]: openCreditAccount with zero debt works correctly
    function test_I_OCA_14_openCreditAccount_sets_zero_debt_flag() public creditTest {
        address expectedCreditAccount =
            AccountFactory(addressProvider.getAddressOrRevert(AP_ACCOUNT_FACTORY, NO_VERSION_CONTROL)).head();

        uint256 blockAtOpen = block.number;
        // pool.setCumulativeIndexNow(cumulativeAtOpen);

        MultiCall[] memory calls = MultiCallBuilder.build();

        // Existing address case
        vm.prank(USER);
        address creditAccount = creditFacade.openCreditAccount(USER, calls, 0);

        assertEq(creditAccount, expectedCreditAccount, "Incorrecct credit account address");

        (uint256 debt,,,,,,,) = creditManager.creditAccountInfo(creditAccount);

        assertEq(debt, 0, "Incorrect borrowed amount set in CA");

        assertEq(ICreditAccount(creditAccount).since(), blockAtOpen, "Incorrect since set in CA");

        expectBalance(Tokens.DAI, creditAccount, 0);

        assertEq(creditManager.enabledTokensMaskOf(creditAccount), 0, "Incorrect enabled token mask");
    }
}
