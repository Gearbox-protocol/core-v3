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

import {IPriceOracleV2, IPriceOracleV2Ext} from "@gearbox-protocol/core-v2/contracts/interfaces/IPriceOracle.sol";
import {IWETHGateway} from "../../../interfaces/IWETHGateway.sol";
import {IWithdrawalManager} from "../../../interfaces/IWithdrawalManager.sol";

import {CreditManagerV3} from "../../../credit/CreditManagerV3.sol";

import {IPoolService} from "@gearbox-protocol/core-v2/contracts/interfaces/IPoolService.sol";

import {IWETH} from "@gearbox-protocol/core-v2/contracts/interfaces/external/IWETH.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "@gearbox-protocol/core-v2/contracts/test/mocks/token/ERC20Mock.sol";
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/PercentageMath.sol";

// LIBS & TRAITS
import {BitMask} from "../../../libraries/BitMask.sol";
// TESTS

import "../../lib/constants.sol";
import {BalanceHelper} from "../../helpers/BalanceHelper.sol";

// EXCEPTIONS
import {TokenAlreadyAddedException} from "../../../interfaces/IExceptions.sol";

// MOCKS
import {PriceFeedMock} from "@gearbox-protocol/core-v2/contracts/test/mocks/oracles/PriceFeedMock.sol";
import {PoolServiceMock} from "../../mocks/pool/PoolServiceMock.sol";
import {TargetContractMock} from "@gearbox-protocol/core-v2/contracts/test/mocks/adapters/TargetContractMock.sol";
import {
    ERC20ApproveRestrictedRevert,
    ERC20ApproveRestrictedFalse
} from "@gearbox-protocol/core-v2/contracts/test/mocks/token/ERC20ApproveRestricted.sol";

// SUITES
import {TokensTestSuite} from "../../suites/TokensTestSuite.sol";
import {Tokens} from "../../config/Tokens.sol";
import {CreditManagerTestSuite} from "../../suites/CreditManagerTestSuite.sol";

import {CreditManagerTestInternal} from "../../mocks/credit/CreditManagerTestInternal.sol";

import {CreditConfig} from "../../config/CreditConfig.sol";

// EXCEPTIONS
import "../../../interfaces/IExceptions.sol";
import "forge-std/console.sol";

/// @title AddressRepository
/// @notice Stores addresses of deployed contracts
contract CreditManagerTest is DSTest, ICreditManagerV3Events, BalanceHelper {
    using BitMask for uint256;

    CheatCodes evm = CheatCodes(HEVM_ADDRESS);

    CreditManagerTestSuite cms;

    IAddressProvider addressProvider;
    IWETH wethToken;

    AccountFactory af;
    CreditManagerV3 creditManager;
    PoolServiceMock poolMock;
    IPriceOracleV2 priceOracle;
    IWETHGateway wethGateway;
    IWithdrawalManager withdrawalManager;
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
        cms = new CreditManagerTestSuite(creditConfig, internalSuite, false, 1);

        acl = cms.acl();

        addressProvider = cms.addressProvider();
        af = cms.af();

        poolMock = cms.poolMock();
        withdrawalManager = cms.withdrawalManager();

        creditManager = cms.creditManager();

        priceOracle = creditManager.priceOracle();
        underlying = creditManager.underlying();
        wethGateway = IWETHGateway(creditManager.wethGateway());
    }

    /// @dev Opens credit account for testing management functions
    function _openCreditAccount()
        internal
        returns (
            uint256 borrowedAmount,
            uint256 cumulativeIndexAtOpen,
            uint256 cumulativeIndexAtClose,
            address creditAccount
        )
    {
        return cms.openCreditAccount();
    }

    function expectTokenIsEnabled(address creditAccount, Tokens t, bool expectedState) internal {
        bool state = creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(t))
            & creditManager.enabledTokensMap(creditAccount) != 0;
        assertTrue(
            state == expectedState,
            string(
                abi.encodePacked(
                    "Token ",
                    tokenTestSuite.symbols(t),
                    state ? " enabled as not expected" : " not enabled as expected "
                )
            )
        );
    }

    function mintBalance(address creditAccount, Tokens t, uint256 amount, bool enable) internal {
        tokenTestSuite.mint(t, creditAccount, amount);
        // if (enable) {
        //     creditManager.checkAndEnableToken(tokenTestSuite.addressOf(t));
        // }
    }

    function _addAndEnableTokens(address creditAccount, uint256 numTokens, uint256 balance) internal {
        for (uint256 i = 0; i < numTokens; i++) {
            ERC20Mock t = new ERC20Mock("new token", "nt", 18);
            PriceFeedMock pf = new PriceFeedMock(10**8, 8);

            evm.startPrank(CONFIGURATOR);
            creditManager.addToken(address(t));
            IPriceOracleV2Ext(address(priceOracle)).addPriceFeed(address(t), address(pf));
            creditManager.setLiquidationThreshold(address(t), 8000);
            evm.stopPrank();

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

    function enableTokensMoreThanLimit(address creditAccount) internal {
        uint256 maxAllowedEnabledTokenLength = creditManager.maxAllowedEnabledTokenLength();
        _addAndEnableTokens(creditAccount, maxAllowedEnabledTokenLength, 2);
    }

    function _openAccountAndTransferToCF() internal returns (address creditAccount) {
        (,,, creditAccount) = _openCreditAccount();
        creditManager.transferAccountOwnership(creditAccount, address(this));
    }

    function _baseFullCollateralCheck(address creditAccount) internal {
        // TODO: CHANGE
        creditManager.fullCollateralCheck(creditAccount, 0, new uint256[](0), 10000);
    }

    ///
    ///
    ///  TESTS
    ///
    ///
    /// @dev [CM-1]: credit manager reverts if were called non-creditFacade
    function test_CM_01_constructor_sets_correct_values() public {
        creditManager = new CreditManagerV3(address(poolMock), address(withdrawalManager));

        assertEq(address(creditManager.poolService()), address(poolMock), "Incorrect poolSerivice");

        assertEq(address(creditManager.pool()), address(poolMock), "Incorrect pool");

        assertEq(creditManager.underlying(), tokenTestSuite.addressOf(Tokens.DAI), "Incorrect underlying");

        (address token, uint16 lt) = creditManager.collateralTokens(0);

        assertEq(token, tokenTestSuite.addressOf(Tokens.DAI), "Incorrect underlying");

        assertEq(
            creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.DAI)),
            1,
            "Incorrect token mask for underlying token"
        );

        assertEq(lt, 0, "Incorrect LT for underlying");

        assertEq(creditManager.wethAddress(), addressProvider.getWethToken(), "Incorrect WETH token");

        assertEq(address(creditManager.wethGateway()), addressProvider.getWETHGateway(), "Incorrect WETH Gateway");

        assertEq(address(creditManager.priceOracle()), addressProvider.getPriceOracle(), "Incorrect Price oracle");

        assertEq(address(creditManager.creditConfigurator()), address(this), "Incorrect creditConfigurator");
    }

    /// @dev [CM-2]:credit account management functions revert if were called non-creditFacade
    /// Functions list:
    /// - openCreditAccount
    /// - closeCreditAccount
    /// - manadgeDebt
    /// - addCollateral
    /// - transferOwnership
    /// All these functions have creditFacadeOnly modifier
    function test_CM_02_credit_account_management_functions_revert_if_not_called_by_creditFacadeCall() public {
        assertEq(creditManager.creditFacade(), address(this));

        evm.startPrank(USER);

        evm.expectRevert(CallerNotCreditFacadeException.selector);
        creditManager.openCreditAccount(200000, address(this));

        // evm.expectRevert(CallerNotCreditFacadeException.selector);
        // creditManager.closeCreditAccount(
        //     DUMB_ADDRESS, ClosureAction.LIQUIDATE_ACCOUNT, 0, DUMB_ADDRESS, DUMB_ADDRESS, type(uint256).max, false
        // );

        evm.expectRevert(CallerNotCreditFacadeException.selector);
        creditManager.manageDebt(DUMB_ADDRESS, 100, 0, ManageDebtAction.INCREASE_DEBT);

        evm.expectRevert(CallerNotCreditFacadeException.selector);
        creditManager.addCollateral(DUMB_ADDRESS, DUMB_ADDRESS, DUMB_ADDRESS, 100);

        evm.expectRevert(CallerNotCreditFacadeException.selector);
        creditManager.transferAccountOwnership(DUMB_ADDRESS, DUMB_ADDRESS);

        evm.stopPrank();
    }

    /// @dev [CM-3]:credit account execution functions revert if were called non-creditFacade & non-adapters
    /// Functions list:
    /// - approveCreditAccount
    /// - executeOrder
    /// - checkAndEnableToken
    /// - fullCollateralCheck
    /// - disableToken
    /// - changeEnabledTokens
    function test_CM_03_credit_account_execution_functions_revert_if_not_called_by_creditFacade_or_adapters() public {
        assertEq(creditManager.creditFacade(), address(this));

        evm.startPrank(USER);

        evm.expectRevert(CallerNotAdapterException.selector);
        creditManager.approveCreditAccount(DUMB_ADDRESS, 100);

        evm.expectRevert(CallerNotAdapterException.selector);
        creditManager.executeOrder(bytes("0"));

        evm.expectRevert(CallerNotCreditFacadeException.selector);
        creditManager.fullCollateralCheck(DUMB_ADDRESS, 0, new uint256[](0), 10000);

        evm.stopPrank();
    }

    /// @dev [CM-4]:credit account configuration functions revert if were called non-configurator
    /// Functions list:
    /// - addToken
    /// - setParams
    /// - setLiquidationThreshold
    /// - setForbidMask
    /// - setContractAllowance
    /// - upgradeContracts
    /// - setCreditConfigurator
    /// - addEmergencyLiquidator
    /// - removeEmergenceLiquidator
    function test_CM_04_credit_account_configurator_functions_revert_if_not_called_by_creditConfigurator() public {
        assertEq(creditManager.creditFacade(), address(this));

        evm.startPrank(USER);

        evm.expectRevert(CallerNotConfiguratorException.selector);
        creditManager.addToken(DUMB_ADDRESS);

        evm.expectRevert(CallerNotConfiguratorException.selector);
        creditManager.setParams(0, 0, 0, 0, 0);

        evm.expectRevert(CallerNotConfiguratorException.selector);
        creditManager.setLiquidationThreshold(DUMB_ADDRESS, 0);

        evm.expectRevert(CallerNotConfiguratorException.selector);
        creditManager.setContractAllowance(DUMB_ADDRESS, DUMB_ADDRESS);

        evm.expectRevert(CallerNotConfiguratorException.selector);
        creditManager.setCreditFacade(DUMB_ADDRESS);

        evm.expectRevert(CallerNotConfiguratorException.selector);
        creditManager.setPriceOracle(DUMB_ADDRESS);

        evm.expectRevert(CallerNotConfiguratorException.selector);
        creditManager.setCreditConfigurator(DUMB_ADDRESS);

        evm.expectRevert(CallerNotConfiguratorException.selector);
        creditManager.setMaxEnabledTokens(255);

        evm.stopPrank();
    }

    // TODO: REMOVE OUTDATED
    // /// @dev [CM-5]:credit account management+execution functions revert if were called non-creditFacade
    // /// Functions list:
    // /// - openCreditAccount
    // /// - closeCreditAccount
    // /// - manadgeDebt
    // /// - addCollateral
    // /// - transferOwnership
    // /// All these functions have whenNotPaused modifier
    // function test_CM_05_pause_pauses_management_functions() public {
    //     address root = acl.owner();
    //     evm.prank(root);

    //     acl.addPausableAdmin(root);

    //     evm.prank(root);
    //     creditManager.pause();

    //     assertEq(creditManager.creditFacade(), address(this));

    //     evm.expectRevert(bytes(PAUSABLE_ERROR));
    //     creditManager.openCreditAccount(200000, address(this));

    //     // evm.expectRevert(bytes(PAUSABLE_ERROR));
    //     // creditManager.closeCreditAccount(
    //     //     DUMB_ADDRESS, ClosureAction.LIQUIDATE_ACCOUNT, 0, DUMB_ADDRESS, DUMB_ADDRESS, type(uint256).max, false
    //     // );

    //     evm.expectRevert(bytes(PAUSABLE_ERROR));
    //     creditManager.manageDebt(DUMB_ADDRESS, 100, ManageDebtAction.INCREASE_DEBT);

    //     evm.expectRevert(bytes(PAUSABLE_ERROR));
    //     creditManager.addCollateral(DUMB_ADDRESS, DUMB_ADDRESS, DUMB_ADDRESS, 100);

    //     evm.expectRevert(bytes(PAUSABLE_ERROR));
    //     creditManager.transferAccountOwnership(DUMB_ADDRESS, DUMB_ADDRESS);

    //     evm.expectRevert(bytes(PAUSABLE_ERROR));
    //     creditManager.approveCreditAccount(DUMB_ADDRESS, DUMB_ADDRESS, 100);

    //     evm.expectRevert(bytes(PAUSABLE_ERROR));
    //     creditManager.executeOrder(DUMB_ADDRESS, bytes("dd"));
    // }

    //
    // REVERTS IF CREDIT ACCOUNT NOT EXISTS
    //

    /// @dev [CM-6A]: management function reverts if account not exists
    /// Functions list:
    /// - getCreditAccountOrRevert
    /// - closeCreditAccount
    /// - transferOwnership

    function test_CM_06A_management_functions_revert_if_account_does_not_exist() public {
        // evm.expectRevert(CreditAccountNotExistsException.selector);
        // creditManager.getCreditAccountOrRevert(USER);

        // evm.expectRevert(CreditAccountNotExistsException.selector);
        // creditManager.closeCreditAccount(
        //     USER, ClosureAction.LIQUIDATE_ACCOUNT, 0, DUMB_ADDRESS, DUMB_ADDRESS, type(uint256).max, false
        // );

        evm.expectRevert(CreditAccountNotExistsException.selector);
        creditManager.transferAccountOwnership(USER, DUMB_ADDRESS);
    }

    /// @dev [CM-6A]: external call functions revert when the Credit Facade has no account
    /// Functions list:
    /// - executeOrder
    /// - approveCreditAccount
    function test_CM_06B_extenrnal_ca_only_functions_revert_when_ec_is_not_set() public {
        address token = tokenTestSuite.addressOf(Tokens.DAI);

        evm.prank(CONFIGURATOR);
        creditManager.setContractAllowance(ADAPTER, DUMB_ADDRESS);

        evm.prank(ADAPTER);
        evm.expectRevert(ExternalCallCreditAccountNotSetException.selector);
        creditManager.approveCreditAccount(token, 100);

        // / TODO: decide about test
        evm.prank(ADAPTER);
        evm.expectRevert(ExternalCallCreditAccountNotSetException.selector);
        creditManager.executeOrder(bytes("dd"));
    }

    ///
    ///  OPEN CREDIT ACCOUNT
    ///

    /// @dev [CM-7]: openCreditAccount reverts if zero address or address exists
    function test_CM_07_openCreditAccount_reverts_if_address_exists() public {
        // // Existing address case
        // creditManager.openCreditAccount(1, USER);
        // evm.expectRevert(UserAlreadyHasAccountException.selector);
        // creditManager.openCreditAccount(1, USER);
    }

    /// @dev [CM-8]: openCreditAccount sets correct values and transfers tokens from pool
    function test_CM_08_openCreditAccount_sets_correct_values_and_transfers_tokens_from_pool() public {
        address expectedCreditAccount = AccountFactory(addressProvider.getAccountFactory()).head();

        uint256 blockAtOpen = block.number;
        uint256 cumulativeAtOpen = 1012;
        poolMock.setCumulative_RAY(cumulativeAtOpen);

        // Existing address case
        address creditAccount = creditManager.openCreditAccount(DAI_ACCOUNT_AMOUNT, USER);
        assertEq(creditAccount, expectedCreditAccount, "Incorrecct credit account address");

        (uint256 debt, uint256 cumulativeIndexAtOpen,,,,) = creditManager.creditAccountInfo(creditAccount);

        assertEq(debt, DAI_ACCOUNT_AMOUNT, "Incorrect borrowed amount set in CA");
        assertEq(cumulativeIndexAtOpen, cumulativeAtOpen, "Incorrect cumulativeIndexAtOpen set in CA");

        assertEq(ICreditAccount(creditAccount).since(), blockAtOpen, "Incorrect since set in CA");

        expectBalance(Tokens.DAI, creditAccount, DAI_ACCOUNT_AMOUNT);
        assertEq(poolMock.lendAmount(), DAI_ACCOUNT_AMOUNT, "Incorrect DAI_ACCOUNT_AMOUNT in Pool call");
        assertEq(poolMock.lendAccount(), creditAccount, "Incorrect credit account in lendCreditAccount call");
        // assertEq(creditManager.creditAccounts(USER), creditAccount, "Credit account is not associated with user");
        assertEq(creditManager.enabledTokensMap(creditAccount), 0, "Incorrect enabled token mask");
    }

    //
    // CLOSE CREDIT ACCOUNT
    //

    /// @dev [CM-9]: closeCreditAccount returns credit account to factory and
    /// remove borrower from creditAccounts mapping
    function test_CM_09_close_credit_account_returns_credit_account_and_remove_borrower_from_map() public {
        (uint256 borrowedAmount,,, address creditAccount) = _openCreditAccount();

        assertTrue(
            creditAccount != AccountFactory(addressProvider.getAccountFactory()).tail(),
            "credit account is already in tail!"
        );

        // Transfer additional borrowedAmount. After that underluying token balance = 2 * borrowedAmount
        tokenTestSuite.mint(Tokens.DAI, creditAccount, borrowedAmount);

        // Increase block number cause it's forbidden to close credit account in the same block
        evm.roll(block.number + 1);

        creditManager.closeCreditAccount(
            creditAccount, ClosureAction.CLOSE_ACCOUNT, 0, USER, USER, 0, 0, DAI_ACCOUNT_AMOUNT, false
        );

        assertEq(
            creditAccount,
            AccountFactory(addressProvider.getAccountFactory()).tail(),
            "credit account is not in accountFactory tail!"
        );

        // evm.expectRevert(CreditAccountNotExistsException.selector);
        // creditManager.getCreditAccountOrRevert(USER);
    }

    /// @dev [CM-10]: closeCreditAccount returns undelying tokens if credit account balance > amounToPool
    ///
    /// This test covers the case:
    /// Closure type: CLOSURE
    /// Underlying balance: > amountToPool
    /// Send all assets: false
    ///
    function test_CM_10_close_credit_account_returns_underlying_token_if_not_liquidated() public {
        (uint256 borrowedAmount, uint256 cumulativeIndexAtOpen, uint256 cumulativeIndexAtClose, address creditAccount) =
            _openCreditAccount();

        uint256 poolBalanceBefore = tokenTestSuite.balanceOf(Tokens.DAI, address(poolMock));

        // Transfer additional borrowedAmount. After that underluying token balance = 2 * borrowedAmount
        tokenTestSuite.mint(Tokens.DAI, creditAccount, borrowedAmount);

        uint256 interestAccrued = (borrowedAmount * cumulativeIndexAtClose) / cumulativeIndexAtOpen - borrowedAmount;

        (uint16 feeInterest,,,,) = creditManager.fees();

        uint256 profit = (interestAccrued * feeInterest) / PERCENTAGE_FACTOR;

        uint256 amountToPool = borrowedAmount + interestAccrued + profit;

        evm.expectCall(
            address(poolMock),
            abi.encodeWithSelector(IPoolService.repayCreditAccount.selector, borrowedAmount, profit, 0)
        );

        (uint256 remainingFunds, uint256 loss) = creditManager.closeCreditAccount(
            creditAccount,
            ClosureAction.CLOSE_ACCOUNT,
            0,
            USER,
            FRIEND,
            1,
            0,
            DAI_ACCOUNT_AMOUNT + interestAccrued,
            false
        );

        assertEq(remainingFunds, 0, "Remaining funds is not zero!");

        assertEq(loss, 0, "Loss is not zero");

        expectBalance(Tokens.DAI, creditAccount, 1);

        expectBalance(Tokens.DAI, address(poolMock), poolBalanceBefore + amountToPool);

        expectBalance(Tokens.DAI, FRIEND, 2 * borrowedAmount - amountToPool - 1, "Incorrect amount were paid back");
    }

    /// @dev [CM-11]: closeCreditAccount sets correct values and transfers tokens from pool
    ///
    /// This test covers the case:
    /// Closure type: CLOSURE
    /// Underlying balance: < amountToPool
    /// Send all assets: false
    ///
    function test_CM_11_close_credit_account_charges_caller_if_underlying_token_not_enough() public {
        (uint256 borrowedAmount, uint256 cumulativeIndexAtOpen, uint256 cumulativeIndexAtClose, address creditAccount) =
            _openCreditAccount();

        uint256 poolBalanceBefore = tokenTestSuite.balanceOf(Tokens.DAI, address(poolMock));

        // Transfer funds to USER account to be able to cover extra cost
        tokenTestSuite.mint(Tokens.DAI, USER, borrowedAmount);

        uint256 interestAccrued = (borrowedAmount * cumulativeIndexAtClose) / cumulativeIndexAtOpen - borrowedAmount;

        (uint16 feeInterest,,,,) = creditManager.fees();

        uint256 profit = (interestAccrued * feeInterest) / PERCENTAGE_FACTOR;

        uint256 amountToPool = borrowedAmount + interestAccrued + profit;

        evm.expectCall(
            address(poolMock),
            abi.encodeWithSelector(IPoolService.repayCreditAccount.selector, borrowedAmount, profit, 0)
        );

        (uint256 remainingFunds, uint256 loss) = creditManager.closeCreditAccount(
            creditAccount,
            ClosureAction.CLOSE_ACCOUNT,
            0,
            USER,
            FRIEND,
            1,
            0,
            DAI_ACCOUNT_AMOUNT + interestAccrued,
            false
        );
        assertEq(remainingFunds, 0, "Remaining funds is not zero!");

        assertEq(loss, 0, "Loss is not zero");

        expectBalance(Tokens.DAI, creditAccount, 1, "Credit account balance != 1");

        expectBalance(Tokens.DAI, address(poolMock), poolBalanceBefore + amountToPool);

        expectBalance(Tokens.DAI, USER, 2 * borrowedAmount - amountToPool - 1, "Incorrect amount were paid back");

        expectBalance(Tokens.DAI, FRIEND, 0, "Incorrect amount were paid back");
    }

    /// @dev [CM-12]: closeCreditAccount sets correct values and transfers tokens from pool
    ///
    /// This test covers the case:
    /// Closure type: LIQUIDATION / LIQUIDATION_EXPIRED
    /// Underlying balance: > amountToPool
    /// Send all assets: false
    /// Remaining funds: 0
    ///
    function test_CM_12_close_credit_account_charges_caller_if_underlying_token_not_enough() public {
        for (uint256 i = 0; i < 2; i++) {
            uint256 friendBalanceBefore = tokenTestSuite.balanceOf(Tokens.DAI, FRIEND);

            ClosureAction action = i == 1 ? ClosureAction.LIQUIDATE_EXPIRED_ACCOUNT : ClosureAction.LIQUIDATE_ACCOUNT;
            uint256 interestAccrued;
            uint256 borrowedAmount;
            address creditAccount;

            {
                uint256 cumulativeIndexAtOpen;
                uint256 cumulativeIndexAtClose;
                (borrowedAmount, cumulativeIndexAtOpen, cumulativeIndexAtClose, creditAccount) = _openCreditAccount();

                interestAccrued = (borrowedAmount * cumulativeIndexAtClose) / cumulativeIndexAtOpen - borrowedAmount;
            }

            uint256 poolBalanceBefore = tokenTestSuite.balanceOf(Tokens.DAI, address(poolMock));
            uint256 discount;

            {
                (,, uint16 liquidationDiscount,, uint16 liquidationDiscountExpired) = creditManager.fees();
                discount = action == ClosureAction.LIQUIDATE_ACCOUNT ? liquidationDiscount : liquidationDiscountExpired;
            }

            // uint256 totalValue = borrowedAmount;
            uint256 amountToPool = (borrowedAmount * discount) / PERCENTAGE_FACTOR;

            {
                uint256 loss = borrowedAmount + interestAccrued - amountToPool;

                evm.expectCall(
                    address(poolMock),
                    abi.encodeWithSelector(IPoolService.repayCreditAccount.selector, borrowedAmount, 0, loss)
                );
            }
            {
                uint256 a = borrowedAmount + interestAccrued;

                (uint256 remainingFunds,) = creditManager.closeCreditAccount(
                    creditAccount, action, borrowedAmount, LIQUIDATOR, FRIEND, 1, 0, a, false
                );
            }

            expectBalance(Tokens.DAI, creditAccount, 1, "Credit account balance != 1");

            expectBalance(Tokens.DAI, address(poolMock), poolBalanceBefore + amountToPool);

            expectBalance(
                Tokens.DAI,
                FRIEND,
                friendBalanceBefore + (borrowedAmount * (PERCENTAGE_FACTOR - discount)) / PERCENTAGE_FACTOR
                    - (i == 2 ? 0 : 1),
                "Incorrect amount were paid to liqiudator friend address"
            );
        }
    }

    /// @dev [CM-13]: openCreditAccount sets correct values and transfers tokens from pool
    ///
    /// This test covers the case:
    /// Closure type: LIQUIDATION / LIQUIDATION_EXPIRED
    /// Underlying balance: < amountToPool
    /// Send all assets: false
    /// Remaining funds: >0
    ///

    function test_CM_13_close_credit_account_charges_caller_if_underlying_token_not_enough() public {
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
                uint256 cumulativeIndexAtOpen;
                uint256 cumulativeIndexAtClose;
                (borrowedAmount, cumulativeIndexAtOpen, cumulativeIndexAtClose, creditAccount) = _openCreditAccount();

                interestAccrued = (borrowedAmount * cumulativeIndexAtClose) / cumulativeIndexAtOpen - borrowedAmount;

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

            uint256 poolBalanceBefore = tokenTestSuite.balanceOf(Tokens.DAI, address(poolMock));

            tokenTestSuite.mint(Tokens.DAI, LIQUIDATOR, totalValue);
            expectBalance(Tokens.DAI, USER, 0, "USER has non-zero balance");
            expectBalance(Tokens.DAI, FRIEND, 0, "FRIEND has non-zero balance");
            expectBalance(Tokens.DAI, LIQUIDATOR, totalValue, "LIQUIDATOR has incorrect initial balance");

            expectBalance(Tokens.DAI, creditAccount, borrowedAmount, "creditAccount has incorrect initial balance");

            evm.expectCall(
                address(poolMock),
                abi.encodeWithSelector(IPoolService.repayCreditAccount.selector, borrowedAmount, profit, 0)
            );

            uint256 remainingFunds;

            {
                uint256 loss;

                uint256 a = borrowedAmount + interestAccrued;
                (remainingFunds, loss) = creditManager.closeCreditAccount(
                    creditAccount,
                    i == 1 ? ClosureAction.LIQUIDATE_EXPIRED_ACCOUNT : ClosureAction.LIQUIDATE_ACCOUNT,
                    totalValue,
                    LIQUIDATOR,
                    FRIEND,
                    1,
                    0,
                    a,
                    false
                );

                assertLe(expectedRemainingFunds - remainingFunds, 2, "Incorrect remaining funds");

                assertEq(loss, 0, "Loss can't be positive with remaining funds");
            }

            {
                expectBalance(Tokens.DAI, creditAccount, 1, "Credit account balance != 1");
                expectBalance(Tokens.DAI, USER, remainingFunds, "USER get incorrect amount as remaning funds");

                expectBalance(Tokens.DAI, address(poolMock), poolBalanceBefore + amountToPool, "INCORRECT POOL BALANCE");
            }

            expectBalance(
                Tokens.DAI,
                LIQUIDATOR,
                totalValue + borrowedAmount - amountToPool - remainingFunds - 1,
                "Incorrect amount were paid to lqiudaidator"
            );
        }
    }

    /// @dev [CM-14]: closeCreditAccount sends assets depends on sendAllAssets flag
    ///
    /// This test covers the case:
    /// Closure type: LIQUIDATION
    /// Underlying balance: < amountToPool
    /// Send all assets: false
    /// Remaining funds: >0
    ///

    function test_CM_14_close_credit_account_with_nonzero_skipTokenMask_sends_correct_tokens() public {
        (uint256 borrowedAmount,,, address creditAccount) = _openCreditAccount();
        creditManager.transferAccountOwnership(creditAccount, address(this));

        tokenTestSuite.mint(Tokens.DAI, creditAccount, borrowedAmount);
        tokenTestSuite.mint(Tokens.WETH, creditAccount, WETH_EXCHANGE_AMOUNT);
        // creditManager.checkAndEnableToken(tokenTestSuite.addressOf(Tokens.WETH));

        tokenTestSuite.mint(Tokens.USDC, creditAccount, USDC_EXCHANGE_AMOUNT);
        // creditManager.checkAndEnableToken(tokenTestSuite.addressOf(Tokens.USDC));

        tokenTestSuite.mint(Tokens.LINK, creditAccount, LINK_EXCHANGE_AMOUNT);
        // creditManager.checkAndEnableToken(tokenTestSuite.addressOf(Tokens.LINK));

        uint256 wethTokenMask = creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.WETH));
        uint256 usdcTokenMask = creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.USDC));
        uint256 linkTokenMask = creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.LINK));

        creditManager.transferAccountOwnership(creditAccount, USER);

        creditManager.closeCreditAccount(
            creditAccount,
            ClosureAction.CLOSE_ACCOUNT,
            0,
            USER,
            FRIEND,
            wethTokenMask | usdcTokenMask | linkTokenMask,
            wethTokenMask | usdcTokenMask,
            DAI_ACCOUNT_AMOUNT,
            false
        );

        expectBalance(Tokens.WETH, FRIEND, 0);
        expectBalance(Tokens.WETH, creditAccount, WETH_EXCHANGE_AMOUNT);

        expectBalance(Tokens.USDC, FRIEND, 0);
        expectBalance(Tokens.USDC, creditAccount, USDC_EXCHANGE_AMOUNT);

        expectBalance(Tokens.LINK, FRIEND, LINK_EXCHANGE_AMOUNT - 1);
    }

    /// @dev [CM-16]: closeCreditAccount sends ETH for WETH creditManger to borrower
    /// CASE: CLOSURE
    /// Underlying token: WETH
    function test_CM_16_close_weth_credit_account_sends_eth_to_borrower() public {
        // It takes "clean" address which doesn't holds any assets

        _connectCreditManagerSuite(Tokens.WETH, false);

        /// CLOSURE CASE
        (uint256 borrowedAmount, uint256 cumulativeIndexAtOpen, uint256 cumulativeIndexAtClose, address creditAccount) =
            _openCreditAccount();

        // Transfer additional borrowedAmount. After that underluying token balance = 2 * borrowedAmount
        tokenTestSuite.mint(Tokens.WETH, creditAccount, borrowedAmount);

        uint256 interestAccrued = (borrowedAmount * cumulativeIndexAtClose) / cumulativeIndexAtOpen - borrowedAmount;

        // creditManager.closeCreditAccount(USER, ClosureAction.CLOSE_ACCOUNT, 0, USER, USER, 0, true);

        creditManager.closeCreditAccount(
            creditAccount, ClosureAction.CLOSE_ACCOUNT, 0, USER, USER, 1, 0, borrowedAmount + interestAccrued, true
        );

        expectBalance(Tokens.WETH, creditAccount, 1);

        (uint16 feeInterest,,,,) = creditManager.fees();

        uint256 profit = (interestAccrued * feeInterest) / PERCENTAGE_FACTOR;

        uint256 amountToPool = borrowedAmount + interestAccrued + profit;

        assertEq(
            wethGateway.balanceOf(USER),
            2 * borrowedAmount - amountToPool - 1,
            "Incorrect amount deposited on wethGateway"
        );
    }

    /// @dev [CM-17]: closeCreditAccount sends ETH for WETH creditManger to borrower
    /// CASE: CLOSURE
    /// Underlying token: DAI
    function test_CM_17_close_dai_credit_account_sends_eth_to_borrower() public {
        /// CLOSURE CASE
        (uint256 borrowedAmount,,, address creditAccount) = _openCreditAccount();
        creditManager.transferAccountOwnership(creditAccount, address(this));

        // Transfer additional borrowedAmount. After that underluying token balance = 2 * borrowedAmount
        tokenTestSuite.mint(Tokens.DAI, creditAccount, borrowedAmount);

        // Adds WETH to test how it would be converted
        tokenTestSuite.mint(Tokens.WETH, creditAccount, WETH_EXCHANGE_AMOUNT);

        uint256 wethTokenMask = creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.WETH));
        uint256 daiTokenMask = creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.DAI));

        creditManager.transferAccountOwnership(creditAccount, USER);
        creditManager.closeCreditAccount(
            creditAccount,
            ClosureAction.CLOSE_ACCOUNT,
            0,
            USER,
            USER,
            wethTokenMask | daiTokenMask,
            0,
            borrowedAmount,
            true
        );

        expectBalance(Tokens.WETH, creditAccount, 1);

        assertEq(wethGateway.balanceOf(USER), WETH_EXCHANGE_AMOUNT - 1, "Incorrect amount deposited on wethGateway");
    }

    /// @dev [CM-18]: closeCreditAccount sends ETH for WETH creditManger to borrower
    /// CASE: LIQUIDATION
    function test_CM_18_close_credit_account_sends_eth_to_liquidator_and_weth_to_borrower() public {
        /// Store USER ETH balance

        uint256 userBalanceBefore = tokenTestSuite.balanceOf(Tokens.WETH, USER);

        (,, uint16 liquidationDiscount,,) = creditManager.fees();

        // It takes "clean" address which doesn't holds any assets

        _connectCreditManagerSuite(Tokens.WETH, false);

        /// CLOSURE CASE
        (uint256 borrowedAmount,,, address creditAccount) = _openCreditAccount();

        // Transfer additional borrowedAmount. After that underluying token balance = 2 * borrowedAmount
        tokenTestSuite.mint(Tokens.WETH, creditAccount, borrowedAmount);

        uint256 totalValue = borrowedAmount * 2;

        uint256 wethTokenMask = creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.WETH));
        uint256 daiTokenMask = creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.DAI));

        (uint256 remainingFunds,) = creditManager.closeCreditAccount(
            creditAccount,
            ClosureAction.LIQUIDATE_ACCOUNT,
            totalValue,
            LIQUIDATOR,
            FRIEND,
            wethTokenMask | daiTokenMask,
            0,
            borrowedAmount,
            true
        );

        // checks that no eth were sent to USER account
        expectEthBalance(USER, 0);

        expectBalance(Tokens.WETH, creditAccount, 1, "Credit account balance != 1");

        // expectBalance(Tokens.WETH, USER, userBalanceBefore + remainingFunds, "Incorrect amount were paid back");

        assertEq(
            wethGateway.balanceOf(FRIEND),
            (totalValue * (PERCENTAGE_FACTOR - liquidationDiscount)) / PERCENTAGE_FACTOR,
            "Incorrect amount were paid to liqiudator friend address"
        );
    }

    /// @dev [CM-19]: closeCreditAccount sends ETH for WETH creditManger to borrower
    /// CASE: LIQUIDATION
    /// Underlying token: DAI
    function test_CM_19_close_dai_credit_account_sends_eth_to_liquidator() public {
        /// CLOSURE CASE
        (uint256 borrowedAmount,,, address creditAccount) = _openCreditAccount();
        creditManager.transferAccountOwnership(creditAccount, address(this));

        // Transfer additional borrowedAmount. After that underluying token balance = 2 * borrowedAmount
        tokenTestSuite.mint(Tokens.DAI, creditAccount, borrowedAmount);

        // Adds WETH to test how it would be converted
        tokenTestSuite.mint(Tokens.WETH, creditAccount, WETH_EXCHANGE_AMOUNT);

        creditManager.transferAccountOwnership(creditAccount, USER);
        uint256 wethTokenMask = creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.WETH));
        uint256 daiTokenMask = creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.DAI));

        (uint256 remainingFunds,) = creditManager.closeCreditAccount(
            creditAccount,
            ClosureAction.LIQUIDATE_ACCOUNT,
            borrowedAmount,
            LIQUIDATOR,
            FRIEND,
            wethTokenMask | daiTokenMask,
            0,
            borrowedAmount,
            true
        );

        expectBalance(Tokens.WETH, creditAccount, 1);

        assertEq(
            wethGateway.balanceOf(FRIEND),
            WETH_EXCHANGE_AMOUNT - 1,
            "Incorrect amount were paid to liqiudator friend address"
        );
    }

    //
    // MANAGE DEBT
    //

    /// @dev [CM-20]: manageDebt correctly increases debt
    function test_CM_20_manageDebt_correctly_increases_debt(uint128 amount) public {
        (uint256 borrowedAmount, uint256 cumulativeIndexAtOpen,, address creditAccount) = cms.openCreditAccount(1);

        tokenTestSuite.mint(Tokens.DAI, address(poolMock), amount);

        poolMock.setCumulative_RAY(cumulativeIndexAtOpen * 2);

        uint256 expectedNewCulumativeIndex =
            (2 * cumulativeIndexAtOpen * (borrowedAmount + amount)) / (2 * borrowedAmount + amount);

        (uint256 newBorrowedAmount,) =
            creditManager.manageDebt(creditAccount, amount, 1, ManageDebtAction.INCREASE_DEBT);

        assertEq(newBorrowedAmount, borrowedAmount + amount, "Incorrect returned newBorrowedAmount");

        assertLe(
            (ICreditAccount(creditAccount).cumulativeIndexAtOpen() * (10 ** 6)) / expectedNewCulumativeIndex,
            10 ** 6,
            "Incorrect cumulative index"
        );

        (uint256 debt,,,,,) = creditManager.creditAccountInfo(creditAccount);
        assertEq(debt, newBorrowedAmount, "Incorrect borrowedAmount");

        expectBalance(Tokens.DAI, creditAccount, newBorrowedAmount, "Incorrect balance on credit account");

        assertEq(poolMock.lendAmount(), amount, "Incorrect lend amount");

        assertEq(poolMock.lendAccount(), creditAccount, "Incorrect lend account");
    }

    /// @dev [CM-21]: manageDebt correctly decreases debt
    function test_CM_21_manageDebt_correctly_decreases_debt(uint128 amount) public {
        tokenTestSuite.mint(Tokens.DAI, address(poolMock), (uint256(type(uint128).max) * 14) / 10);

        (uint256 borrowedAmount, uint256 cumulativeIndexAtOpen, uint256 cumulativeIndexNow, address creditAccount) =
            cms.openCreditAccount((uint256(type(uint128).max) * 14) / 10);

        (,, uint256 totalDebt) = creditManager.calcCreditAccountAccruedInterest(creditAccount);

        uint256 expectedInterestAndFees;
        uint256 expectedBorrowAmount;
        if (amount >= totalDebt - borrowedAmount) {
            expectedInterestAndFees = 0;
            expectedBorrowAmount = totalDebt - amount;
        } else {
            expectedInterestAndFees = totalDebt - borrowedAmount - amount;
            expectedBorrowAmount = borrowedAmount;
        }

        (uint256 newBorrowedAmount,) =
            creditManager.manageDebt(creditAccount, amount, 1, ManageDebtAction.DECREASE_DEBT);

        assertEq(newBorrowedAmount, expectedBorrowAmount, "Incorrect returned newBorrowedAmount");

        if (amount >= totalDebt - borrowedAmount) {
            (,, uint256 newTotalDebt) = creditManager.calcCreditAccountAccruedInterest(creditAccount);

            assertEq(newTotalDebt, newBorrowedAmount, "Incorrect new interest");
        } else {
            (,, uint256 newTotalDebt) = creditManager.calcCreditAccountAccruedInterest(creditAccount);

            assertLt(
                (RAY * (newTotalDebt - newBorrowedAmount)) / expectedInterestAndFees - RAY,
                10000,
                "Incorrect new interest"
            );
        }
        uint256 cumulativeIndexAtOpenAfter;
        {
            uint256 debt;
            (debt, cumulativeIndexAtOpenAfter,,,,) = creditManager.creditAccountInfo(creditAccount);

            assertEq(debt, newBorrowedAmount, "Incorrect borrowedAmount");
        }

        expectBalance(Tokens.DAI, creditAccount, borrowedAmount - amount, "Incorrect balance on credit account");

        if (amount >= totalDebt - borrowedAmount) {
            assertEq(cumulativeIndexAtOpenAfter, cumulativeIndexNow, "Incorrect cumulativeIndexAtOpen");
        } else {
            CreditManagerTestInternal cmi = new CreditManagerTestInternal(
                creditManager.poolService(), address(withdrawalManager)
            );

            {
                (uint256 feeInterest,,,,) = creditManager.fees();
                amount = uint128((uint256(amount) * PERCENTAGE_FACTOR) / (PERCENTAGE_FACTOR + feeInterest));
            }

            assertEq(
                cumulativeIndexAtOpenAfter,
                cmi.calcNewCumulativeIndex(borrowedAmount, amount, cumulativeIndexNow, cumulativeIndexAtOpen, false),
                "Incorrect cumulativeIndexAtOpen"
            );
        }
    }

    //
    // ADD COLLATERAL
    //

    /// @dev [CM-22]: add collateral transfers money and returns token mask

    function test_CM_22_add_collateral_transfers_money_and_returns_token_mask() public {
        (,,, address creditAccount) = _openCreditAccount();

        tokenTestSuite.mint(Tokens.WETH, FRIEND, WETH_EXCHANGE_AMOUNT);
        tokenTestSuite.approve(Tokens.WETH, FRIEND, address(creditManager));

        expectBalance(Tokens.WETH, creditAccount, 0, "Non-zero WETH balance");

        expectTokenIsEnabled(creditAccount, Tokens.WETH, false);

        uint256 tokenMask = creditManager.addCollateral(
            FRIEND, creditAccount, tokenTestSuite.addressOf(Tokens.WETH), WETH_EXCHANGE_AMOUNT
        );

        expectBalance(Tokens.WETH, creditAccount, WETH_EXCHANGE_AMOUNT, "Non-zero WETH balance");

        expectBalance(Tokens.WETH, FRIEND, 0, "Incorrect FRIEND balance");

        assertEq(
            tokenMask,
            creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.WETH)),
            "Incorrect return result"
        );

        // expectTokenIsEnabled(creditAccount, Tokens.WETH, true);
    }

    //
    // TRANSFER ACCOUNT OWNERSHIP
    //

    /// @dev [CM-23]: transferAccountOwnership reverts if to equals 0 or creditAccount is linked with "to" address

    function test_CM_23_transferAccountOwnership_reverts_if_account_exists() public {
        // _openCreditAccount();

        // creditManager.openCreditAccount(1, FRIEND);

        // // Existing account case
        // evm.expectRevert(UserAlreadyHasAccountException.selector);
        // creditManager.transferAccountOwnership(FRIEND, USER);
    }

    /// @dev [CM-24]: transferAccountOwnership changes creditAccounts map properly

    function test_CM_24_transferAccountOwnership_changes_creditAccounts_map_properly() public {
        (,,, address creditAccount) = _openCreditAccount();

        creditManager.transferAccountOwnership(creditAccount, FRIEND);

        // assertEq(creditManager.creditAccounts(USER), address(0), "From account wasn't deleted");

        // assertEq(creditManager.creditAccounts(FRIEND), creditAccount, "To account isn't correct");

        // evm.expectRevert(CreditAccountNotExistsException.selector);
        // creditManager.getCreditAccountOrRevert(USER);
    }

    //
    // APPROVE CREDIT ACCOUNT
    //

    /// @dev [CM-25A]: approveCreditAccount reverts if the token is not added
    function test_CM_25A_approveCreditAccount_reverts_if_the_token_is_not_added() public {
        (,,, address creditAccount) = _openCreditAccount();
        creditManager.setCaForExternalCall(creditAccount);

        evm.prank(CONFIGURATOR);
        creditManager.setContractAllowance(ADAPTER, DUMB_ADDRESS);

        evm.expectRevert(TokenNotAllowedException.selector);

        evm.prank(ADAPTER);
        creditManager.approveCreditAccount(DUMB_ADDRESS, 100);
    }

    /// @dev [CM-26]: approveCreditAccount approves with desired allowance
    function test_CM_26_approveCreditAccount_approves_with_desired_allowance() public {
        (,,, address creditAccount) = _openCreditAccount();
        creditManager.setCaForExternalCall(creditAccount);

        evm.prank(CONFIGURATOR);
        creditManager.setContractAllowance(ADAPTER, DUMB_ADDRESS);

        // Case, when current allowance > Allowance_THRESHOLD
        tokenTestSuite.approve(Tokens.DAI, creditAccount, DUMB_ADDRESS, 200);

        address dai = tokenTestSuite.addressOf(Tokens.DAI);

        evm.prank(ADAPTER);
        creditManager.approveCreditAccount(dai, DAI_EXCHANGE_AMOUNT);

        expectAllowance(Tokens.DAI, creditAccount, DUMB_ADDRESS, DAI_EXCHANGE_AMOUNT);
    }

    /// @dev [CM-27A]: approveCreditAccount works for ERC20 that revert if allowance > 0 before approve
    function test_CM_27A_approveCreditAccount_works_for_ERC20_with_approve_restrictions() public {
        (,,, address creditAccount) = _openCreditAccount();
        creditManager.setCaForExternalCall(creditAccount);

        evm.prank(CONFIGURATOR);
        creditManager.setContractAllowance(ADAPTER, DUMB_ADDRESS);

        address approveRevertToken = address(new ERC20ApproveRestrictedRevert());

        evm.prank(CONFIGURATOR);
        creditManager.addToken(approveRevertToken);

        evm.prank(ADAPTER);
        creditManager.approveCreditAccount(approveRevertToken, DAI_EXCHANGE_AMOUNT);

        evm.prank(ADAPTER);
        creditManager.approveCreditAccount(approveRevertToken, 2 * DAI_EXCHANGE_AMOUNT);

        expectAllowance(approveRevertToken, creditAccount, DUMB_ADDRESS, 2 * DAI_EXCHANGE_AMOUNT);
    }

    // /// @dev [CM-27B]: approveCreditAccount works for ERC20 that returns false if allowance > 0 before approve
    function test_CM_27B_approveCreditAccount_works_for_ERC20_with_approve_restrictions() public {
        (,,, address creditAccount) = _openCreditAccount();
        creditManager.setCaForExternalCall(creditAccount);

        address approveFalseToken = address(new ERC20ApproveRestrictedFalse());

        evm.prank(CONFIGURATOR);
        creditManager.addToken(approveFalseToken);

        evm.prank(CONFIGURATOR);
        creditManager.setContractAllowance(ADAPTER, DUMB_ADDRESS);

        evm.prank(ADAPTER);
        creditManager.approveCreditAccount(approveFalseToken, DAI_EXCHANGE_AMOUNT);

        evm.prank(ADAPTER);
        creditManager.approveCreditAccount(approveFalseToken, 2 * DAI_EXCHANGE_AMOUNT);

        expectAllowance(approveFalseToken, creditAccount, DUMB_ADDRESS, 2 * DAI_EXCHANGE_AMOUNT);
    }

    //
    // EXECUTE ORDER
    //

    /// @dev [CM-29]: executeOrder calls credit account method and emit event
    function test_CM_29_executeOrder_calls_credit_account_method_and_emit_event() public {
        (,,, address creditAccount) = _openCreditAccount();
        creditManager.setCaForExternalCall(creditAccount);

        TargetContractMock targetMock = new TargetContractMock();

        evm.prank(CONFIGURATOR);
        creditManager.setContractAllowance(ADAPTER, address(targetMock));

        bytes memory callData = bytes("Hello, world!");

        // we emit the event we expect to see.
        evm.expectEmit(true, false, false, false);
        emit ExecuteOrder(address(targetMock));

        // stack trace check
        evm.expectCall(creditAccount, abi.encodeWithSignature("execute(address,bytes)", address(targetMock), callData));
        evm.expectCall(address(targetMock), callData);

        evm.prank(ADAPTER);
        creditManager.executeOrder(callData);

        assertEq0(targetMock.callData(), callData, "Incorrect calldata");
    }

    //
    // FULL COLLATERAL CHECK
    //

    /// @dev [CM-38]: fullCollateralCheck skips tokens is they are not enabled
    function test_CM_38_fullCollateralCheck_skips_tokens_is_they_are_not_enabled() public {
        address creditAccount = _openAccountAndTransferToCF();

        tokenTestSuite.mint(Tokens.USDC, creditAccount, USDC_ACCOUNT_AMOUNT);

        evm.expectRevert(NotEnoughCollateralException.selector);
        _baseFullCollateralCheck(creditAccount);

        // fullCollateralCheck doesn't revert when token is enabled
        uint256 usdcTokenMask = creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.USDC));
        uint256 daiTokenMask = creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.DAI));

        creditManager.fullCollateralCheck(creditAccount, usdcTokenMask | daiTokenMask, new uint256[](0), 10000);
    }

    /// @dev [CM-39]: fullCollateralCheck diables tokens if they have zero balance
    function test_CM_39_fullCollateralCheck_diables_tokens_if_they_have_zero_balance() public {
        (uint256 borrowedAmount, uint256 cumulativeIndexAtOpen, uint256 cumulativeIndexNow, address creditAccount) =
            _openCreditAccount();
        creditManager.transferAccountOwnership(creditAccount, address(this));

        (uint256 feeInterest,,,,) = creditManager.fees();

        /// TODO: CHANGE COMPUTATION

        uint256 borrowAmountWithInterest = borrowedAmount * cumulativeIndexNow / cumulativeIndexAtOpen;
        uint256 interestAccured = borrowAmountWithInterest - borrowedAmount;

        uint256 amountToRepayInLINK = (
            ((borrowAmountWithInterest + interestAccured * feeInterest / PERCENTAGE_FACTOR) * (10 ** 8))
                * PERCENTAGE_FACTOR / tokenTestSuite.prices(Tokens.LINK)
                / creditManager.liquidationThresholds(tokenTestSuite.addressOf(Tokens.LINK))
        ) + 1000000000;

        tokenTestSuite.mint(Tokens.LINK, creditAccount, amountToRepayInLINK);

        uint256 wethTokenMask = creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.WETH));
        uint256 daiTokenMask = creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.DAI));
        uint256 linkTokenMask = creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.LINK));
        // Enable WETH and LINK token. WETH should be disabled adter fullCollateralCheck
        // creditManager.checkAndEnableToken(tokenTestSuite.addressOf(Tokens.LINK));
        // creditManager.checkAndEnableToken(tokenTestSuite.addressOf(Tokens.WETH));

        creditManager.fullCollateralCheck(
            creditAccount, wethTokenMask | linkTokenMask | daiTokenMask, new uint256[](0), 10000
        );

        expectTokenIsEnabled(creditAccount, Tokens.LINK, true);
        expectTokenIsEnabled(creditAccount, Tokens.WETH, false);
    }

    /// @dev [CM-40]: fullCollateralCheck breaks loop if total >= borrowAmountPlusInterestRateUSD and pass the check
    function test_CM_40_fullCollateralCheck_breaks_loop_if_total_gte_borrowAmountPlusInterestRateUSD_and_pass_the_check(
    ) public {
        evm.startPrank(CONFIGURATOR);

        CreditManagerV3 cm = new CreditManagerV3(address(poolMock), address(withdrawalManager));
        cms.cr().addCreditManager(address(cm));

        cm.setCreditFacade(address(this));
        cm.setPriceOracle(address(priceOracle));

        evm.stopPrank();

        address creditAccount = cm.openCreditAccount(DAI_ACCOUNT_AMOUNT, USER);
        cm.transferAccountOwnership(creditAccount, address(this));

        address revertToken = DUMB_ADDRESS;
        address linkToken = tokenTestSuite.addressOf(Tokens.LINK);

        // We add "revert" token - DUMB address which would revert if balanceOf method would be called
        // If (total >= borrowAmountPlusInterestRateUSD) doesn't break the loop, it would be called
        // cause we enable this token using checkAndEnableToken.
        // If fullCollateralCheck doesn't revert, it means that the break works
        evm.startPrank(CONFIGURATOR);

        cm.addToken(linkToken);
        cm.addToken(revertToken);
        cm.setLiquidationThreshold(linkToken, creditConfig.lt(Tokens.LINK));

        evm.stopPrank();

        // cm.checkAndEnableToken(revertToken);
        // cm.checkAndEnableToken(linkToken);

        // We add WAD for rounding compensation
        uint256 amountToRepayInLINK = ((DAI_ACCOUNT_AMOUNT + WAD) * PERCENTAGE_FACTOR * (10 ** 8))
            / creditConfig.lt(Tokens.LINK) / tokenTestSuite.prices(Tokens.LINK);

        tokenTestSuite.mint(Tokens.LINK, creditAccount, amountToRepayInLINK);

        uint256 revertTokenMask = cm.getTokenMaskOrRevert(revertToken);
        uint256 linkTokenMask = cm.getTokenMaskOrRevert(linkToken);

        uint256 enabledTokensMap = revertTokenMask | linkTokenMask;

        cm.fullCollateralCheck(creditAccount, enabledTokensMap, new uint256[](0), 10000);
    }

    /// @dev [CM-41]: fullCollateralCheck reverts if CA has more than allowed enabled tokens
    function test_CM_41_fullCollateralCheck_reverts_if_CA_has_more_than_allowed_enabled_tokens() public {
        evm.startPrank(CONFIGURATOR);

        // We use clean CreditManagerV3 to have only one underlying token for testing
        creditManager = new CreditManagerV3(address(poolMock), address(withdrawalManager));
        cms.cr().addCreditManager(address(creditManager));

        creditManager.setCreditFacade(address(this));
        creditManager.setPriceOracle(address(priceOracle));

        creditManager.setLiquidationThreshold(poolMock.underlyingToken(), 9300);
        evm.stopPrank();

        address creditAccount = creditManager.openCreditAccount(DAI_ACCOUNT_AMOUNT, address(this));
        tokenTestSuite.mint(Tokens.DAI, creditAccount, 2 * DAI_ACCOUNT_AMOUNT);

        enableTokensMoreThanLimit(creditAccount);
        evm.expectRevert(TooManyEnabledTokensException.selector);

        creditManager.fullCollateralCheck(creditAccount, 2 ** 13 - 1, new uint256[](0), 10000);
    }

    /// @dev [CM-41A]: fullCollateralCheck correctly disables the underlying when needed
    function test_CM_41A_fullCollateralCheck_correctly_dfisables_the_underlying_when_needed() public {
        (uint256 borrowedAmount, uint256 cumulativeIndexAtOpen, uint256 cumulativeIndexNow, address creditAccount) =
            _openCreditAccount();

        uint256 daiBalance = tokenTestSuite.balanceOf(Tokens.DAI, creditAccount);

        tokenTestSuite.burn(Tokens.DAI, creditAccount, daiBalance);

        _addAndEnableTokens(creditAccount, 200, 0);

        uint256 totalTokens = creditManager.collateralTokensCount();

        uint256 borrowAmountWithInterest = borrowedAmount * cumulativeIndexNow / cumulativeIndexAtOpen;
        uint256 interestAccured = borrowAmountWithInterest - borrowedAmount;

        (uint256 feeInterest,,,,) = creditManager.fees();

        uint256 amountToRepayInLINK = (
            ((borrowAmountWithInterest + interestAccured * feeInterest / PERCENTAGE_FACTOR) * (10 ** 8))
                * PERCENTAGE_FACTOR / tokenTestSuite.prices(Tokens.DAI)
                / creditManager.liquidationThresholds(tokenTestSuite.addressOf(Tokens.DAI))
        ) + WAD;

        tokenTestSuite.mint(Tokens.DAI, creditAccount, amountToRepayInLINK);

        uint256[] memory hints = new uint256[](totalTokens);
        unchecked {
            for (uint256 i; i < totalTokens; ++i) {
                hints[i] = 2 ** (totalTokens - i - 1);
            }
        }

        creditManager.fullCollateralCheck(creditAccount, 2 ** (totalTokens) - 1, hints, 10000);

        assertEq(
            creditManager.enabledTokensMap(creditAccount).calcEnabledTokens(), 1, "Incorrect number of tokens enabled"
        );
    }

    /// @dev [CM-42]: fullCollateralCheck fuzzing test
    function test_CM_42_fullCollateralCheck_fuzzing_test(
        uint128 borrowedAmount,
        uint128 daiBalance,
        uint128 usdcBalance,
        uint128 linkBalance,
        uint128 wethBalance,
        bool enableUSDC,
        bool enableLINK,
        bool enableWETH,
        uint16 minHealthFactor
    ) public {
        evm.assume(borrowedAmount > WAD);

        evm.assume(minHealthFactor > 10_000 && minHealthFactor < 50_000);

        tokenTestSuite.mint(Tokens.DAI, address(poolMock), borrowedAmount);

        (,,, address creditAccount) = cms.openCreditAccount(borrowedAmount);
        creditManager.transferAccountOwnership(creditAccount, address(this));

        if (daiBalance > borrowedAmount) {
            tokenTestSuite.mint(Tokens.DAI, creditAccount, daiBalance - borrowedAmount);
        } else {
            tokenTestSuite.burn(Tokens.DAI, creditAccount, borrowedAmount - daiBalance);
        }

        expectBalance(Tokens.DAI, creditAccount, daiBalance);

        mintBalance(creditAccount, Tokens.USDC, usdcBalance, enableUSDC);
        mintBalance(creditAccount, Tokens.LINK, linkBalance, enableLINK);
        mintBalance(creditAccount, Tokens.WETH, wethBalance, enableWETH);

        uint256 twvUSD = (
            tokenTestSuite.balanceOf(Tokens.DAI, creditAccount) * tokenTestSuite.prices(Tokens.DAI)
                * creditConfig.lt(Tokens.DAI)
        ) / WAD;

        twvUSD += !enableUSDC
            ? 0
            : (
                tokenTestSuite.balanceOf(Tokens.USDC, creditAccount) * tokenTestSuite.prices(Tokens.USDC)
                    * creditConfig.lt(Tokens.USDC)
            ) / (10 ** 6);

        twvUSD += !enableLINK
            ? 0
            : (
                tokenTestSuite.balanceOf(Tokens.LINK, creditAccount) * tokenTestSuite.prices(Tokens.LINK)
                    * creditConfig.lt(Tokens.LINK)
            ) / WAD;

        twvUSD += !enableWETH
            ? 0
            : (
                tokenTestSuite.balanceOf(Tokens.WETH, creditAccount) * tokenTestSuite.prices(Tokens.WETH)
                    * creditConfig.lt(Tokens.WETH)
            ) / WAD;

        (,, uint256 borrowedAmountWithInterestAndFees) = creditManager.calcCreditAccountAccruedInterest(creditAccount);

        uint256 debtUSD = borrowedAmountWithInterestAndFees * tokenTestSuite.prices(Tokens.DAI) * minHealthFactor / WAD;

        bool shouldRevert = twvUSD < debtUSD;

        uint256 enabledTokensMap = 1;

        if (enableUSDC) {
            enabledTokensMap |= creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.USDC));
        }

        if (enableLINK) {
            enabledTokensMap |= creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.LINK));
        }

        if (enableWETH) {
            enabledTokensMap |= creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.WETH));
        }

        if (shouldRevert) {
            evm.expectRevert(NotEnoughCollateralException.selector);
        }

        creditManager.fullCollateralCheck(creditAccount, enabledTokensMap, new uint256[](0), minHealthFactor);
    }

    //
    // CALC CLOSE PAYMENT PURE
    //
    struct CalcClosePaymentsPureTestCase {
        string name;
        uint256 totalValue;
        ClosureAction closureActionType;
        uint256 borrowedAmount;
        uint256 borrowedAmountWithInterest;
        uint256 amountToPool;
        uint256 remainingFunds;
        uint256 profit;
        uint256 loss;
    }

    /// @dev [CM-43]: calcClosePayments computes
    function test_CM_43_calcClosePayments_test() public {
        evm.prank(CONFIGURATOR);

        creditManager.setParams(
            1000, // feeInterest: 10% , it doesn't matter this test
            200, // feeLiquidation: 2%, it doesn't matter this test
            9500, // liquidationPremium: 5%, it doesn't matter this test
            100, // feeLiquidationExpired: 1%
            9800 // liquidationPremiumExpired: 2%
        );

        CalcClosePaymentsPureTestCase[7] memory cases = [
            CalcClosePaymentsPureTestCase({
                name: "CLOSURE",
                totalValue: 0,
                closureActionType: ClosureAction.CLOSE_ACCOUNT,
                borrowedAmount: 1000,
                borrowedAmountWithInterest: 1100,
                amountToPool: 1110, // amountToPool = 1100 + 100 * 10% = 1110
                remainingFunds: 0,
                profit: 10, // profit: 100 (interest) * 10% = 10
                loss: 0
            }),
            CalcClosePaymentsPureTestCase({
                name: "LIQUIDATION WITH PROFIT & REMAINING FUNDS",
                totalValue: 2000,
                closureActionType: ClosureAction.LIQUIDATE_ACCOUNT,
                borrowedAmount: 1000,
                borrowedAmountWithInterest: 1100,
                amountToPool: 1150, // amountToPool = 1100 + 100 * 10% + 2000 * 2% = 1150
                remainingFunds: 749, //remainingFunds: 2000 * (100% - 5%) - 1150 - 1 = 749
                profit: 50,
                loss: 0
            }),
            CalcClosePaymentsPureTestCase({
                name: "LIQUIDATION WITH PROFIT & ZERO REMAINING FUNDS",
                totalValue: 2100,
                closureActionType: ClosureAction.LIQUIDATE_ACCOUNT,
                borrowedAmount: 900,
                borrowedAmountWithInterest: 1900,
                amountToPool: 1995, // amountToPool =  1900 + 1000 * 10% + 2100 * 2% = 2042,  totalFunds = 2100 * 95% = 1995, so, amount to pool would be 1995
                remainingFunds: 0, // remainingFunds: 2000 * (100% - 5%) - 1150 - 1 = 749
                profit: 95,
                loss: 0
            }),
            CalcClosePaymentsPureTestCase({
                name: "LIQUIDATION WITH LOSS",
                totalValue: 1000,
                closureActionType: ClosureAction.LIQUIDATE_ACCOUNT,
                borrowedAmount: 900,
                borrowedAmountWithInterest: 1900,
                amountToPool: 950, // amountToPool =  1900 + 1000 * 10% + 1000 * 2% = 2020, totalFunds = 1000 * 95% = 950, So, amount to pool would be 950
                remainingFunds: 0, // 0, cause it's loss
                profit: 0,
                loss: 950
            }),
            CalcClosePaymentsPureTestCase({
                name: "LIQUIDATION OF EXPIRED WITH PROFIT & REMAINING FUNDS",
                totalValue: 2000,
                closureActionType: ClosureAction.LIQUIDATE_EXPIRED_ACCOUNT,
                borrowedAmount: 1000,
                borrowedAmountWithInterest: 1100,
                amountToPool: 1130, // amountToPool = 1100 + 100 * 10% + 2000 * 1% = 1130
                remainingFunds: 829, //remainingFunds: 2000 * (100% - 2%) - 1130 - 1 = 829
                profit: 30,
                loss: 0
            }),
            CalcClosePaymentsPureTestCase({
                name: "LIQUIDATION OF EXPIRED WITH PROFIT & ZERO REMAINING FUNDS",
                totalValue: 2100,
                closureActionType: ClosureAction.LIQUIDATE_EXPIRED_ACCOUNT,
                borrowedAmount: 900,
                borrowedAmountWithInterest: 2000,
                amountToPool: 2058, // amountToPool =  2000 + 1100 * 10% + 2100 * 1% = 2131,  totalFunds = 2100 * 98% = 2058, so, amount to pool would be 2058
                remainingFunds: 0,
                profit: 58,
                loss: 0
            }),
            CalcClosePaymentsPureTestCase({
                name: "LIQUIDATION OF EXPIRED WITH LOSS",
                totalValue: 1000,
                closureActionType: ClosureAction.LIQUIDATE_EXPIRED_ACCOUNT,
                borrowedAmount: 900,
                borrowedAmountWithInterest: 1900,
                amountToPool: 980, // amountToPool =  1900 + 1000 * 10% + 1000 * 2% = 2020, totalFunds = 1000 * 98% = 980, So, amount to pool would be 980
                remainingFunds: 0, // 0, cause it's loss
                profit: 0,
                loss: 920
            })
            // CalcClosePaymentsPureTestCase({
            //     name: "LIQUIDATION WHILE PAUSED WITH REMAINING FUNDS",
            //     totalValue: 2000,
            //     closureActionType: ClosureAction.LIQUIDATE_PAUSED,
            //     borrowedAmount: 1000,
            //     borrowedAmountWithInterest: 1100,
            //     amountToPool: 1150, // amountToPool = 1100 + 100 * 10%  + 2000 * 2% = 1150
            //     remainingFunds: 849, //remainingFunds: 2000 - 1150 - 1 = 869
            //     profit: 50,
            //     loss: 0
            // }),
            // CalcClosePaymentsPureTestCase({
            //     name: "LIQUIDATION OF EXPIRED WITH LOSS",
            //     totalValue: 1000,
            //     closureActionType: ClosureAction.LIQUIDATE_PAUSED,
            //     borrowedAmount: 900,
            //     borrowedAmountWithInterest: 1900,
            //     amountToPool: 1000, // amountToPool =  1900 + 1000 * 10% + 1000 * 2% = 2020, totalFunds = 1000 * 98% = 980, So, amount to pool would be 980
            //     remainingFunds: 0, // 0, cause it's loss
            //     profit: 0,
            //     loss: 900
            // })
        ];

        for (uint256 i = 0; i < cases.length; i++) {
            (uint256 amountToPool, uint256 remainingFunds, uint256 profit, uint256 loss) = creditManager
                .calcClosePayments(
                cases[i].totalValue,
                cases[i].closureActionType,
                cases[i].borrowedAmount,
                cases[i].borrowedAmountWithInterest
            );

            assertEq(amountToPool, cases[i].amountToPool, string(abi.encodePacked(cases[i].name, ": amountToPool")));
            assertEq(
                remainingFunds, cases[i].remainingFunds, string(abi.encodePacked(cases[i].name, ": remainingFunds"))
            );
            assertEq(profit, cases[i].profit, string(abi.encodePacked(cases[i].name, ": profit")));
            assertEq(loss, cases[i].loss, string(abi.encodePacked(cases[i].name, ": loss")));
        }
    }

    //
    // TRASNFER ASSETS TO
    //

    /// @dev [CM-44]: _transferAssetsTo sends all tokens except underlying one and not-enabled to provided address
    function test_CM_44_transferAssetsTo_sends_all_tokens_except_underlying_one_to_provided_address() public {
        // It enables  CreditManagerTestInternal for some test cases
        _connectCreditManagerSuite(Tokens.DAI, true);

        address[2] memory friends = [FRIEND, FRIEND2];

        // CASE 0: convertToETH = false
        // CASE 1: convertToETH = true
        for (uint256 i = 0; i < 2; i++) {
            bool convertToETH = i > 0;

            address friend = friends[i];
            (uint256 borrowedAmount,,, address creditAccount) = _openCreditAccount();
            creditManager.transferAccountOwnership(creditAccount, address(this));

            CreditManagerTestInternal cmi = CreditManagerTestInternal(address(creditManager));

            tokenTestSuite.mint(Tokens.USDC, creditAccount, USDC_EXCHANGE_AMOUNT);
            tokenTestSuite.mint(Tokens.WETH, creditAccount, WETH_EXCHANGE_AMOUNT);
            tokenTestSuite.mint(Tokens.LINK, creditAccount, LINK_EXCHANGE_AMOUNT);

            address wethTokenAddr = tokenTestSuite.addressOf(Tokens.WETH);
            // creditManager.checkAndEnableToken(wethTokenAddr);

            uint256 enabledTokenMask = creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.DAI))
                | creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.WETH));

            cmi.transferAssetsTo(creditAccount, friend, convertToETH, enabledTokenMask);

            expectBalance(Tokens.DAI, creditAccount, borrowedAmount, "Underlying assets were transffered!");

            expectBalance(Tokens.DAI, friend, 0);

            expectBalance(Tokens.USDC, creditAccount, USDC_EXCHANGE_AMOUNT);

            expectBalance(Tokens.USDC, friend, 0);

            expectBalance(Tokens.WETH, creditAccount, 1);

            if (convertToETH) {
                assertEq(
                    wethGateway.balanceOf(friend),
                    WETH_EXCHANGE_AMOUNT - 1,
                    "Incorrect amount were sent to friend address"
                );
            } else {
                expectBalance(Tokens.WETH, friend, WETH_EXCHANGE_AMOUNT - 1);
            }

            expectBalance(Tokens.LINK, creditAccount, LINK_EXCHANGE_AMOUNT);

            expectBalance(Tokens.LINK, friend, 0);

            creditManager.transferAccountOwnership(creditAccount, USER);
            creditManager.closeCreditAccount(
                creditAccount,
                ClosureAction.LIQUIDATE_ACCOUNT,
                0,
                LIQUIDATOR,
                friend,
                enabledTokenMask,
                0,
                DAI_ACCOUNT_AMOUNT,
                false
            );
        }
    }

    //
    // SAFE TOKEN TRANSFER
    //

    /// @dev [CM-45]: _safeTokenTransfer transfers tokens
    function test_CM_45_safeTokenTransfer_transfers_tokens() public {
        // It enables  CreditManagerTestInternal for some test cases
        _connectCreditManagerSuite(Tokens.DAI, true);

        uint256 WETH_TRANSFER = WETH_EXCHANGE_AMOUNT / 4;

        address[2] memory friends = [FRIEND, FRIEND2];

        // CASE 0: convertToETH = false
        // CASE 1: convertToETH = true
        for (uint256 i = 0; i < 2; i++) {
            bool convertToETH = i > 0;

            address friend = friends[i];
            (,,, address creditAccount) = _openCreditAccount();

            CreditManagerTestInternal cmi = CreditManagerTestInternal(address(creditManager));

            tokenTestSuite.mint(Tokens.WETH, creditAccount, WETH_EXCHANGE_AMOUNT);

            cmi.safeTokenTransfer(
                creditAccount, tokenTestSuite.addressOf(Tokens.WETH), friend, WETH_TRANSFER, convertToETH
            );

            expectBalance(Tokens.WETH, creditAccount, WETH_EXCHANGE_AMOUNT - WETH_TRANSFER);

            if (convertToETH) {
                assertEq(wethGateway.balanceOf(friend), WETH_TRANSFER, "Incorrect amount were sent to friend address");
            } else {
                expectBalance(Tokens.WETH, friend, WETH_TRANSFER);
            }

            creditManager.closeCreditAccount(
                creditAccount, ClosureAction.LIQUIDATE_ACCOUNT, 0, LIQUIDATOR, friend, 1, 0, DAI_ACCOUNT_AMOUNT, false
            );
        }
    }

    //
    // DISABLE TOKEN
    //

    // /// @dev [CM-46]: _disableToken disabale tokens and do not enable it if called twice
    // function test_CM_46__disableToken_disabale_tokens_and_do_not_enable_it_if_called_twice() public {
    //     // It enables  CreditManagerTestInternal for some test cases
    //     _connectCreditManagerSuite(Tokens.DAI, true);

    //     address creditAccount = _openAccountAndTransferToCF();

    //     address usdcToken = tokenTestSuite.addressOf(Tokens.USDC);
    //     // creditManager.checkAndEnableToken(usdcToken);

    //     expectTokenIsEnabled(creditAccount, Tokens.USDC, true);

    //     CreditManagerTestInternal cmi = CreditManagerTestInternal(address(creditManager));

    //     cmi.disableToken(usdcToken);
    //     expectTokenIsEnabled(creditAccount, Tokens.USDC, false);

    //     cmi.disableToken(usdcToken);
    //     expectTokenIsEnabled(creditAccount, Tokens.USDC, false);
    // }

    /// @dev [CM-47]: collateralTokens works as expected
    function test_CM_47_collateralTokens_works_as_expected(address newToken, uint16 newLT) public {
        evm.assume(newToken != underlying && newToken != address(0));

        evm.startPrank(CONFIGURATOR);

        // reset connected tokens
        CreditManagerV3 cm = new CreditManagerV3(address(poolMock), address(0));

        cm.setLiquidationThreshold(underlying, 9200);

        (address token, uint16 lt) = cm.collateralTokens(0);
        assertEq(token, underlying, "incorrect underlying token");
        assertEq(lt, 9200, "incorrect lt for underlying token");

        uint16 ltAlt = cm.liquidationThresholds(underlying);
        assertEq(ltAlt, 9200, "incorrect lt for underlying token");

        assertEq(cm.collateralTokensCount(), 1, "Incorrect length");

        cm.addToken(newToken);
        assertEq(cm.collateralTokensCount(), 2, "Incorrect length");
        (token, lt) = cm.collateralTokens(1);

        assertEq(token, newToken, "incorrect newToken token");
        assertEq(lt, 0, "incorrect lt for  newToken token");

        cm.setLiquidationThreshold(newToken, newLT);
        (token, lt) = cm.collateralTokens(1);

        assertEq(token, newToken, "incorrect newToken token");
        assertEq(lt, newLT, "incorrect lt for  newToken token");

        ltAlt = cm.liquidationThresholds(newToken);

        assertEq(ltAlt, newLT, "incorrect lt for  newToken token");

        evm.stopPrank();
    }

    //
    // GET CREDIT ACCOUNT OR REVERT
    //

    /// @dev [CM-48]: getCreditAccountOrRevert reverts if borrower has no account
    // function test_CM_48_getCreditAccountOrRevert_reverts_if_borrower_has_no_account() public {
    //     (,,, address creditAccount) = _openCreditAccount();

    //     assertEq(creditManager.getCreditAccountOrRevert(USER), creditAccount, "Incorrect credit account");

    //     evm.expectRevert(CreditAccountNotExistsException.selector);
    //     creditManager.getCreditAccountOrRevert(DUMB_ADDRESS);
    // }

    //
    // CALC CREDIT ACCOUNT ACCRUED INTEREST
    //

    /// @dev [CM-49]: calcCreditAccountAccruedInterest computes correctly
    function test_CM_49_calcCreditAccountAccruedInterest_computes_correctly(uint128 amount) public {
        tokenTestSuite.mint(Tokens.DAI, address(poolMock), amount);
        (,,, address creditAccount) = cms.openCreditAccount(amount);

        uint256 expectedBorrowedAmount = amount;

        (, uint256 cumulativeIndexAtOpen,,,,) = creditManager.creditAccountInfo(creditAccount);

        uint256 cumulativeIndexNow = poolMock._cumulativeIndex_RAY();
        uint256 expectedBorrowedAmountWithInterest =
            (expectedBorrowedAmount * cumulativeIndexNow) / cumulativeIndexAtOpen;

        (uint256 feeInterest,,,,) = creditManager.fees();

        uint256 expectedFee =
            ((expectedBorrowedAmountWithInterest - expectedBorrowedAmount) * feeInterest) / PERCENTAGE_FACTOR;

        (uint256 borrowedAmount, uint256 borrowedAmountWithInterest, uint256 borrowedAmountWithInterestAndFees) =
            creditManager.calcCreditAccountAccruedInterest(creditAccount);

        assertEq(borrowedAmount, expectedBorrowedAmount, "Incorrect borrowed amount");
        assertEq(
            borrowedAmountWithInterest, expectedBorrowedAmountWithInterest, "Incorrect borrowed amount with interest"
        );
        assertEq(
            borrowedAmountWithInterestAndFees,
            expectedBorrowedAmountWithInterest + expectedFee,
            "Incorrect borrowed amount with interest and fees"
        );
    }

    //
    // GET CREDIT ACCOUNT PARAMETERS
    //

    /// @dev [CM-50]: getCreditAccountParameters return correct values
    function test_CM_50_getCreditAccountParameters_return_correct_values() public {
        // It enables  CreditManagerTestInternal for some test cases
        _connectCreditManagerSuite(Tokens.DAI, true);

        (,,, address creditAccount) = _openCreditAccount();

        (uint256 expectedDebt, uint256 expectedCumulativeIndexAtOpen,,,,) =
            creditManager.creditAccountInfo(creditAccount);

        CreditManagerTestInternal cmi = CreditManagerTestInternal(address(creditManager));

        (uint256 borrowedAmount, uint256 cumulativeIndexAtOpen,) = cmi.getCreditAccountParameters(creditAccount);

        assertEq(borrowedAmount, expectedDebt, "Incorrect borrowed amount");
        assertEq(cumulativeIndexAtOpen, expectedCumulativeIndexAtOpen, "Incorrect cumulativeIndexAtOpen");

        assertEq(cumulativeIndexAtOpen, expectedCumulativeIndexAtOpen, "cumulativeIndexAtOpen");
    }

    //
    // SET PARAMS
    //

    /// @dev [CM-51]: setParams sets configuration properly
    function test_CM_51_setParams_sets_configuration_properly() public {
        uint16 s_feeInterest = 8733;
        uint16 s_feeLiquidation = 1233;
        uint16 s_liquidationPremium = 1220;
        uint16 s_feeLiquidationExpired = 1221;
        uint16 s_liquidationPremiumExpired = 7777;

        evm.prank(CONFIGURATOR);
        creditManager.setParams(
            s_feeInterest, s_feeLiquidation, s_liquidationPremium, s_feeLiquidationExpired, s_liquidationPremiumExpired
        );
        (
            uint16 feeInterest,
            uint16 feeLiquidation,
            uint16 liquidationDiscount,
            uint16 feeLiquidationExpired,
            uint16 liquidationPremiumExpired
        ) = creditManager.fees();

        assertEq(feeInterest, s_feeInterest, "Incorrect feeInterest");
        assertEq(feeLiquidation, s_feeLiquidation, "Incorrect feeLiquidation");
        assertEq(liquidationDiscount, s_liquidationPremium, "Incorrect liquidationDiscount");
        assertEq(feeLiquidationExpired, s_feeLiquidationExpired, "Incorrect feeLiquidationExpired");
        assertEq(liquidationPremiumExpired, s_liquidationPremiumExpired, "Incorrect liquidationPremiumExpired");
    }

    //
    // ADD TOKEN
    //

    /// @dev [CM-52]: addToken reverts if token exists and if collateralTokens > 256
    function test_CM_52_addToken_reverts_if_token_exists_and_if_collateralTokens_more_256() public {
        evm.startPrank(CONFIGURATOR);

        evm.expectRevert(TokenAlreadyAddedException.selector);
        creditManager.addToken(underlying);

        for (uint256 i = creditManager.collateralTokensCount(); i < 248; i++) {
            creditManager.addToken(address(uint160(uint256(keccak256(abi.encodePacked(i))))));
        }

        evm.expectRevert(TooManyTokensException.selector);
        creditManager.addToken(DUMB_ADDRESS);

        evm.stopPrank();
    }

    /// @dev [CM-53]: addToken adds token and set tokenMaskMap correctly
    function test_CM_53_addToken_adds_token_and_set_tokenMaskMap_correctly() public {
        uint256 count = creditManager.collateralTokensCount();

        evm.prank(CONFIGURATOR);
        creditManager.addToken(DUMB_ADDRESS);

        assertEq(creditManager.collateralTokensCount(), count + 1, "collateralTokensCount want incremented");

        assertEq(creditManager.getTokenMaskOrRevert(DUMB_ADDRESS), 1 << count, "tokenMaskMap was set incorrectly");
    }

    //
    // SET LIQUIDATION THRESHOLD
    //

    /// @dev [CM-54]: setLiquidationThreshold reverts for unknown token
    function test_CM_54_setLiquidationThreshold_reverts_for_unknown_token() public {
        evm.prank(CONFIGURATOR);
        evm.expectRevert(TokenNotAllowedException.selector);
        creditManager.setLiquidationThreshold(DUMB_ADDRESS, 1200);
    }

    // //
    // // SET FORBID MASK
    // //
    // /// @dev [CM-55]: setForbidMask sets forbidMask correctly
    // function test_CM_55_setForbidMask_sets_forbidMask_correctly() public {
    //     uint256 expectedForbidMask = 244;

    //     assertTrue(creditManager.forbiddenTokenMask() != expectedForbidMask, "expectedForbidMask is already the same");

    //     evm.prank(CONFIGURATOR);
    //     creditManager.setForbidMask(expectedForbidMask);

    //     assertEq(creditManager.forbiddenTokenMask(), expectedForbidMask, "ForbidMask is not set correctly");
    // }

    //
    // CHANGE CONTRACT AllowanceAction
    //

    /// @dev [CM-56]: setContractAllowance updates adapterToContract
    function test_CM_56_setContractAllowance_updates_adapterToContract() public {
        assertTrue(
            creditManager.adapterToContract(ADAPTER) != DUMB_ADDRESS, "adapterToContract(ADAPTER) is already the same"
        );

        evm.prank(CONFIGURATOR);
        creditManager.setContractAllowance(ADAPTER, DUMB_ADDRESS);

        assertEq(creditManager.adapterToContract(ADAPTER), DUMB_ADDRESS, "adapterToContract is not set correctly");

        assertEq(creditManager.contractToAdapter(DUMB_ADDRESS), ADAPTER, "adapterToContract is not set correctly");

        evm.prank(CONFIGURATOR);
        creditManager.setContractAllowance(ADAPTER, address(0));

        assertEq(creditManager.adapterToContract(ADAPTER), address(0), "adapterToContract is not set correctly");

        assertEq(creditManager.contractToAdapter(address(0)), address(0), "adapterToContract is not set correctly");

        evm.prank(CONFIGURATOR);
        creditManager.setContractAllowance(ADAPTER, DUMB_ADDRESS);

        evm.prank(CONFIGURATOR);
        creditManager.setContractAllowance(address(0), DUMB_ADDRESS);

        assertEq(creditManager.adapterToContract(address(0)), address(0), "adapterToContract is not set correctly");

        assertEq(creditManager.contractToAdapter(DUMB_ADDRESS), address(0), "adapterToContract is not set correctly");

        // evm.prank(CONFIGURATOR);
        // creditManager.setContractAllowance(ADAPTER, UNIVERSAL_CONTRACT);

        // assertEq(creditManager.universalAdapter(), ADAPTER, "Universal adapter is not correctly set");

        // evm.prank(CONFIGURATOR);
        // creditManager.setContractAllowance(address(0), UNIVERSAL_CONTRACT);

        // assertEq(creditManager.universalAdapter(), address(0), "Universal adapter is not correctly set");
    }

    //
    // UPGRADE CONTRACTS
    //

    /// @dev [CM-57A]: setCreditFacade updates Credit Facade correctly
    function test_CM_57A_setCreditFacade_updates_contract_correctly() public {
        assertTrue(creditManager.creditFacade() != DUMB_ADDRESS, "creditFacade( is already the same");

        evm.prank(CONFIGURATOR);
        creditManager.setCreditFacade(DUMB_ADDRESS);

        assertEq(creditManager.creditFacade(), DUMB_ADDRESS, "creditFacade is not set correctly");
    }

    /// @dev [CM-57B]: setPriceOracle updates contract correctly
    function test_CM_57_setPriceOracle_updates_contract_correctly() public {
        assertTrue(address(creditManager.priceOracle()) != DUMB_ADDRESS2, "priceOracle is already the same");

        evm.prank(CONFIGURATOR);
        creditManager.setPriceOracle(DUMB_ADDRESS2);

        assertEq(address(creditManager.priceOracle()), DUMB_ADDRESS2, "priceOracle is not set correctly");
    }

    //
    // SET CONFIGURATOR
    //

    /// @dev [CM-58]: setCreditConfigurator sets creditConfigurator correctly and emits event
    function test_CM_58_setCreditConfigurator_sets_creditConfigurator_correctly_and_emits_event() public {
        assertTrue(creditManager.creditConfigurator() != DUMB_ADDRESS, "creditConfigurator is already the same");

        evm.prank(CONFIGURATOR);

        evm.expectEmit(true, false, false, false);
        emit SetCreditConfigurator(DUMB_ADDRESS);

        creditManager.setCreditConfigurator(DUMB_ADDRESS);

        assertEq(creditManager.creditConfigurator(), DUMB_ADDRESS, "creditConfigurator is not set correctly");
    }

    // /// @dev [CM-59]: _getTokenIndexByAddress works properly
    // function test_CM_59_getMaxIndex_works_properly(uint256 noise) public {
    //     CreditManagerTestInternal cm = new CreditManagerTestInternal(
    //         address(poolMock)
    //     );

    //     for (uint256 i = 0; i < 256; i++) {
    //         uint256 mask = 1 << i;
    //         if (mask > noise) mask |= noise;
    //         uint256 value = cm.getMaxIndex(mask);
    //         assertEq(i, value, "Incorrect result");
    //     }
    // }

    // /// @dev [CM-60]: CreditManagerV3 allows approveCreditAccount and executeOrder for universal adapter
    // function test_CM_60_universal_adapter_can_call_adapter_restricted_functions() public {
    //     TargetContractMock targetMock = new TargetContractMock();

    //     evm.prank(CONFIGURATOR);
    //     creditManager.setContractAllowance(ADAPTER, UNIVERSAL_CONTRACT_ADDRESS);

    //     _openAccountAndTransferToCF();

    //     evm.prank(ADAPTER);
    //     creditManager.approveCreditAccount(DUMB_ADDRESS, underlying, type(uint256).max);

    //     bytes memory callData = bytes("Hello");

    //     evm.prank(ADAPTER);
    //     creditManager.executeOrder(address(targetMock), callData);
    // }

    /// @dev [CM-61]: setMaxEnabledToken correctly sets value
    function test_CM_61_setMaxEnabledTokens_works_correctly() public {
        evm.prank(CONFIGURATOR);
        creditManager.setMaxEnabledTokens(255);

        assertEq(creditManager.maxAllowedEnabledTokenLength(), 255, "Incorrect max enabled tokens");
    }

    // /// @dev [CM-64]: closeCreditAccount reverts when attempting to liquidate while paused,
    // /// and the payer is not set as emergency liquidator

    // function test_CM_64_closeCreditAccount_reverts_when_paused_and_liquidator_not_privileged() public {
    //     evm.prank(CONFIGURATOR);
    //     creditManager.pause();

    //     evm.expectRevert("Pausable: paused");
    //     // creditManager.closeCreditAccount(USER, ClosureAction.LIQUIDATE_ACCOUNT, 0, LIQUIDATOR, FRIEND, 0, false);
    // }

    // /// @dev [CM-65]: Emergency liquidator can't close an account instead of liquidating

    // function test_CM_65_closeCreditAccount_reverts_when_paused_and_liquidator_tries_to_close() public {
    //     evm.startPrank(CONFIGURATOR);
    //     creditManager.pause();
    //     creditManager.addEmergencyLiquidator(LIQUIDATOR);
    //     evm.stopPrank();

    //     evm.expectRevert("Pausable: paused");
    //     // creditManager.closeCreditAccount(USER, ClosureAction.CLOSE_ACCOUNT, 0, LIQUIDATOR, FRIEND, 0, false);
    // }

    /// @dev [CM-66]: calcNewCumulativeIndex works correctly for various values
    function test_CM_66_calcNewCumulativeIndex_is_correct(
        uint128 borrowedAmount,
        uint256 indexAtOpen,
        uint256 indexNow,
        uint128 delta,
        bool isIncrease
    ) public {
        evm.assume(borrowedAmount > 100);
        evm.assume(uint256(borrowedAmount) + uint256(delta) <= 2 ** 128 - 1);

        indexNow = indexNow < RAY ? indexNow + RAY : indexNow;
        indexAtOpen = indexAtOpen < RAY ? indexAtOpen + RAY : indexNow;

        evm.assume(indexNow <= 100 * RAY);
        evm.assume(indexNow >= indexAtOpen);
        evm.assume(indexNow - indexAtOpen < 10 * RAY);

        uint256 interest = uint256((borrowedAmount * indexNow) / indexAtOpen - borrowedAmount);

        evm.assume(interest > 1);

        if (!isIncrease && (delta > interest)) delta %= uint128(interest);

        CreditManagerTestInternal cmi = new CreditManagerTestInternal(
            creditManager.poolService(), address(withdrawalManager)
        );

        if (isIncrease) {
            uint256 newIndex = cmi.calcNewCumulativeIndex(borrowedAmount, delta, indexNow, indexAtOpen, true);

            uint256 newInterestError = ((borrowedAmount + delta) * indexNow) / newIndex - (borrowedAmount + delta)
                - ((borrowedAmount * indexNow) / indexAtOpen - borrowedAmount);

            uint256 newTotalDebt = ((borrowedAmount + delta) * indexNow) / newIndex;

            assertLe((RAY * newInterestError) / newTotalDebt, 10000, "Interest error is larger than 10 ** -23");
        } else {
            uint256 newIndex = cmi.calcNewCumulativeIndex(borrowedAmount, delta, indexNow, indexAtOpen, false);

            uint256 newTotalDebt = ((borrowedAmount * indexNow) / newIndex);
            uint256 newInterestError = newTotalDebt - borrowedAmount - (interest - delta);

            emit log_uint(indexNow);
            emit log_uint(indexAtOpen);
            emit log_uint(interest);
            emit log_uint(delta);
            emit log_uint(interest - delta);
            emit log_uint(newTotalDebt);
            emit log_uint(borrowedAmount);
            emit log_uint(newInterestError);

            assertLe((RAY * newInterestError) / newTotalDebt, 10000, "Interest error is larger than 10 ** -23");
        }
    }

    // /// @dev [CM-67]: checkEmergencyPausable returns pause state and enable emergencyLiquidation if needed
    // function test_CM_67_checkEmergencyPausable_returns_pause_state_and_enable_emergencyLiquidation_if_needed() public {
    //     bool p = creditManager.checkEmergencyPausable(DUMB_ADDRESS, true);
    //     assertTrue(!p, "Incorrect paused() value for non-paused state");
    //     assertTrue(!creditManager.emergencyLiquidation(), "Emergency liquidation true when expected false");

    //     evm.prank(CONFIGURATOR);
    //     creditManager.pause();

    //     p = creditManager.checkEmergencyPausable(DUMB_ADDRESS, true);
    //     assertTrue(p, "Incorrect paused() value for paused state");
    //     assertTrue(!creditManager.emergencyLiquidation(), "Emergency liquidation true when expected false");

    //     evm.prank(CONFIGURATOR);
    //     creditManager.unpause();

    //     evm.prank(CONFIGURATOR);
    //     creditManager.addEmergencyLiquidator(DUMB_ADDRESS);
    //     p = creditManager.checkEmergencyPausable(DUMB_ADDRESS, true);
    //     assertTrue(!p, "Incorrect paused() value for non-paused state");
    //     assertTrue(!creditManager.emergencyLiquidation(), "Emergency liquidation true when expected false");

    //     evm.prank(CONFIGURATOR);
    //     creditManager.pause();

    //     p = creditManager.checkEmergencyPausable(DUMB_ADDRESS, true);
    //     assertTrue(p, "Incorrect paused() value for paused state");
    //     assertTrue(creditManager.emergencyLiquidation(), "Emergency liquidation flase when expected true");

    //     p = creditManager.checkEmergencyPausable(DUMB_ADDRESS, false);
    //     assertTrue(p, "Incorrect paused() value for paused state");
    //     assertTrue(!creditManager.emergencyLiquidation(), "Emergency liquidation true when expected false");
    // }

    /// @dev [CM-68]: fullCollateralCheck checks tokens in correct order
    function test_CM_68_fullCollateralCheck_is_evaluated_in_order_of_hints() public {
        (uint256 borrowedAmount, uint256 cumulativeIndexAtOpen, uint256 cumulativeIndexNow, address creditAccount) =
            _openCreditAccount();

        uint256 daiBalance = tokenTestSuite.balanceOf(Tokens.DAI, creditAccount);

        tokenTestSuite.burn(Tokens.DAI, creditAccount, daiBalance);

        uint256 borrowAmountWithInterest = borrowedAmount * cumulativeIndexNow / cumulativeIndexAtOpen;
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

        evm.expectCall(tokenTestSuite.addressOf(Tokens.USDT), abi.encodeCall(IERC20.balanceOf, (creditAccount)));
        evm.expectCall(tokenTestSuite.addressOf(Tokens.LINK), abi.encodeCall(IERC20.balanceOf, (creditAccount)));

        uint256 enabledTokensMap = 1 | creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.USDC))
            | creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.USDT))
            | creditManager.getTokenMaskOrRevert(tokenTestSuite.addressOf(Tokens.LINK));

        creditManager.fullCollateralCheck(creditAccount, enabledTokensMap, collateralHints, PERCENTAGE_FACTOR);

        // assertEq(cmi.fullCheckOrder(0), tokenTestSuite.addressOf(Tokens.USDT), "Token order incorrect");

        // assertEq(cmi.fullCheckOrder(1), tokenTestSuite.addressOf(Tokens.LINK), "Token order incorrect");

        // assertEq(cmi.fullCheckOrder(2), tokenTestSuite.addressOf(Tokens.DAI), "Token order incorrect");

        // assertEq(cmi.fullCheckOrder(3), tokenTestSuite.addressOf(Tokens.USDC), "Token order incorrect");
    }

    /// @dev [CM-70]: fullCollateralCheck reverts when an illegal mask is passed in collateralHints
    function test_CM_70_fullCollateralCheck_reverts_for_illegal_mask_in_hints() public {
        (,,, address creditAccount) = _openCreditAccount();

        evm.expectRevert(TokenNotAllowedException.selector);

        uint256[] memory ch = new uint256[](1);
        ch[0] = 3;

        uint256 enabledTokensMap = 1;

        creditManager.fullCollateralCheck(creditAccount, enabledTokensMap, ch, PERCENTAGE_FACTOR);
    }

    /// @dev [CM-71]: rampLiquidationThreshold correctly updates the internal struct
    function test_CM_71_rampLiquidationThreshold_correctly_updates_parameters() public {
        _connectCreditManagerSuite(Tokens.DAI, true);

        address usdc = tokenTestSuite.addressOf(Tokens.USDC);

        CreditManagerTestInternal cmi = CreditManagerTestInternal(address(creditManager));

        evm.prank(CONFIGURATOR);
        cmi.rampLiquidationThreshold(usdc, 8500, uint40(block.timestamp), 3600 * 24 * 7);

        CollateralTokenData memory cd = cmi.collateralTokensDataExt(cmi.getTokenMaskOrRevert(usdc));

        assertEq(uint256(cd.ltInitial), creditConfig.lt(Tokens.USDC), "Incorrect initial LT");

        assertEq(uint256(cd.ltFinal), 8500, "Incorrect final LT");

        assertEq(uint256(cd.timestampRampStart), block.timestamp, "Incorrect timestamp start");

        assertEq(uint256(cd.rampDuration), 3600 * 24 * 7, "Incorrect ramp duration");
    }

    /// @dev [CM-72]: Ramping liquidation threshold fuzzing
    function test_CM_72_liquidation_ramping_fuzzing(
        uint16 initialLT,
        uint16 newLT,
        uint24 duration,
        uint256 timestampCheck
    ) public {
        initialLT = 1000 + (initialLT % (DEFAULT_UNDERLYING_LT - 999));
        newLT = 1000 + (newLT % (DEFAULT_UNDERLYING_LT - 999));
        duration = 3600 + (duration % (3600 * 24 * 90 - 3600));

        timestampCheck = block.timestamp + (timestampCheck % (duration + 1));

        address usdc = tokenTestSuite.addressOf(Tokens.USDC);

        uint256 timestampStart = block.timestamp;

        evm.startPrank(CONFIGURATOR);
        creditManager.setLiquidationThreshold(usdc, initialLT);
        creditManager.rampLiquidationThreshold(usdc, newLT, uint40(block.timestamp), duration);

        assertEq(creditManager.liquidationThresholds(usdc), initialLT, "LT at ramping start incorrect");

        uint16 expectedLT;
        if (newLT >= initialLT) {
            expectedLT = uint16(
                uint256(initialLT)
                    + (uint256(newLT - initialLT) * (timestampCheck - timestampStart)) / uint256(duration)
            );
        } else {
            expectedLT = uint16(
                uint256(initialLT)
                    - (uint256(initialLT - newLT) * (timestampCheck - timestampStart)) / uint256(duration)
            );
        }

        evm.warp(timestampCheck);
        uint16 actualLT = creditManager.liquidationThresholds(usdc);
        uint16 diff = actualLT > expectedLT ? actualLT - expectedLT : expectedLT - actualLT;

        assertLe(diff, 1, "LT off by more than 1");

        evm.warp(timestampStart + duration + 1);

        assertEq(creditManager.liquidationThresholds(usdc), newLT, "LT at ramping end incorrect");
    }
}