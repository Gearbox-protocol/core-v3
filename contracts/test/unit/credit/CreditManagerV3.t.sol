// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.10;

/// MOCKS
import {AddressProviderACLMock} from "../../mocks/core/AddressProviderACLMock.sol";
import {AccountFactoryMock} from "../../mocks/core/AccountFactoryMock.sol";
import {ACL} from "@gearbox-protocol/core-v2/contracts/core/ACL.sol";

import {AccountFactory} from "@gearbox-protocol/core-v2/contracts/core/AccountFactory.sol";
import {CreditManagerV3Harness} from "./CreditManagerV3Harness.sol";

/// INTERFASE
import "../../../interfaces/IAddressProviderV3.sol";
import {ICreditAccount} from "@gearbox-protocol/core-v2/contracts/interfaces/ICreditAccount.sol";
import {
    ICreditManagerV3,
    ICreditManagerV3Events,
    ClosureAction,
    CollateralTokenData,
    ManageDebtAction
} from "../../../interfaces/ICreditManagerV3.sol";
import {IWETH} from "@gearbox-protocol/core-v2/contracts/interfaces/external/IWETH.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPriceOracleV2, IPriceOracleV2Ext} from "@gearbox-protocol/core-v2/contracts/interfaces/IPriceOracle.sol";
import {IWETHGateway} from "../../../interfaces/IWETHGateway.sol";
import {IWithdrawalManager} from "../../../interfaces/IWithdrawalManager.sol";

import {IPoolService} from "@gearbox-protocol/core-v2/contracts/interfaces/IPoolService.sol";

import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/PercentageMath.sol";

// LIBS & TRAITS
import {BitMask} from "../../../libraries/BitMask.sol";
// TESTS

import "../../lib/constants.sol";
import {BalanceHelper} from "../../helpers/BalanceHelper.sol";

// EXCEPTIONS
import "../../../interfaces/IExceptions.sol";

// MOCKS
import {PriceOracleMock} from "../../mocks/oracles/PriceOracleMock.sol";
import {PoolMock} from "../../mocks/pool/PoolMock.sol";

// SUITES
import {TokensTestSuite} from "../../suites/TokensTestSuite.sol";
import {Tokens} from "../../config/Tokens.sol";

import {CreditConfig} from "../../config/CreditConfig.sol";

// EXCEPTIONS
import "../../../interfaces/IExceptions.sol";

import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";

/// @title AddressRepository
/// @notice Stores addresses of deployed contracts
contract CreditManagerV3UnitTest is Test, ICreditManagerV3Events, BalanceHelper {
    using BitMask for uint256;

    IAddressProviderV3 addressProvider;
    IWETH wethToken;

    AccountFactoryMock af;
    CreditManagerV3Harness creditManager;
    PoolMock poolMock;
    IPriceOracleV2 priceOracle;
    IWETHGateway wethGateway;
    IWithdrawalManager withdrawalManager;

    address underlying;

    CreditConfig creditConfig;

    function setUp() public {
        tokenTestSuite = new TokensTestSuite();

        tokenTestSuite.topUpWETH{value: 100 * WAD}();

        underlying = makeAddr("UNDERLYING_TOKEN");

        addressProvider = new AddressProviderACLMock();
        poolMock = new PoolMock(address(addressProvider), underlying);
        creditManager = new CreditManagerV3Harness(address(addressProvider), address(poolMock));
    }

    ///
    /// HELPERS

    ///
    ///
    ///  TESTS
    ///
    ///
    /// @dev [CM-1]: credit manager reverts if were called non-creditFacade
    function test_CM_01_constructor_sets_correct_values() public {
        creditManager = new CreditManagerV3Harness(address(poolMock), address(withdrawalManager));

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

        assertEq(creditManager.wethAddress(), addressProvider.getAddress(AP_WETH_TOKEN), "Incorrect WETH token");

        assertEq(
            address(creditManager.wethGateway()), addressProvider.getAddress(AP_WETH_GATEWAY), "Incorrect WETH Gateway"
        );

        assertEq(
            address(creditManager.priceOracle()), addressProvider.getAddress(AP_PRICE_ORACLE), "Incorrect Price oracle"
        );

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

        vm.startPrank(USER);

        vm.expectRevert(CallerNotCreditFacadeException.selector);
        creditManager.openCreditAccount(200000, address(this), false);

        // vm.expectRevert(CallerNotCreditFacadeException.selector);
        // creditManager.closeCreditAccount(
        //     DUMB_ADDRESS, ClosureAction.LIQUIDATE_ACCOUNT, 0, DUMB_ADDRESS, DUMB_ADDRESS, type(uint256).max, false
        // );

        vm.expectRevert(CallerNotCreditFacadeException.selector);
        creditManager.manageDebt(DUMB_ADDRESS, 100, 0, ManageDebtAction.INCREASE_DEBT);

        vm.expectRevert(CallerNotCreditFacadeException.selector);
        creditManager.addCollateral(DUMB_ADDRESS, DUMB_ADDRESS, DUMB_ADDRESS, 100);

        vm.expectRevert(CallerNotCreditFacadeException.selector);
        creditManager.transferAccountOwnership(DUMB_ADDRESS, DUMB_ADDRESS);

        vm.stopPrank();
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

        vm.startPrank(USER);

        vm.expectRevert(CallerNotAdapterException.selector);
        creditManager.approveCreditAccount(DUMB_ADDRESS, 100);

        vm.expectRevert(CallerNotAdapterException.selector);
        creditManager.executeOrder(bytes("0"));

        vm.expectRevert(CallerNotCreditFacadeException.selector);
        creditManager.fullCollateralCheck(DUMB_ADDRESS, 0, new uint256[](0), 10000);

        vm.stopPrank();
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

        vm.startPrank(USER);

        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditManager.addToken(DUMB_ADDRESS);

        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditManager.setParams(0, 0, 0, 0, 0);

        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditManager.setCollateralTokenData(DUMB_ADDRESS, 0, 0, 0, 0);

        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditManager.setContractAllowance(DUMB_ADDRESS, DUMB_ADDRESS);

        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditManager.setCreditFacade(DUMB_ADDRESS);

        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditManager.setPriceOracle(DUMB_ADDRESS);

        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditManager.setCreditConfigurator(DUMB_ADDRESS);

        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditManager.setMaxEnabledTokens(255);

        vm.stopPrank();
    }
}
