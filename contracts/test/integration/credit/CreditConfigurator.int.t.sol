// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import "../../interfaces/IAddressProviderV3.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {CreditFacadeV3} from "../../../credit/CreditFacadeV3.sol";
import {CreditManagerV3} from "../../../credit/CreditManagerV3.sol";
import {PriceOracleV3} from "../../../core/PriceOracleV3.sol";
import {BotListV3} from "../../../core/BotListV3.sol";

import {CreditConfiguratorV3, AllowanceAction} from "../../../credit/CreditConfiguratorV3.sol";
import {ICreditManagerV3} from "../../../interfaces/ICreditManagerV3.sol";
import {ICreditConfiguratorV3Events} from "../../../interfaces/ICreditConfiguratorV3.sol";
import {IAdapter} from "../../../interfaces/base/IAdapter.sol";

//
import "../../../libraries/Constants.sol";
import {AddressList} from "../../lib/AddressList.sol";

// EXCEPTIONS

import "../../../interfaces/IExceptions.sol";

// TEST
import "../../lib/constants.sol";

// MOCKS
import {AdapterMock} from "../../mocks//core/AdapterMock.sol";
import {TargetContractMock} from "../../mocks/core/TargetContractMock.sol";
import {CreditFacadeV3Harness} from "../../unit/credit/CreditFacadeV3Harness.sol";
import {IntegrationTestHelper} from "../../helpers/IntegrationTestHelper.sol";

// SUITES
import {TokensTestSuite} from "../../suites/TokensTestSuite.sol";
import {Tokens} from "@gearbox-protocol/sdk-gov/contracts/Tokens.sol";

import {CollateralTokenHuman} from "../../interfaces/ICreditConfig.sol";

import "forge-std/console.sol";

contract CreditConfiguratorIntegrationTest is IntegrationTestHelper, ICreditConfiguratorV3Events {
    using AddressList for address[];

    function getAdapterDifferentCM() internal returns (AdapterMock) {
        address CM = makeAddr("Different CM");

        vm.mockCall(CM, abi.encodeCall(IAdapter.creditManager, ()), abi.encode(CM));
        // vm.mockCall(CM, abi.encodeCall(ICreditManagerV3.addressProvider, ()), abi.encode((address(addressProvider))));

        address TARGET_CONTRACT = makeAddr("Target Contract");

        return new AdapterMock(CM, TARGET_CONTRACT);
    }

    //
    // HELPERS
    //
    function _compareParams(
        uint16 feeLiquidation,
        uint16 liquidationDiscount,
        uint16 feeLiquidationExpired,
        uint16 liquidationDiscountExpired
    ) internal {
        (
            ,
            uint16 feeLiquidation2,
            uint16 liquidationDiscount2,
            uint16 feeLiquidationExpired2,
            uint16 liquidationDiscountExpired2
        ) = creditManager.fees();

        assertEq(feeLiquidation2, feeLiquidation, "Incorrect feeLiquidation");
        assertEq(liquidationDiscount2, liquidationDiscount, "Incorrect liquidationDiscount");
        assertEq(feeLiquidationExpired2, feeLiquidationExpired, "Incorrect feeLiquidationExpired");
        assertEq(liquidationDiscountExpired2, liquidationDiscountExpired, "Incorrect liquidationDiscountExpired");
    }

    function _getAddress(bytes memory bytecode, uint256 _salt) public view returns (address) {
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), address(this), _salt, keccak256(bytecode)));

        // NOTE: cast last 20 bytes of hash to address
        return address(uint160(uint256(hash)));
    }

    function _deploy(bytes memory bytecode, uint256 _salt) public payable {
        address addr;

        /*
        NOTE: How to call create2
        create2(v, p, n, s)
        create new contract with code at memory p to p + n
        and send v wei
        and return the new address
        where new address = first 20 bytes of keccak256(0xff + address(this) + s + keccak256(mem[p…(p+n)))
              s = big-endian 256-bit value
        */
        assembly {
            addr :=
                create2(
                    callvalue(), // wei sent with current call
                    // Actual code starts after skipping the first 32 bytes
                    add(bytecode, 0x20),
                    mload(bytecode), // Load the size of code contained in the first 32 bytes
                    _salt // Salt from function arguments
                )

            if iszero(extcodesize(addr)) { revert(0, 0) }
        }
    }

    ///
    ///
    ///  TESTS
    ///
    ///

    /// @dev I:[CC-1]: constructor sets correct values
    function test_I_CC_01_constructor_sets_correct_values() public creditTest {
        assertEq(address(creditConfigurator.creditManager()), address(creditManager), "Incorrect creditManager");

        assertEq(address(creditConfigurator.creditFacade()), address(creditFacade), "Incorrect creditFacade");

        assertEq(address(creditConfigurator.underlying()), address(creditManager.underlying()), "Incorrect underlying");

        // CREDIT MANAGER PARAMS

        (
            uint16 feeInterest,
            uint16 feeLiquidation,
            uint16 liquidationDiscount,
            uint16 feeLiquidationExpired,
            uint16 liquidationDiscountExpired
        ) = creditManager.fees();

        assertEq(feeInterest, DEFAULT_FEE_INTEREST, "Incorrect feeInterest");

        assertEq(feeLiquidation, DEFAULT_FEE_LIQUIDATION, "Incorrect feeLiquidation");

        assertEq(liquidationDiscount, PERCENTAGE_FACTOR - DEFAULT_LIQUIDATION_PREMIUM, "Incorrect liquidationDiscount");

        assertEq(feeLiquidationExpired, DEFAULT_FEE_LIQUIDATION_EXPIRED, "Incorrect feeLiquidationExpired");

        assertEq(
            liquidationDiscountExpired,
            PERCENTAGE_FACTOR - DEFAULT_LIQUIDATION_PREMIUM_EXPIRED,
            "Incorrect liquidationDiscountExpired"
        );

        CollateralTokenHuman[8] memory collateralTokenOpts = [
            CollateralTokenHuman({token: Tokens.DAI, lt: DEFAULT_UNDERLYING_LT}),
            CollateralTokenHuman({token: Tokens.USDC, lt: 9000}),
            CollateralTokenHuman({token: Tokens.USDT, lt: 8800}),
            CollateralTokenHuman({token: Tokens.WETH, lt: 8300}),
            CollateralTokenHuman({token: Tokens.LINK, lt: 7300}),
            CollateralTokenHuman({token: Tokens.CRV, lt: 7300}),
            CollateralTokenHuman({token: Tokens.CVX, lt: 7300}),
            CollateralTokenHuman({token: Tokens.STETH, lt: 7300})
        ];

        uint256 len = collateralTokenOpts.length;

        // Allowed Tokens
        assertEq(creditManager.collateralTokensCount(), len, "Incorrect quantity of allowed tokens");

        for (uint256 i = 0; i < len; i++) {
            (address token, uint16 lt) = creditManager.collateralTokenByMask(1 << i);

            assertEq(token, tokenTestSuite.addressOf(collateralTokenOpts[i].token), "Incorrect token address");

            assertEq(lt, collateralTokenOpts[i].lt, "Incorrect liquidation threshold");
        }

        assertEq(address(creditManager.creditFacade()), address(creditFacade), "Incorrect creditFacade");

        assertEq(address(creditManager.priceOracle()), address(priceOracle), "Incorrect creditFacade");

        // CREDIT FACADE PARAMS
        // (uint128 minDebt, uint128 maxDebt) = creditFacade.debtLimits();

        // todo: fix
        // assertEq(minDebt, cct.minDebt(), "Incorrect minDebt");

        // assertEq(maxDebt, cct.maxDebt(), "Incorrect maxDebt");

        uint8 maxDebtPerBlock = creditFacade.maxDebtPerBlockMultiplier();

        uint40 expirationDate = creditFacade.expirationDate();

        assertEq(maxDebtPerBlock, DEFAULT_LIMIT_PER_BLOCK_MULTIPLIER, "Incorrect  maxDebtPerBlock");

        assertEq(expirationDate, 0, "Incorrect expiration date");
    }

    /// @dev I:[CC-2]: configuratorOnly functions revert on non-configurator
    function test_I_CC_02_configuratorOnly_functions_revert_on_non_configurator() public creditTest {
        vm.startPrank(USER);

        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditConfigurator.addCollateralToken(DUMB_ADDRESS, 1);

        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditConfigurator.allowAdapter(DUMB_ADDRESS);

        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditConfigurator.setFees(0, 0, 0, 0);

        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditConfigurator.setPriceOracle(address(1));

        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditConfigurator.setCreditFacade(DUMB_ADDRESS);

        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditConfigurator.upgradeCreditConfigurator(DUMB_ADDRESS);

        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditConfigurator.addEmergencyLiquidator(address(0));

        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditConfigurator.removeEmergencyLiquidator(address(0));

        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditConfigurator.setExpirationDate(0);

        vm.stopPrank();
    }

    /// @dev I:[CC-2A]: pausableAdminOnly functions revert on non-pausable admin
    function test_I_CC_02A_pausableAdminsOnly_functions_revert_on_non_pausable_admin() public creditTest {
        vm.expectRevert(CallerNotPausableAdminException.selector);
        creditConfigurator.forbidBorrowing();

        vm.expectRevert(CallerNotPausableAdminException.selector);
        creditConfigurator.forbidToken(DUMB_ADDRESS);
    }

    /// @dev I:[CC-2B]: controllerOnly functions revert on non-pausable admin
    function test_I_CC_02B_controllerOnly_functions_revert_on_non_controller() public creditTest {
        vm.expectRevert(CallerNotControllerException.selector);
        creditConfigurator.setLiquidationThreshold(DUMB_ADDRESS, uint16(0));

        vm.expectRevert(CallerNotControllerException.selector);
        creditConfigurator.rampLiquidationThreshold(DUMB_ADDRESS, 0, 0, 0);

        vm.expectRevert(CallerNotControllerException.selector);
        creditConfigurator.allowToken(DUMB_ADDRESS);

        vm.expectRevert(CallerNotControllerException.selector);
        creditConfigurator.forbidAdapter(DUMB_ADDRESS);

        vm.expectRevert(CallerNotControllerException.selector);
        creditConfigurator.setMinDebtLimit(0);

        vm.expectRevert(CallerNotControllerException.selector);
        creditConfigurator.setMaxDebtLimit(0);

        vm.expectRevert(CallerNotControllerException.selector);
        creditConfigurator.setMaxDebtPerBlockMultiplier(0);

        vm.expectRevert(CallerNotControllerException.selector);
        creditConfigurator.setMaxCumulativeLoss(0);

        vm.expectRevert(CallerNotControllerException.selector);
        creditConfigurator.resetCumulativeLoss();
    }

    //
    // TOKEN MANAGEMENT
    //

    /// @dev I:[CC-3]: addCollateralToken reverts as expected
    function test_I_CC_03_addCollateralToken_reverts_as_expected() public creditTest {
        vm.startPrank(CONFIGURATOR);

        vm.expectRevert(ZeroAddressException.selector);
        creditConfigurator.addCollateralToken(address(0), 9300);

        vm.expectRevert(TokenNotAllowedException.selector);
        creditConfigurator.addCollateralToken(underlying, 9300);

        vm.expectRevert(abi.encodeWithSelector(AddressIsNotContractException.selector, DUMB_ADDRESS));
        creditConfigurator.addCollateralToken(DUMB_ADDRESS, 9300);

        vm.expectRevert(IncorrectTokenContractException.selector);
        creditConfigurator.addCollateralToken(address(this), 9300);

        address unknownPricefeedToken = address(new ERC20("TWPF", "Token without priceFeed"));

        vm.expectRevert(PriceFeedDoesNotExistException.selector);
        creditConfigurator.addCollateralToken(unknownPricefeedToken, 9300);

        address nonQuotedToken = tokenTestSuite.addressOf(Tokens.wstETH);
        vm.expectRevert(TokenIsNotQuotedException.selector);
        creditConfigurator.addCollateralToken(nonQuotedToken, 9300);

        vm.stopPrank();
    }

    /// @dev I:[CC-4]: addCollateralToken adds new token to creditManager
    function test_I_CC_04_addCollateralToken_adds_new_token_to_creditManager_and_set_lt() public creditTest {
        uint256 tokensCountBefore = creditManager.collateralTokensCount();

        address newToken = tokenTestSuite.addressOf(Tokens.wstETH);
        makeTokenQuoted(newToken, 1, type(uint96).max);

        vm.expectEmit(true, false, false, false);
        emit AddCollateralToken(newToken);

        vm.prank(CONFIGURATOR);
        creditConfigurator.addCollateralToken(newToken, 8800);

        assertEq(creditManager.collateralTokensCount(), tokensCountBefore + 1, "Incorrect tokens count");

        (address token,) = creditManager.collateralTokenByMask(1 << tokensCountBefore);

        assertEq(token, newToken, "Token is not added to list");

        assertTrue(creditManager.getTokenMaskOrRevert(newToken) > 0, "Incorrect token mask");

        assertEq(creditManager.liquidationThresholds(newToken), 8800, "Threshold wasn't set");
    }

    /// @dev I:[CC-5]: setLiquidationThreshold reverts for underling token and incorrect values
    function test_I_CC_05_setLiquidationThreshold_reverts_for_underling_token_and_incorrect_values()
        public
        creditTest
    {
        vm.startPrank(CONFIGURATOR);

        vm.expectRevert(TokenNotAllowedException.selector);
        creditConfigurator.setLiquidationThreshold(underlying, 1);

        address usdcToken = tokenTestSuite.addressOf(Tokens.USDC);

        uint16 maxAllowedLT = creditManager.liquidationThresholds(underlying);
        vm.expectRevert(IncorrectLiquidationThresholdException.selector);
        creditConfigurator.setLiquidationThreshold(usdcToken, maxAllowedLT + 1);

        vm.stopPrank();
    }

    /// @dev I:[CC-6]: setLiquidationThreshold sets liquidation threshold in creditManager
    function test_I_CC_06_setLiquidationThreshold_sets_liquidation_threshold_in_creditManager() public creditTest {
        address usdcToken = tokenTestSuite.addressOf(Tokens.USDC);
        uint16 newLT = 24;

        vm.expectEmit(true, false, false, true);
        emit SetTokenLiquidationThreshold(usdcToken, newLT);

        vm.prank(CONFIGURATOR);
        creditConfigurator.setLiquidationThreshold(usdcToken, newLT);

        assertEq(creditManager.liquidationThresholds(usdcToken), newLT);
    }

    /// @dev I:[CC-7]: allowToken and forbidToken reverts for unknown or underlying token
    function test_I_CC_07_allowToken_and_forbidToken_reverts_for_unknown_or_underlying_token() public creditTest {
        vm.startPrank(CONFIGURATOR);

        vm.expectRevert(TokenNotAllowedException.selector);
        creditConfigurator.allowToken(DUMB_ADDRESS);

        vm.expectRevert(TokenNotAllowedException.selector);
        creditConfigurator.allowToken(underlying);

        vm.expectRevert(TokenNotAllowedException.selector);
        creditConfigurator.forbidToken(DUMB_ADDRESS);

        vm.expectRevert(TokenNotAllowedException.selector);
        creditConfigurator.forbidToken(underlying);

        vm.stopPrank();
    }

    /// @dev I:[CC-8]: allowToken works correctly
    function test_I_CC_08_allowToken_works_correctly() public creditTest {
        address usdcToken = tokenTestSuite.addressOf(Tokens.USDC);
        uint256 forbiddenMask = creditFacade.forbiddenTokenMask();

        vm.prank(CONFIGURATOR);
        creditConfigurator.allowToken(usdcToken);

        assertEq(creditFacade.forbiddenTokenMask(), forbiddenMask, "Incorrect forbidden mask");

        vm.prank(CONFIGURATOR);
        creditConfigurator.forbidToken(usdcToken);

        vm.expectEmit(true, false, false, false);
        emit AllowToken(usdcToken);

        vm.prank(CONFIGURATOR);
        creditConfigurator.allowToken(usdcToken);

        assertEq(creditFacade.forbiddenTokenMask(), 0, "Incorrect forbidden mask");
    }

    /// @dev I:[CC-9]: forbidToken works correctly
    function test_I_CC_09_forbidToken_works_correctly() public creditTest {
        address usdcToken = tokenTestSuite.addressOf(Tokens.USDC);
        uint256 usdcMask = creditManager.getTokenMaskOrRevert(usdcToken);

        vm.expectEmit(true, false, false, false);
        emit ForbidToken(usdcToken);

        vm.prank(CONFIGURATOR);
        creditConfigurator.forbidToken(usdcToken);

        assertEq(creditFacade.forbiddenTokenMask(), usdcMask, "Incorrect forbidden mask");

        vm.prank(CONFIGURATOR);
        creditConfigurator.forbidToken(usdcToken);

        assertEq(creditFacade.forbiddenTokenMask(), usdcMask, "Incorrect forbidden mask");
    }

    //
    // CONFIGURATION: CONTRACTS & ADAPTERS MANAGEMENT
    //

    /// @dev I:[CC-10]: allowAdapter and forbidAdapter reverts for zero address
    function test_I_CC_10_allowAdapter_and_forbidAdapter_reverts_for_zero_address() public withAdapterMock creditTest {
        vm.startPrank(CONFIGURATOR);

        vm.expectRevert(ZeroAddressException.selector);
        creditConfigurator.allowAdapter(address(0));

        vm.mockCall(address(adapterMock), abi.encodeCall(IAdapter.targetContract, ()), abi.encode(address(0)));

        vm.expectRevert(TargetContractNotAllowedException.selector);
        creditConfigurator.allowAdapter(address(adapterMock));

        vm.expectRevert(ZeroAddressException.selector);
        creditConfigurator.forbidAdapter(address(0));

        vm.expectRevert(TargetContractNotAllowedException.selector);
        creditConfigurator.forbidAdapter(address(adapterMock));

        vm.stopPrank();
    }

    /// @dev I:[CC-10A]: allowAdapter reverts for non contract addresses
    function test_I_CC_10A_allowAdapter_reverts_for_non_contract_addresses() public creditTest {
        vm.startPrank(CONFIGURATOR);

        vm.expectRevert(abi.encodeWithSelector(AddressIsNotContractException.selector, DUMB_ADDRESS));
        creditConfigurator.allowAdapter(DUMB_ADDRESS);

        vm.stopPrank();
    }

    /// @dev I:[CC-10B]: allowAdapter reverts for non compartible adapter contract
    function test_I_CC_10B_allowAdapter_reverts_for_non_compartible_adapter_contract() public creditTest {
        AdapterMock adapterDifferentCM = getAdapterDifferentCM();

        vm.startPrank(CONFIGURATOR);

        // Should be reverted, cause it's conncted to another creditManager
        vm.expectRevert(IncompatibleContractException.selector);
        creditConfigurator.allowAdapter(address(adapterDifferentCM));

        vm.stopPrank();
    }

    /// @dev I:[CC-10C]: allowAdapter reverts for creditManager and creditFacade contracts
    function test_I_CC_10C_allowAdapter_reverts_for_creditManager_and_creditFacade_contracts()
        public
        withAdapterMock
        creditTest
    {
        vm.startPrank(CONFIGURATOR);

        vm.mockCall(
            address(adapterMock), abi.encodeCall(IAdapter.targetContract, ()), abi.encode(address(creditManager))
        );

        vm.expectRevert(TargetContractNotAllowedException.selector);
        creditConfigurator.allowAdapter(address(adapterMock));

        vm.mockCall(
            address(adapterMock), abi.encodeCall(IAdapter.targetContract, ()), abi.encode(address(creditFacade))
        );

        vm.expectRevert(TargetContractNotAllowedException.selector);
        creditConfigurator.allowAdapter(address(adapterMock));

        vm.stopPrank();
    }

    /// @dev I:[CC-11]: allowAdapter allows targetContract <-> adapter and emits event
    function test_I_CC_11_allowAdapter_allows_targetContract_adapter_and_emits_event() public creditTest {
        address[] memory allowedAdapters = creditConfigurator.allowedAdapters();
        uint256 allowedAdapterCount = allowedAdapters.length;

        targetMock = new TargetContractMock();
        adapterMock = new AdapterMock(address(creditManager), address(targetMock));

        vm.prank(CONFIGURATOR);

        vm.expectEmit(true, true, false, false);
        emit AllowAdapter(address(targetMock), address(adapterMock));

        assertTrue(!allowedAdapters.includes(address(targetMock)), "Contract already added");

        creditConfigurator.allowAdapter(address(adapterMock));

        assertEq(
            creditManager.adapterToContract(address(adapterMock)),
            address(targetMock),
            "adapterToContract wasn't udpated"
        );

        assertEq(
            creditManager.contractToAdapter(address(targetMock)),
            address(adapterMock),
            "contractToAdapter wasn't udpated"
        );

        allowedAdapters = creditConfigurator.allowedAdapters();

        assertEq(allowedAdapters.length, allowedAdapterCount + 1, "Incorrect allowed contracts count");

        assertTrue(allowedAdapters.includes(address(adapterMock)), "Target contract wasnt found");
    }

    /// @dev I:[CC-12]: allowAdapter removes existing adapter
    function test_I_CC_12_allowAdapter_removes_old_adapter_if_it_exists() public withAdapterMock creditTest {
        vm.prank(CONFIGURATOR);
        creditConfigurator.allowAdapter(address(adapterMock));

        AdapterMock adapter2 = new AdapterMock(address(creditManager), address(targetMock));

        vm.prank(CONFIGURATOR);
        creditConfigurator.allowAdapter(address(adapter2));

        assertEq(creditManager.contractToAdapter(address(targetMock)), address(adapter2), "Incorrect adapter");

        assertEq(
            creditManager.adapterToContract(address(adapter2)),
            address(targetMock),
            "Incorrect target contract for new adapter"
        );

        address[] memory allowedAdapters = creditConfigurator.allowedAdapters();
        assertFalse(allowedAdapters.includes(address(adapterMock)), "Old adapter was not removed");

        assertEq(creditManager.adapterToContract(address(adapterMock)), address(0), "Old adapter was not removed");
    }

    /// @dev I:[CC-13]: forbidAdapter reverts for non-connected adapter
    function test_I_CC_13_forbidAdapter_reverts_for_unknown_contract() public withAdapterMock creditTest {
        AdapterMock adapter2 = new AdapterMock(address(creditManager), address(targetMock));

        vm.prank(CONFIGURATOR);
        creditConfigurator.allowAdapter(address(adapterMock));

        vm.expectRevert(AdapterIsNotRegisteredException.selector);

        vm.prank(CONFIGURATOR);
        creditConfigurator.forbidAdapter(address(adapter2));
    }

    /// @dev I:[CC-14]: forbidAdapter forbids contract and emits event
    function test_I_CC_14_forbidAdapter_forbids_contract_and_emits_event() public withAdapterMock creditTest {
        vm.startPrank(CONFIGURATOR);
        creditConfigurator.allowAdapter(address(adapterMock));

        address[] memory allowedAdapters = creditConfigurator.allowedAdapters();

        uint256 allowedAdapterCount = allowedAdapters.length;

        assertTrue(allowedAdapters.includes(address(adapterMock)), "Target contract wasnt found");

        vm.expectEmit(true, true, false, false);
        emit ForbidAdapter(address(targetMock), address(adapterMock));

        creditConfigurator.forbidAdapter(address(adapterMock));

        //
        allowedAdapters = creditConfigurator.allowedAdapters();

        assertEq(creditManager.adapterToContract(address(adapterMock)), address(0), "CreditManagerV3 wasn't udpated");

        assertEq(creditManager.contractToAdapter(address(targetMock)), address(0), "CreditFacadeV3 wasn't udpated");

        assertEq(allowedAdapters.length, allowedAdapterCount - 1, "Incorrect allowed contracts count");

        assertTrue(!allowedAdapters.includes(address(adapterMock)), "Target contract wasn't removed");

        vm.stopPrank();
    }

    //
    // CREDIT MANAGER MGMT
    //

    /// @dev I:[CC-15]: setMinDebtLimit and setMaxDebtLimit revert if minAmount > maxAmount
    function test_I_CC_15_setMinDebtLimit_setMaxDebtLimit_revert_if_minAmount_gt_maxAmount() public creditTest {
        (uint128 minDebt, uint128 maxDebt) = creditFacade.debtLimits();

        vm.expectRevert(IncorrectLimitsException.selector);
        vm.prank(CONFIGURATOR);
        creditConfigurator.setMinDebtLimit(maxDebt + 1);

        vm.expectRevert(IncorrectLimitsException.selector);
        vm.prank(CONFIGURATOR);
        creditConfigurator.setMaxDebtLimit(minDebt - 1);
    }

    /// @dev I:[CC-16]: setMinDebtLimit and setMaxDebtLimit set limits
    function test_I_CC_16_setLimits_sets_limits() public creditTest {
        (uint128 minDebtOld, uint128 maxDebtOld) = creditFacade.debtLimits();
        uint128 newminDebt = minDebtOld + 1000;
        uint128 newmaxDebt = maxDebtOld + 1000;

        vm.expectEmit(false, false, false, true);
        emit SetBorrowingLimits(newminDebt, maxDebtOld);
        vm.prank(CONFIGURATOR);
        creditConfigurator.setMinDebtLimit(newminDebt);
        (uint128 minDebt, uint128 maxDebt) = creditFacade.debtLimits();
        assertEq(minDebt, newminDebt, "Incorrect minDebt");
        assertEq(maxDebt, maxDebtOld, "Incorrect maxDebt");

        vm.expectEmit(false, false, false, true);
        emit SetBorrowingLimits(newminDebt, newmaxDebt);
        vm.prank(CONFIGURATOR);
        creditConfigurator.setMaxDebtLimit(newmaxDebt);
        (minDebt, maxDebt) = creditFacade.debtLimits();
        assertEq(minDebt, newminDebt, "Incorrect minDebt");
        assertEq(maxDebt, newmaxDebt, "Incorrect maxDebt");
    }

    /// @dev I:[CC-17]: setFees reverts for incorrect fees
    function test_I_CC_17_setFees_reverts_for_incorrect_fees() public creditTest {
        (, uint16 feeLiquidation,, uint16 feeLiquidationExpired,) = creditManager.fees();

        vm.expectRevert(IncorrectParameterException.selector);

        vm.prank(CONFIGURATOR);
        creditConfigurator.setFees(feeLiquidation, PERCENTAGE_FACTOR - feeLiquidation, 0, 0);

        vm.expectRevert(IncorrectParameterException.selector);

        vm.prank(CONFIGURATOR);
        creditConfigurator.setFees(
            feeLiquidation,
            PERCENTAGE_FACTOR - feeLiquidation - 1,
            feeLiquidationExpired,
            PERCENTAGE_FACTOR - feeLiquidationExpired
        );
    }

    /// @dev I:[CC-18]: setFees updates LT for underlying or reverts
    function test_I_CC_18_setFees_updates_LT_for_underlying_or_reverts() public creditTest {
        address usdc = tokenTestSuite.addressOf(Tokens.USDC);

        uint16 expectedLT = PERCENTAGE_FACTOR - DEFAULT_LIQUIDATION_PREMIUM - 2 * DEFAULT_FEE_LIQUIDATION;

        vm.startPrank(CONFIGURATOR);

        creditConfigurator.setLiquidationThreshold(usdc, expectedLT + 1);
        vm.expectRevert(IncorrectLiquidationThresholdException.selector);
        creditConfigurator.setFees(
            2 * DEFAULT_FEE_LIQUIDATION,
            DEFAULT_LIQUIDATION_PREMIUM,
            DEFAULT_FEE_LIQUIDATION_EXPIRED,
            DEFAULT_LIQUIDATION_PREMIUM_EXPIRED
        );
        creditConfigurator.setLiquidationThreshold(usdc, expectedLT - 1);

        creditConfigurator.rampLiquidationThreshold(usdc, expectedLT + 1, uint40(block.timestamp + 1), 1);
        vm.expectRevert(IncorrectLiquidationThresholdException.selector);
        creditConfigurator.setFees(
            2 * DEFAULT_FEE_LIQUIDATION,
            DEFAULT_LIQUIDATION_PREMIUM,
            DEFAULT_FEE_LIQUIDATION_EXPIRED,
            DEFAULT_LIQUIDATION_PREMIUM_EXPIRED
        );
        creditConfigurator.setLiquidationThreshold(usdc, expectedLT - 1);

        vm.expectEmit(true, false, false, true);
        emit SetTokenLiquidationThreshold(underlying, uint16(expectedLT));

        creditConfigurator.setFees(
            2 * DEFAULT_FEE_LIQUIDATION,
            DEFAULT_LIQUIDATION_PREMIUM,
            DEFAULT_FEE_LIQUIDATION_EXPIRED,
            DEFAULT_LIQUIDATION_PREMIUM_EXPIRED
        );

        assertEq(creditManager.liquidationThresholds(underlying), expectedLT, "Incorrect LT for underlying token");
    }

    /// @dev I:[CC-19]: setFees sets fees and doesn't change others
    function test_I_CC_19_setFees_sets_fees_and_doesnt_change_others() public creditTest {
        (
            ,
            uint16 feeLiquidation,
            uint16 liquidationDiscount,
            uint16 feeLiquidationExpired,
            uint16 liquidationDiscountExpired
        ) = creditManager.fees();

        uint16 newFeeLiquidation = feeLiquidation * 3 / 2;
        uint16 newLiquidationPremium = (PERCENTAGE_FACTOR - liquidationDiscount) * 3 / 2;
        uint16 newFeeLiquidationExpired = feeLiquidationExpired * 3 / 2;
        uint16 newLiquidationPremiumExpired = (PERCENTAGE_FACTOR - liquidationDiscountExpired) * 3 / 2;

        vm.expectEmit(false, false, false, true);
        emit UpdateFees(
            newFeeLiquidation, newLiquidationPremium, newFeeLiquidationExpired, newLiquidationPremiumExpired
        );

        vm.prank(CONFIGURATOR);
        creditConfigurator.setFees(
            newFeeLiquidation, newLiquidationPremium, newFeeLiquidationExpired, newLiquidationPremiumExpired
        );

        _compareParams(
            newFeeLiquidation,
            PERCENTAGE_FACTOR - newLiquidationPremium,
            newFeeLiquidationExpired,
            PERCENTAGE_FACTOR - newLiquidationPremiumExpired
        );
    }

    /// @dev I:[CC-20]: contract upgrade functions revert on zero and incompatible addresses
    function test_I_CC_20_contract_upgrade_functions_revert_on_incompatible_addresses() public creditTest {
        vm.startPrank(CONFIGURATOR);

        vm.expectRevert(ZeroAddressException.selector);
        creditConfigurator.setCreditFacade(address(0));

        vm.expectRevert(ZeroAddressException.selector);
        creditConfigurator.upgradeCreditConfigurator(address(0));

        vm.expectRevert(abi.encodeWithSelector(AddressIsNotContractException.selector, DUMB_ADDRESS));
        creditConfigurator.setCreditFacade(DUMB_ADDRESS);

        vm.expectRevert(abi.encodeWithSelector(AddressIsNotContractException.selector, DUMB_ADDRESS));
        creditConfigurator.upgradeCreditConfigurator(DUMB_ADDRESS);

        vm.expectRevert(IncompatibleContractException.selector);
        creditConfigurator.setCreditFacade(underlying);

        vm.expectRevert(IncompatibleContractException.selector);
        creditConfigurator.upgradeCreditConfigurator(underlying);

        AdapterMock adapterDifferentCM = getAdapterDifferentCM();

        vm.expectRevert(IncompatibleContractException.selector);
        creditConfigurator.setCreditFacade(address(adapterDifferentCM));

        vm.expectRevert(IncompatibleContractException.selector);
        creditConfigurator.upgradeCreditConfigurator(address(adapterDifferentCM));
    }

    /// @dev I:[CC-21]: setPriceOracle upgrades priceOracle correctly
    function test_I_CC_21_setPriceOracle_upgrades_priceOracle_correctly() public creditTest {
        PriceOracleV3 newPriceOracle = new PriceOracleV3(address(acl));

        vm.startPrank(CONFIGURATOR);

        vm.expectRevert(PriceFeedDoesNotExistException.selector);
        creditConfigurator.setPriceOracle(address(newPriceOracle));

        uint256 num = creditManager.collateralTokensCount();
        for (uint256 i; i < num; ++i) {
            address token = creditManager.getTokenByMask(1 << i);
            newPriceOracle.setPriceFeed(token, priceOracle.priceFeeds(token), 1);
        }

        vm.expectEmit(true, true, true, true);
        emit SetPriceOracle(address(newPriceOracle));

        creditConfigurator.setPriceOracle(address(newPriceOracle));

        assertEq(address(creditManager.priceOracle()), address(newPriceOracle));
        vm.stopPrank();
    }

    /// @dev I:[CC-22]: setCreditFacade upgrades creditFacade and correctly migrates parameters
    function test_I_CC_22_setCreditFacade_upgrades_creditFacade_and_migrates_params()
        public
        allExpirableCases
        creditTest
    {
        if (expirable) {
            CreditFacadeV3 initialCf =
                new CreditFacadeV3(address(acl), address(creditManager), address(botList), address(0), address(0), true);

            vm.prank(CONFIGURATOR);
            creditConfigurator.setCreditFacade(address(initialCf));

            vm.prank(CONFIGURATOR);
            creditConfigurator.setExpirationDate(uint40(block.timestamp + 2));

            creditFacade = initialCf;
        }

        vm.prank(CONFIGURATOR);
        creditConfigurator.setMaxCumulativeLoss(1e18);

        vm.prank(CONFIGURATOR);
        creditConfigurator.setMaxDebtPerBlockMultiplier(DEFAULT_LIMIT_PER_BLOCK_MULTIPLIER + 1);

        CreditFacadeV3 cf = new CreditFacadeV3(
            address(acl), address(creditManager), address(botList), address(0), address(0), expirable
        );

        uint8 maxDebtPerBlockMultiplier = creditFacade.maxDebtPerBlockMultiplier();

        uint40 expirationDate = creditFacade.expirationDate();
        (uint128 minDebt, uint128 maxDebt) = creditFacade.debtLimits();

        (, uint128 maxCumulativeLoss) = creditFacade.lossParams();

        vm.expectEmit(true, false, false, false);
        emit SetCreditFacade(address(cf));

        vm.prank(CONFIGURATOR);
        creditConfigurator.setCreditFacade(address(cf));

        assertEq(address(creditManager.creditFacade()), address(cf));
        assertEq(address(creditConfigurator.creditFacade()), address(cf));

        uint8 maxDebtPerBlockMultiplier2 = cf.maxDebtPerBlockMultiplier();

        uint40 expirationDate2 = cf.expirationDate();

        (uint128 minDebt2, uint128 maxDebt2) = cf.debtLimits();

        (, uint128 maxCumulativeLoss2) = cf.lossParams();

        assertEq(maxDebtPerBlockMultiplier2, maxDebtPerBlockMultiplier, "Incorrect limitPerBlock");
        assertEq(minDebt2, minDebt, "Incorrect minDebt");
        assertEq(maxDebt2, maxDebt, "Incorrect maxDebt");

        assertEq(expirationDate2, expirationDate, "Incorrect expirationDate");

        assertEq(maxCumulativeLoss2, maxCumulativeLoss, "Incorrect maxCumulativeLoss");
    }

    /// @dev I:[CC-22B]: setCreditFacade reverts if new facade is adapter or target contract
    function test_I_CC_22B_setCreditFacade_reverts_if_new_facade_is_adapter() public creditTest {
        vm.startPrank(CONFIGURATOR);

        CreditFacadeV3 cf =
            new CreditFacadeV3(address(acl), address(creditManager), address(botList), address(0), address(0), false);
        AdapterMock adapter = new AdapterMock(address(creditManager), address(cf));
        TargetContractMock target = new TargetContractMock();

        vm.mockCall(address(cf), abi.encodeCall(IAdapter.targetContract, ()), abi.encode(address(target)));
        creditConfigurator.allowAdapter(address(cf));

        vm.expectRevert(TargetContractNotAllowedException.selector);
        creditConfigurator.setCreditFacade(address(cf));

        creditConfigurator.forbidAdapter(address(cf));
        creditConfigurator.allowAdapter(address(adapter));

        vm.expectRevert(TargetContractNotAllowedException.selector);
        creditConfigurator.setCreditFacade(address(cf));

        vm.stopPrank();
    }

    /// @dev I:[CC-22C]: setCreditFacade correctly migrates array parameters
    function test_I_CC_22C_setCreditFacade_correctly_migrates_array_parameters() public creditTest {
        vm.startPrank(CONFIGURATOR);

        creditConfigurator.addEmergencyLiquidator(DUMB_ADDRESS);
        creditConfigurator.addEmergencyLiquidator(DUMB_ADDRESS2);

        address crvToken = tokenTestSuite.addressOf(Tokens.CRV);
        uint256 crvMask = creditManager.getTokenMaskOrRevert(crvToken);
        address cvxToken = tokenTestSuite.addressOf(Tokens.CVX);
        uint256 cvxMask = creditManager.getTokenMaskOrRevert(cvxToken);

        creditConfigurator.forbidToken(crvToken);
        creditConfigurator.forbidToken(cvxToken);

        vm.stopPrank();

        CreditFacadeV3 cf =
            new CreditFacadeV3(address(acl), address(creditManager), address(botList), address(0), address(0), false);

        vm.prank(CONFIGURATOR);
        creditConfigurator.setCreditFacade(address(cf));

        assertEq(cf.forbiddenTokenMask(), crvMask | cvxMask, "Incorrect forbidden mask migration");

        assertTrue(cf.canLiquidateWhilePaused(DUMB_ADDRESS), "Emergency liquidator 1 was not migrated correctly");

        assertTrue(cf.canLiquidateWhilePaused(DUMB_ADDRESS2), "Emergency liquidator 2 was not migrated correctly");
    }

    /// @dev I:[CC-22D]: `setCreditFacade` reverts when trying to change bot list
    function test_I_CC_22D_setCreditFacade_reverts_when_trying_to_change_botList() public creditTest {
        BotListV3 otherBotList = new BotListV3(address(this));
        otherBotList.addCreditManager(address(creditManager));

        CreditFacadeV3 newCreditFacade = new CreditFacadeV3(
            address(acl), address(creditManager), address(otherBotList), address(0), address(0), false
        );

        vm.expectRevert(IncorrectBotListException.selector);
        vm.prank(CONFIGURATOR);
        creditConfigurator.setCreditFacade(address(newCreditFacade));
    }

    /// @dev I:[CC-23]: uupgradeCreditConfigurator upgrades creditConfigurator
    function test_I_CC_23_upgradeCreditConfigurator_upgrades_creditConfigurator() public creditTest {
        TargetContractMock target1 = new TargetContractMock();
        TargetContractMock target2 = new TargetContractMock();
        AdapterMock adapter1 = new AdapterMock(address(creditManager), address(target1));
        AdapterMock adapter2 = new AdapterMock(address(creditManager), address(target2));

        vm.prank(CONFIGURATOR);
        creditConfigurator.allowAdapter(address(adapter1));

        CreditConfiguratorV3 cc1 = new CreditConfiguratorV3(address(acl), address(creditManager));

        vm.prank(CONFIGURATOR);
        creditConfigurator.allowAdapter(address(adapter2));

        CreditConfiguratorV3 cc2 = new CreditConfiguratorV3(address(acl), address(creditManager));

        vm.expectRevert(IncorrectAdaptersSetException.selector);
        vm.prank(CONFIGURATOR);
        creditConfigurator.upgradeCreditConfigurator(address(cc1));

        vm.expectEmit(true, true, true, true);
        emit CreditConfiguratorUpgraded(address(cc2));

        vm.prank(CONFIGURATOR);
        creditConfigurator.upgradeCreditConfigurator(address(cc2));

        assertEq(address(creditManager.creditConfigurator()), address(cc2));
    }

    /// @dev I:[CC-24]: setMaxDebtPerBlockMultiplier and forbidBorrowing work correctly
    function test_I_CC_24_setMaxDebtPerBlockMultiplier() public creditTest {
        vm.expectEmit(false, false, false, true);
        emit SetMaxDebtPerBlockMultiplier(3);

        vm.prank(CONFIGURATOR);
        creditConfigurator.setMaxDebtPerBlockMultiplier(3);

        assertEq(creditFacade.maxDebtPerBlockMultiplier(), 3, "Multiplier set incorrectly");

        vm.expectEmit(false, false, false, true);
        emit SetMaxDebtPerBlockMultiplier(0);

        vm.prank(CONFIGURATOR);
        creditConfigurator.forbidBorrowing();

        assertEq(creditFacade.maxDebtPerBlockMultiplier(), 0, "Multiplier set incorrectly");
    }

    /// @dev I:[CC-25]: setExpirationDate reverts if the new expiration date is stale, otherwise sets it
    function test_I_CC_25_setExpirationDate_reverts_on_incorrect_newExpirationDate_otherwise_sets()
        public
        expirableCase
        creditTest
    {
        uint40 expirationDate = creditFacade.expirationDate();

        vm.prank(CONFIGURATOR);
        vm.expectRevert(IncorrectExpirationDateException.selector);
        creditConfigurator.setExpirationDate(expirationDate);

        vm.warp(block.timestamp + 10);

        vm.prank(CONFIGURATOR);
        vm.expectRevert(IncorrectExpirationDateException.selector);
        creditConfigurator.setExpirationDate(expirationDate + 1);

        uint40 newExpirationDate = uint40(block.timestamp + 1);

        vm.expectEmit(false, false, false, true);
        emit SetExpirationDate(newExpirationDate);

        vm.prank(CONFIGURATOR);
        creditConfigurator.setExpirationDate(newExpirationDate);

        expirationDate = creditFacade.expirationDate();

        assertEq(expirationDate, newExpirationDate, "Incorrect new expirationDate");
    }

    /// @dev I:[CC-27]: addEmergencyLiquidator works correctly and emits event
    function test_I_CC_27_addEmergencyLiquidator_works_correctly() public creditTest {
        vm.expectEmit(false, false, false, true);
        emit AddEmergencyLiquidator(DUMB_ADDRESS);

        vm.prank(CONFIGURATOR);
        creditConfigurator.addEmergencyLiquidator(DUMB_ADDRESS);

        assertTrue(
            creditFacade.canLiquidateWhilePaused(DUMB_ADDRESS), "Credit manager emergency liquidator status incorrect"
        );

        address[] memory el = creditFacade.emergencyLiquidators();

        assertEq(el.length, 1, "Emergency liquidator was not added to array");

        assertEq(el[0], DUMB_ADDRESS, "Emergency liquidator address is incorrect");
    }

    /// @dev I:[CC-28]: removeEmergencyLiquidator works correctly and emits event
    function test_I_CC_28_removeEmergencyLiquidator_works_correctly() public creditTest {
        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditConfigurator.removeEmergencyLiquidator(DUMB_ADDRESS);

        vm.prank(CONFIGURATOR);
        creditConfigurator.addEmergencyLiquidator(DUMB_ADDRESS);

        vm.expectEmit(false, false, false, true);
        emit RemoveEmergencyLiquidator(DUMB_ADDRESS);

        vm.prank(CONFIGURATOR);
        creditConfigurator.removeEmergencyLiquidator(DUMB_ADDRESS);

        assertTrue(
            !creditFacade.canLiquidateWhilePaused(DUMB_ADDRESS), "Credit manager emergency liquidator status incorrect"
        );

        address[] memory el = creditFacade.emergencyLiquidators();

        assertEq(el.length, 0, "Emergency liquidator was not removed from array");
    }

    /// @dev I:[CC-29]: Array-based parameters are migrated correctly to new CC
    function test_I_CC_29_arrays_are_migrated_correctly_for_new_CC() public withAdapterMock creditTest {
        vm.prank(CONFIGURATOR);
        creditConfigurator.allowAdapter(address(adapterMock));

        CreditConfiguratorV3 newConfigurator = new CreditConfiguratorV3(address(acl), address(creditManager));

        address[] memory newAllowedAdapters = newConfigurator.allowedAdapters();

        assertEq(newAllowedAdapters.length, 1, "Incorrect new allowedAdapters array length");
        assertEq(newAllowedAdapters[0], address(adapterMock), "Incorrect new allowedAdapters array");
    }

    /// @dev I:[CC-30] rampLiquidationThreshold works correctly
    function test_I_CC_30_rampLiquidationThreshold_works_correctly() public creditTest {
        address dai = tokenTestSuite.addressOf(Tokens.DAI);
        address usdc = tokenTestSuite.addressOf(Tokens.USDC);

        vm.expectRevert(TokenNotAllowedException.selector);
        vm.prank(CONFIGURATOR);
        creditConfigurator.rampLiquidationThreshold(dai, 9000, uint40(block.timestamp), 1);

        vm.expectRevert(IncorrectLiquidationThresholdException.selector);
        vm.prank(CONFIGURATOR);
        creditConfigurator.rampLiquidationThreshold(usdc, 9999, uint40(block.timestamp), 1);

        uint16 initialLT = creditManager.liquidationThresholds(usdc);

        vm.expectCall(
            address(creditManager),
            abi.encodeCall(
                CreditManagerV3.setCollateralTokenData, (usdc, initialLT, 8900, uint40(block.timestamp + 1), 1000)
            )
        );

        vm.expectEmit(true, false, false, true);
        emit ScheduleTokenLiquidationThresholdRamp(
            usdc, initialLT, 8900, uint40(block.timestamp + 1), uint40(block.timestamp + 1001)
        );

        vm.prank(CONFIGURATOR);
        creditConfigurator.rampLiquidationThreshold(usdc, 8900, uint40(block.timestamp + 1), 1000);

        vm.warp(block.timestamp + 1006);

        vm.expectCall(
            address(creditManager),
            abi.encodeCall(CreditManagerV3.setCollateralTokenData, (usdc, 8900, 9000, uint40(block.timestamp), 1000))
        );

        vm.prank(CONFIGURATOR);
        creditConfigurator.rampLiquidationThreshold(usdc, 9000, uint40(block.timestamp - 1), 1000);
    }

    /// @dev I:[CC-31] setMaxCumulativeLoss works correctly
    function test_I_CC_31_setMaxCumulativeLoss_works_correctly() public creditTest {
        vm.expectEmit(false, false, false, true);
        emit SetMaxCumulativeLoss(100);

        vm.prank(CONFIGURATOR);
        creditConfigurator.setMaxCumulativeLoss(100);

        (, uint128 maxCumulativeLoss) = creditFacade.lossParams();

        assertEq(maxCumulativeLoss, 100, "Max cumulative loss set incorrectly");
    }

    /// @dev I:[CC-32] resetCumulativeLoss works correctly
    function test_I_CC_32_resetCumulativeLoss_works_correctly() public creditTest {
        CreditFacadeV3Harness cf = new CreditFacadeV3Harness(
            address(acl), address(creditManager), address(botList), address(0), address(0), false
        );

        vm.prank(CONFIGURATOR);
        creditConfigurator.setCreditFacade(address(cf));

        cf.setCumulativeLoss(1000);

        vm.expectEmit(false, false, false, false);
        emit ResetCumulativeLoss();

        vm.prank(CONFIGURATOR);
        creditConfigurator.resetCumulativeLoss();

        (uint256 loss,) = cf.lossParams();

        assertEq(loss, 0, "Cumulative loss was not reset");
    }
}
