// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import "../../../interfaces/IAddressProviderV3.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {CreditFacadeV3} from "../../../credit/CreditFacadeV3.sol";
import {CreditManagerV3} from "../../../credit/CreditManagerV3.sol";

import {
    CreditConfiguratorV3,
    CreditManagerOpts,
    AllowanceAction,
    IVersion
} from "../../../credit/CreditConfiguratorV3.sol";
import {ICreditManagerV3} from "../../../interfaces/ICreditManagerV3.sol";
import {ICreditConfiguratorV3Events} from "../../../interfaces/ICreditConfiguratorV3.sol";
import {IAdapter} from "@gearbox-protocol/core-v2/contracts/interfaces/IAdapter.sol";

//
import "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";
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

import {MockCreditConfig, CollateralTokenHuman} from "../../config/MockCreditConfig.sol";

import "forge-std/console.sol";

contract CreditConfiguratorIntegrationTest is IntegrationTestHelper, ICreditConfiguratorV3Events {
    using AddressList for address[];

    // function setUp() public creditTest {
    //     _setUp(false, false, false);
    // }

    // function _setUp(bool withDegenNFT, bool expirable, bool supportQuotas) public creditTest {
    //     tokenTestSuite = new TokensTestSuite();
    //     tokenTestSuite.topUpWETH{value: 100 * WAD}();

    //     MockCreditConfig creditConfig = new MockCreditConfig(
    //         tokenTestSuite,
    //         Tokens.DAI
    //     );

    //     // cct = new CreditFacadeTestSuite(creditConfig,  withDegenNFT,  expirable,  supportQuotas, 1);

    //     // underlying = cct.underlying();
    //     // creditManager = cct.creditManager();
    //     // creditFacade = cct.creditFacade();
    //     // creditConfigurator = cct.creditConfigurator();
    //     // withdrawalManager = cct.withdrawalManager();

    //     address(targetMock) = address(new TargetContractMock());

    //     adapterMock = new AdapterMock(address(creditManager), address(targetMock));

    //     // adapterDifferentCM = new AdapterMock(
    //     //     address(new CreditFacadeTestSuite(creditConfig, withDegenNFT,  expirable,  supportQuotas,1).creditManager()), address(targetMock)
    //     // );

    //     address(adapterMock) = address(adapterMock);
    // }

    function getAdapterDifferentCM() internal returns (AdapterMock) {
        address CM = makeAddr("Different CM");

        vm.mockCall(CM, abi.encodeCall(IAdapter.creditManager, ()), abi.encode(CM));
        vm.mockCall(CM, abi.encodeCall(ICreditManagerV3.addressProvider, ()), abi.encode((address(addressProvider))));

        address TARGET_CONTRACT = makeAddr("Target Contract");

        return new AdapterMock(CM, TARGET_CONTRACT);
    }

    //
    // HELPERS
    //
    function _compareParams(
        uint16 feeInterest,
        uint16 feeLiquidation,
        uint16 liquidationDiscount,
        uint16 feeLiquidationExpired,
        uint16 liquidationDiscountExpired
    ) internal {
        (
            uint16 feeInterest2,
            uint16 feeLiquidation2,
            uint16 liquidationDiscount2,
            uint16 feeLiquidationExpired2,
            uint16 liquidationDiscountExpired2
        ) = creditManager.fees();

        assertEq(feeInterest2, feeInterest, "Incorrect feeInterest");
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

        assertEq(address(creditConfigurator.addressProvider()), address(addressProvider), "Incorrect addressProvider");

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

        assertEq(address(creditConfigurator.addressProvider()), address(addressProvider), "Incorrect address provider");

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

    /// @dev I:[CC-1A]: constructor emits all events
    function test_I_CC_01A_constructor_emits_all_events() public creditTest {
        CreditManagerOpts memory creditOpts = CreditManagerOpts({
            minDebt: uint128(50 * WAD),
            maxDebt: uint128(150000 * WAD),
            degenNFT: address(0),
            expirable: false,
            name: "Test Credit Manager"
        });

        creditManager = new CreditManagerV3(address(addressProvider), address(pool), "Test Credit Manager");
        creditFacade = new CreditFacadeV3(address(creditManager), creditOpts.degenNFT, creditOpts.expirable);

        address priceOracleAddress = address(creditManager.priceOracle());
        address usdcToken = tokenTestSuite.addressOf(Tokens.USDC);

        bytes memory configuratorByteCode = abi.encodePacked(
            type(CreditConfiguratorV3).creationCode, abi.encode(creditManager, creditFacade, creditOpts)
        );

        address creditConfiguratorAddr = _getAddress(configuratorByteCode, 0);

        creditManager.setCreditConfigurator(creditConfiguratorAddr);

        vm.expectEmit(true, false, false, true);
        emit SetTokenLiquidationThreshold(underlying, DEFAULT_UNDERLYING_LT);

        vm.expectEmit(false, false, false, false);
        emit UpdateFees(
            DEFAULT_FEE_INTEREST,
            DEFAULT_FEE_LIQUIDATION,
            DEFAULT_LIQUIDATION_PREMIUM,
            DEFAULT_FEE_LIQUIDATION_EXPIRED,
            DEFAULT_LIQUIDATION_PREMIUM_EXPIRED
        );

        vm.expectEmit(true, false, false, false);
        emit SetCreditFacade(address(creditFacade));

        vm.expectEmit(true, false, false, false);
        emit SetPriceOracle(priceOracleAddress);

        /// todo: change
        // vm.expectEmit(false, false, false, true);
        // emit SetMaxDebtPerBlockMultiplier(uint128(150000 * WAD * DEFAULT_LIMIT_PER_BLOCK_MULTIPLIER));

        vm.expectEmit(false, false, false, true);
        emit SetBorrowingLimits(uint128(50 * WAD), uint128(150000 * WAD));

        _deploy(configuratorByteCode, 0);
    }

    /// @dev I:[CC-2]: configuratorOnly functions revert on non-configurator
    function test_I_CC_02_configuratorOnly_functions_revert_on_non_configurator() public creditTest {
        vm.startPrank(USER);

        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditConfigurator.addCollateralToken(DUMB_ADDRESS, 1);

        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditConfigurator.setLiquidationThreshold(DUMB_ADDRESS, uint16(0));

        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditConfigurator.allowToken(DUMB_ADDRESS);

        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditConfigurator.allowAdapter(DUMB_ADDRESS);

        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditConfigurator.setFees(0, 0, 0, 0, 0);

        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditConfigurator.setPriceOracle(0);

        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditConfigurator.setCreditFacade(DUMB_ADDRESS, false);

        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditConfigurator.upgradeCreditConfigurator(DUMB_ADDRESS);

        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditConfigurator.setBotList(0);

        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditConfigurator.setMaxEnabledTokens(1);

        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditConfigurator.setMaxCumulativeLoss(0);

        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditConfigurator.resetCumulativeLoss();

        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditConfigurator.addEmergencyLiquidator(address(0));

        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditConfigurator.removeEmergencyLiquidator(address(0));

        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditConfigurator.makeTokenQuoted(address(0));

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
        creditConfigurator.rampLiquidationThreshold(DUMB_ADDRESS, 0, 0, 0);

        vm.expectRevert(CallerNotControllerException.selector);
        creditConfigurator.setMinDebtLimit(0);

        vm.expectRevert(CallerNotControllerException.selector);
        creditConfigurator.setMaxDebtLimit(0);

        vm.expectRevert(CallerNotControllerException.selector);
        creditConfigurator.setMaxDebtPerBlockMultiplier(0);

        vm.expectRevert(CallerNotControllerException.selector);
        creditConfigurator.setExpirationDate(0);

        vm.expectRevert(CallerNotControllerException.selector);
        creditConfigurator.forbidAdapter(DUMB_ADDRESS);
    }

    //
    // TOKEN MANAGEMENT
    //

    /// @dev I:[CC-3]: addCollateralToken reverts for zero address or in priceFeed
    function test_I_CC_03_addCollateralToken_reverts_for_zero_address_or_in_priceFeed() public creditTest {
        vm.startPrank(CONFIGURATOR);

        vm.expectRevert(ZeroAddressException.selector);
        creditConfigurator.addCollateralToken(address(0), 9300);

        vm.expectRevert(abi.encodeWithSelector(AddressIsNotContractException.selector, DUMB_ADDRESS));
        creditConfigurator.addCollateralToken(DUMB_ADDRESS, 9300);

        vm.expectRevert(IncorrectTokenContractException.selector);
        creditConfigurator.addCollateralToken(address(this), 9300);

        address unknownPricefeedToken = address(new ERC20("TWPF", "Token without priceFeed"));

        vm.expectRevert(PriceFeedDoesNotExistException.selector);
        creditConfigurator.addCollateralToken(unknownPricefeedToken, 9300);

        vm.stopPrank();
    }

    /// @dev I:[CC-4]: addCollateralToken adds new token to creditManager
    function test_I_CC_04_addCollateralToken_adds_new_token_to_creditManager_and_set_lt() public creditTest {
        uint256 tokensCountBefore = creditManager.collateralTokensCount();

        address newToken = tokenTestSuite.addressOf(Tokens.wstETH);

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
        creditConfigurator.setFees(PERCENTAGE_FACTOR, feeLiquidation, 0, 0, 0);

        vm.expectRevert(IncorrectParameterException.selector);

        vm.prank(CONFIGURATOR);
        creditConfigurator.setFees(PERCENTAGE_FACTOR - 1, feeLiquidation, PERCENTAGE_FACTOR - feeLiquidation, 0, 0);

        vm.expectRevert(IncorrectParameterException.selector);

        vm.prank(CONFIGURATOR);
        creditConfigurator.setFees(
            PERCENTAGE_FACTOR - 1,
            feeLiquidation,
            PERCENTAGE_FACTOR - feeLiquidation - 1,
            feeLiquidationExpired,
            PERCENTAGE_FACTOR - feeLiquidationExpired
        );
    }

    /// @dev I:[CC-18]: setFees updates LT for underlying and for all tokens which have LTs larger than new LT
    function test_I_CC_18_setFees_updates_LT_for_underlying_and_align_LTs_for_other_tokens() public creditTest {
        vm.startPrank(CONFIGURATOR);

        (uint16 feeInterest,,,,) = creditManager.fees();

        address usdcToken = tokenTestSuite.addressOf(Tokens.USDC);
        address wethToken = tokenTestSuite.addressOf(Tokens.WETH);
        creditConfigurator.setLiquidationThreshold(usdcToken, creditManager.liquidationThresholds(underlying));

        uint256 expectedLT = PERCENTAGE_FACTOR - DEFAULT_LIQUIDATION_PREMIUM - 2 * DEFAULT_FEE_LIQUIDATION;

        uint256 wethLTBefore = creditManager.liquidationThresholds(wethToken);

        vm.expectEmit(true, false, false, true);
        emit SetTokenLiquidationThreshold(usdcToken, uint16(expectedLT));

        vm.expectEmit(true, false, false, true);
        emit SetTokenLiquidationThreshold(underlying, uint16(expectedLT));

        creditConfigurator.setFees(
            feeInterest,
            2 * DEFAULT_FEE_LIQUIDATION,
            DEFAULT_LIQUIDATION_PREMIUM,
            DEFAULT_FEE_LIQUIDATION_EXPIRED,
            DEFAULT_LIQUIDATION_PREMIUM_EXPIRED
        );

        assertEq(creditManager.liquidationThresholds(underlying), expectedLT, "Incorrect LT for underlying token");

        assertEq(creditManager.liquidationThresholds(usdcToken), expectedLT, "Incorrect USDC for underlying token");

        assertEq(creditManager.liquidationThresholds(wethToken), wethLTBefore, "Incorrect WETH for underlying token");
    }

    /// @dev I:[CC-19]: setFees sets fees and doesn't change others
    function test_I_CC_19_setFees_sets_fees_and_doesnt_change_others() public creditTest {
        (
            uint16 feeInterest,
            uint16 feeLiquidation,
            uint16 liquidationDiscount,
            uint16 feeLiquidationExpired,
            uint16 liquidationDiscountExpired
        ) = creditManager.fees();

        uint16 newFeeInterest = (feeInterest * 3) / 2;
        uint16 newFeeLiquidation = feeLiquidation * 2;
        uint16 newLiquidationPremium = (PERCENTAGE_FACTOR - liquidationDiscount) * 2;
        uint16 newFeeLiquidationExpired = feeLiquidationExpired * 2;
        uint16 newLiquidationPremiumExpired = (PERCENTAGE_FACTOR - liquidationDiscountExpired) * 2;

        vm.expectEmit(false, false, false, true);
        emit UpdateFees(
            newFeeInterest,
            newFeeLiquidation,
            newLiquidationPremium,
            newFeeLiquidationExpired,
            newLiquidationPremiumExpired
        );

        vm.prank(CONFIGURATOR);
        creditConfigurator.setFees(
            newFeeInterest,
            newFeeLiquidation,
            newLiquidationPremium,
            newFeeLiquidationExpired,
            newLiquidationPremiumExpired
        );

        _compareParams(
            newFeeInterest,
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
        creditConfigurator.setCreditFacade(address(0), false);

        vm.expectRevert(ZeroAddressException.selector);
        creditConfigurator.upgradeCreditConfigurator(address(0));

        vm.expectRevert(abi.encodeWithSelector(AddressIsNotContractException.selector, DUMB_ADDRESS));
        creditConfigurator.setCreditFacade(DUMB_ADDRESS, false);

        vm.expectRevert(abi.encodeWithSelector(AddressIsNotContractException.selector, DUMB_ADDRESS));
        creditConfigurator.upgradeCreditConfigurator(DUMB_ADDRESS);

        vm.expectRevert(IncompatibleContractException.selector);
        creditConfigurator.setCreditFacade(underlying, false);

        vm.expectRevert(IncompatibleContractException.selector);
        creditConfigurator.upgradeCreditConfigurator(underlying);

        AdapterMock adapterDifferentCM = getAdapterDifferentCM();

        vm.expectRevert(IncompatibleContractException.selector);
        creditConfigurator.setCreditFacade(address(adapterDifferentCM), false);

        vm.expectRevert(IncompatibleContractException.selector);
        creditConfigurator.upgradeCreditConfigurator(address(adapterDifferentCM));
    }

    /// @dev I:[CC-21]: setPriceOracle upgrades priceOracle correctly
    function test_I_CC_21_setPriceOracle_upgrades_priceOracle_correctly() public creditTest {
        vm.mockCall(DUMB_ADDRESS, abi.encodeCall(IVersion.version, ()), abi.encode(1));

        vm.startPrank(CONFIGURATOR);
        addressProvider.setAddress(AP_PRICE_ORACLE, DUMB_ADDRESS, true);

        vm.expectEmit(true, false, false, false);
        emit SetPriceOracle(DUMB_ADDRESS);

        creditConfigurator.setPriceOracle(1);

        assertEq(address(creditManager.priceOracle()), DUMB_ADDRESS);
        vm.stopPrank();
    }

    /// @dev I:[CC-22]: setCreditFacade upgrades creditFacade and correctly migrates parameters
    function test_I_CC_22_setCreditFacade_upgrades_creditFacade_and_migrates_params()
        public
        allExpirableCases
        creditTest
    {
        for (uint256 ms = 0; ms < 2; ms++) {
            uint256 snapshot = vm.snapshot();

            bool migrateSettings = ms != 0;

            if (expirable) {
                CreditFacadeV3 initialCf = new CreditFacadeV3(address(creditManager), address(0), true);

                vm.prank(CONFIGURATOR);
                creditConfigurator.setCreditFacade(address(initialCf), migrateSettings);

                vm.prank(CONFIGURATOR);
                creditConfigurator.setExpirationDate(uint40(block.timestamp + 1 + ms));

                creditFacade = initialCf;
            }

            vm.prank(CONFIGURATOR);
            creditConfigurator.setMaxCumulativeLoss(1e18);

            CreditFacadeV3 cf = new CreditFacadeV3(address(creditManager), address(0), expirable);

            uint8 maxDebtPerBlockMultiplier = creditFacade.maxDebtPerBlockMultiplier();

            uint40 expirationDate = creditFacade.expirationDate();
            (uint128 minDebt, uint128 maxDebt) = creditFacade.debtLimits();

            (, uint128 maxCumulativeLoss) = creditFacade.lossParams();

            vm.expectEmit(true, false, false, false);
            emit SetCreditFacade(address(cf));

            vm.prank(CONFIGURATOR);
            creditConfigurator.setCreditFacade(address(cf), migrateSettings);

            assertEq(address(creditManager.priceOracle()), addressProvider.getAddressOrRevert(AP_PRICE_ORACLE, 3_00));

            assertEq(address(creditManager.creditFacade()), address(cf));
            assertEq(address(creditConfigurator.creditFacade()), address(cf));

            uint8 maxDebtPerBlockMultiplier2 = cf.maxDebtPerBlockMultiplier();

            uint40 expirationDate2 = cf.expirationDate();

            (uint128 minDebt2, uint128 maxDebt2) = cf.debtLimits();

            (, uint128 maxCumulativeLoss2) = cf.lossParams();

            assertEq(
                maxDebtPerBlockMultiplier2, migrateSettings ? maxDebtPerBlockMultiplier : 0, "Incorrwect limitPerBlock"
            );
            assertEq(minDebt2, migrateSettings ? minDebt : 0, "Incorrwect minDebt");
            assertEq(maxDebt2, migrateSettings ? maxDebt : 0, "Incorrwect maxDebt");

            assertEq(expirationDate2, migrateSettings ? expirationDate : 0, "Incorrect expirationDate");

            assertEq(maxCumulativeLoss2, migrateSettings ? maxCumulativeLoss : 0, "Incorrect maxCumulativeLoss");

            vm.revertTo(snapshot);
        }
    }

    /// @dev I:[CC-22A]: setCreditFacade migrates bot list
    function test_I_CC_22A_botList_is_transferred_on_CreditFacade_upgrade() public creditTest {
        for (uint256 ms = 0; ms < 2; ms++) {
            uint256 snapshot = vm.snapshot();

            bool migrateSettings = ms != 0;

            vm.mockCall(DUMB_ADDRESS, abi.encodeCall(IVersion.version, ()), abi.encode(301));

            vm.startPrank(CONFIGURATOR);
            addressProvider.setAddress(AP_BOT_LIST, DUMB_ADDRESS, true);
            creditConfigurator.setBotList(301);
            vm.stopPrank();

            address botList = creditFacade.botList();

            CreditFacadeV3 cf = new CreditFacadeV3(address(creditManager), address(0), false);

            vm.prank(CONFIGURATOR);
            creditConfigurator.setCreditFacade(address(cf), migrateSettings);

            address botList2 = cf.botList();

            assertEq(
                botList2,
                migrateSettings ? botList : addressProvider.getAddressOrRevert(AP_BOT_LIST, 300),
                "Bot list was not transferred"
            );

            vm.revertTo(snapshot);
        }
    }

    /// @dev I:[CC-22C]: setCreditFacade correctly migrates array parameters
    function test_I_CC_22C_setCreditFacade_correctly_migrates_array_parameters() public creditTest {
        for (uint256 ms = 0; ms < 2; ms++) {
            uint256 snapshot = vm.snapshot();

            bool migrateSettings = ms != 0;

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

            CreditFacadeV3 cf = new CreditFacadeV3(address(creditManager), address(0), false);

            vm.prank(CONFIGURATOR);
            creditConfigurator.setCreditFacade(address(cf), migrateSettings);

            assertEq(
                cf.forbiddenTokenMask(), migrateSettings ? crvMask | cvxMask : 0, "Incorrect forbidden mask migration"
            );

            assertEq(
                cf.canLiquidateWhilePaused(DUMB_ADDRESS),
                migrateSettings,
                "Emergency liquidator 1 was not migrated correctly"
            );

            assertEq(
                cf.canLiquidateWhilePaused(DUMB_ADDRESS2),
                migrateSettings,
                "Emergency liquidator 2 was not migrated correctly"
            );

            if (!migrateSettings) {
                address[] memory el = creditConfigurator.emergencyLiquidators();

                assertEq(el.length, 0, "Emergency liquidator array was not deleted");

                assertEq(cf.forbiddenTokenMask(), 0, "Incorrect forbidden token mask");
            }

            vm.revertTo(snapshot);
        }
    }

    /// @dev I:[CC-23]: uupgradeCreditConfigurator upgrades creditConfigurator
    function test_I_CC_23_upgradeCreditConfigurator_upgrades_creditConfigurator() public withAdapterMock creditTest {
        vm.expectEmit(true, false, false, false);
        emit CreditConfiguratorUpgraded(address(adapterMock));

        vm.prank(CONFIGURATOR);
        creditConfigurator.upgradeCreditConfigurator(address(adapterMock));

        assertEq(address(creditManager.creditConfigurator()), address(adapterMock));
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

    /// @dev I:[CC-26]: setMaxEnabledTokens works correctly and emits event
    function test_I_CC_26_setMaxEnabledTokens_works_correctly() public creditTest {
        vm.expectEmit(false, false, false, true);
        emit SetMaxEnabledTokens(255);

        vm.prank(CONFIGURATOR);
        creditConfigurator.setMaxEnabledTokens(255);

        assertEq(creditManager.maxEnabledTokens(), 255, "Credit manager max enabled tokens incorrect");

        vm.expectRevert(IncorrectParameterException.selector);
        vm.prank(CONFIGURATOR);
        creditConfigurator.setMaxEnabledTokens(0);
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

        address[] memory el = creditConfigurator.emergencyLiquidators();

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

        address[] memory el = creditConfigurator.emergencyLiquidators();

        assertEq(el.length, 0, "Emergency liquidator was not removed from array");
    }

    /// @dev I:[CC-29]: Array-based parameters are migrated correctly to new CC
    function test_I_CC_29_arrays_are_migrated_correctly_for_new_CC() public withAdapterMock creditTest {
        vm.startPrank(CONFIGURATOR);
        creditConfigurator.allowAdapter(address(adapterMock));
        creditConfigurator.addEmergencyLiquidator(DUMB_ADDRESS);
        creditConfigurator.addEmergencyLiquidator(DUMB_ADDRESS2);
        vm.stopPrank();

        CreditManagerOpts memory creditOpts = CreditManagerOpts({
            minDebt: uint128(50 * WAD),
            maxDebt: uint128(150000 * WAD),
            degenNFT: address(0),
            expirable: false,
            name: "Test Credit Manager"
        });

        CreditConfiguratorV3 newCC = new CreditConfiguratorV3(creditManager, creditFacade, creditOpts);

        assertEq(
            creditConfigurator.allowedAdapters().length,
            newCC.allowedAdapters().length,
            "Incorrect new allowed contracts array"
        );

        assertEq(
            creditConfigurator.emergencyLiquidators().length,
            newCC.emergencyLiquidators().length,
            "Incorrect new emergency liquidators array"
        );

        uint256 len = newCC.allowedAdapters().length;

        for (uint256 i = 0; i < len;) {
            assertEq(
                creditConfigurator.allowedAdapters()[i],
                newCC.allowedAdapters()[i],
                "Allowed contracts migrated incorrectly"
            );

            unchecked {
                ++i;
            }
        }

        len = newCC.emergencyLiquidators().length;

        for (uint256 i = 0; i < len;) {
            assertEq(
                creditConfigurator.emergencyLiquidators()[i],
                newCC.emergencyLiquidators()[i],
                "Emergency liquidators migrated incorrectly"
            );

            unchecked {
                ++i;
            }
        }
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
        CreditFacadeV3Harness cf = new CreditFacadeV3Harness(address(creditManager), address(0), false);

        vm.prank(CONFIGURATOR);
        creditConfigurator.setCreditFacade(address(cf), true);

        cf.setCumulativeLoss(1000);

        vm.expectEmit(false, false, false, false);
        emit ResetCumulativeLoss();

        vm.prank(CONFIGURATOR);
        creditConfigurator.resetCumulativeLoss();

        (uint256 loss,) = cf.lossParams();

        assertEq(loss, 0, "Cumulative loss was not reset");
    }

    /// @dev I:[CC-33]: setBotList upgrades the bot list correctly
    function test_I_CC_33_setBotList_upgrades_priceOracle_correctly() public creditTest {
        vm.mockCall(DUMB_ADDRESS, abi.encodeCall(IVersion.version, ()), abi.encode(301));

        vm.startPrank(CONFIGURATOR);
        addressProvider.setAddress(AP_BOT_LIST, DUMB_ADDRESS, true);

        vm.expectEmit(true, false, false, false);
        emit SetBotList(DUMB_ADDRESS);

        creditConfigurator.setBotList(301);

        assertEq(creditFacade.botList(), DUMB_ADDRESS);
        vm.stopPrank();
    }
}
