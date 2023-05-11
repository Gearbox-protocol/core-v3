// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.10;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {CreditFacadeV3} from "../../../credit/CreditFacadeV3.sol";
import {CreditManagerV3} from "../../../credit/CreditManagerV3.sol";
import {WithdrawalManager} from "../../../support/WithdrawalManager.sol";
import {CreditConfigurator, CreditManagerOpts, CollateralToken} from "../../../credit/CreditConfiguratorV3.sol";
import {ICreditManagerV3, ICreditManagerV3Events} from "../../../interfaces/ICreditManagerV3.sol";
import {ICreditConfiguratorEvents} from "../../../interfaces/ICreditConfiguratorV3.sol";
import {IAdapter} from "@gearbox-protocol/core-v2/contracts/interfaces/adapters/IAdapter.sol";

import {BotList} from "../../../support/BotList.sol";

//
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/PercentageMath.sol";
import "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";
import {AddressList} from "@gearbox-protocol/core-v2/contracts/libraries/AddressList.sol";

// EXCEPTIONS

import "../../../interfaces/IExceptions.sol";

// TEST
import "../../lib/constants.sol";

// MOCKS
import {AdapterMock} from "../../mocks/adapters/AdapterMock.sol";
import {TargetContractMock} from "@gearbox-protocol/core-v2/contracts/test/mocks/adapters/TargetContractMock.sol";

// SUITES
import {TokensTestSuite} from "../../suites/TokensTestSuite.sol";
import {Tokens} from "../../config/Tokens.sol";
import {CreditFacadeTestSuite} from "../../suites/CreditFacadeTestSuite.sol";
import {CreditConfig} from "../../config/CreditConfig.sol";

import {CollateralTokensItem} from "../../config/CreditConfig.sol";

import {Test} from "forge-std/Test.sol";

/// @title CreditConfiguratorTest
/// @notice Designed for unit test purposes only
contract CreditConfiguratorTest is Test, ICreditManagerV3Events, ICreditConfiguratorEvents {
    using AddressList for address[];

    TokensTestSuite tokenTestSuite;
    CreditFacadeTestSuite cct;

    CreditManagerV3 public creditManager;
    CreditFacadeV3 public creditFacade;
    CreditConfigurator public creditConfigurator;
    WithdrawalManager public withdrawalManager;
    address underlying;

    AdapterMock adapter1;
    AdapterMock adapterDifferentCM;

    address DUMB_COMPARTIBLE_CONTRACT;
    address TARGET_CONTRACT;

    function setUp() public {
        _setUp(false, false, false);
    }

    function _setUp(bool withDegenNFT, bool expirable, bool supportQuotas) public {
        tokenTestSuite = new TokensTestSuite();
        tokenTestSuite.topUpWETH{value: 100 * WAD}();

        CreditConfig creditConfig = new CreditConfig(
            tokenTestSuite,
            Tokens.DAI
        );

        cct = new CreditFacadeTestSuite(creditConfig,  withDegenNFT,  expirable,  supportQuotas, 1);

        underlying = cct.underlying();
        creditManager = cct.creditManager();
        creditFacade = cct.creditFacade();
        creditConfigurator = cct.creditConfigurator();
        withdrawalManager = cct.withdrawalManager();

        TARGET_CONTRACT = address(new TargetContractMock());

        adapter1 = new AdapterMock(address(creditManager), TARGET_CONTRACT);

        adapterDifferentCM = new AdapterMock(
            address(new CreditFacadeTestSuite(creditConfig, withDegenNFT,  expirable,  supportQuotas,1).creditManager()), TARGET_CONTRACT
        );

        DUMB_COMPARTIBLE_CONTRACT = address(adapter1);
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

    /// @dev [CC-1]: constructor sets correct values
    function test_CC_01_constructor_sets_correct_values() public {
        assertEq(address(creditConfigurator.creditManager()), address(creditManager), "Incorrect creditManager");

        assertEq(address(creditConfigurator.creditFacade()), address(creditFacade), "Incorrect creditFacade");

        assertEq(address(creditConfigurator.underlying()), address(creditManager.underlying()), "Incorrect underlying");

        assertEq(
            address(creditConfigurator.addressProvider()), address(cct.addressProvider()), "Incorrect addressProvider"
        );

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

        assertEq(
            address(creditConfigurator.addressProvider()), address(cct.addressProvider()), "Incorrect address provider"
        );

        CollateralTokensItem[8] memory collateralTokenOpts = [
            CollateralTokensItem({token: Tokens.DAI, liquidationThreshold: DEFAULT_UNDERLYING_LT}),
            CollateralTokensItem({token: Tokens.USDC, liquidationThreshold: 9000}),
            CollateralTokensItem({token: Tokens.USDT, liquidationThreshold: 8800}),
            CollateralTokensItem({token: Tokens.WETH, liquidationThreshold: 8300}),
            CollateralTokensItem({token: Tokens.LINK, liquidationThreshold: 7300}),
            CollateralTokensItem({token: Tokens.CRV, liquidationThreshold: 7300}),
            CollateralTokensItem({token: Tokens.CVX, liquidationThreshold: 7300}),
            CollateralTokensItem({token: Tokens.STETH, liquidationThreshold: 7300})
        ];

        uint256 len = collateralTokenOpts.length;

        // Allowed Tokens
        assertEq(creditManager.collateralTokensCount(), len, "Incorrect quantity of allowed tokens");

        for (uint256 i = 0; i < len; i++) {
            (address token, uint16 lt) = creditManager.collateralTokens(i);

            assertEq(token, tokenTestSuite.addressOf(collateralTokenOpts[i].token), "Incorrect token address");

            assertEq(lt, collateralTokenOpts[i].liquidationThreshold, "Incorrect liquidation threshold");
        }

        assertEq(address(creditManager.creditFacade()), address(creditFacade), "Incorrect creditFacade");

        assertEq(address(creditManager.priceOracle()), address(cct.priceOracle()), "Incorrect creditFacade");

        // CREDIT FACADE PARAMS
        (uint128 minBorrowedAmount, uint128 maxBorrowedAmount) = creditFacade.debtLimits();

        assertEq(minBorrowedAmount, cct.minBorrowedAmount(), "Incorrect minBorrowedAmount");

        assertEq(maxBorrowedAmount, cct.maxBorrowedAmount(), "Incorrect maxBorrowedAmount");

        uint8 maxBorrowedAmountPerBlock = creditFacade.maxDebtPerBlockMultiplier();

        uint40 expirationDate = creditFacade.expirationDate();

        assertEq(maxBorrowedAmountPerBlock, DEFAULT_LIMIT_PER_BLOCK_MULTIPLIER, "Incorrect  maxBorrowedAmountPerBlock");

        assertEq(expirationDate, 0, "Incorrect expiration date");
    }

    /// @dev [CC-1A]: constructor emits all events
    function test_CC_01A_constructor_emits_all_events() public {
        CollateralToken[] memory cTokens = new CollateralToken[](1);

        cTokens[0] = CollateralToken({token: tokenTestSuite.addressOf(Tokens.USDC), liquidationThreshold: 6000});

        CreditManagerOpts memory creditOpts = CreditManagerOpts({
            minBorrowedAmount: uint128(50 * WAD),
            maxBorrowedAmount: uint128(150000 * WAD),
            collateralTokens: cTokens,
            degenNFT: address(0),
            withdrawalManager: address(0),
            expirable: false
        });

        creditManager = new CreditManagerV3(address(cct.poolMock()), address(withdrawalManager));
        creditFacade = new CreditFacadeV3(
            address(creditManager),
            creditOpts.degenNFT,

            creditOpts.expirable
        );

        address priceOracleAddress = address(creditManager.priceOracle());
        address usdcToken = tokenTestSuite.addressOf(Tokens.USDC);

        bytes memory configuratorByteCode =
            abi.encodePacked(type(CreditConfigurator).creationCode, abi.encode(creditManager, creditFacade, creditOpts));

        address creditConfiguratorAddr = _getAddress(configuratorByteCode, 0);

        creditManager.setCreditConfigurator(creditConfiguratorAddr);

        vm.expectEmit(true, false, false, true);
        emit SetTokenLiquidationThreshold(underlying, DEFAULT_UNDERLYING_LT);

        vm.expectEmit(false, false, false, false);
        emit FeesUpdated(
            DEFAULT_FEE_INTEREST,
            DEFAULT_FEE_LIQUIDATION,
            DEFAULT_LIQUIDATION_PREMIUM,
            DEFAULT_FEE_LIQUIDATION_EXPIRED,
            DEFAULT_LIQUIDATION_PREMIUM_EXPIRED
        );

        vm.expectEmit(true, false, false, false);
        emit AllowToken(usdcToken);

        vm.expectEmit(true, false, false, true);
        emit SetTokenLiquidationThreshold(usdcToken, 6000);

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

    /// @dev [CC-2]: all functions revert if called non-configurator
    function test_CC_02_all_functions_revert_if_called_non_configurator() public {
        vm.startPrank(USER);

        // Token mgmt

        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditConfigurator.addCollateralToken(DUMB_ADDRESS, 1);

        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditConfigurator.allowToken(DUMB_ADDRESS);

        // Contract mgmt

        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditConfigurator.allowContract(DUMB_ADDRESS, DUMB_ADDRESS);

        // Credit manager mgmt

        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditConfigurator.setFees(0, 0, 0, 0, 0);

        // Upgrades
        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditConfigurator.setPriceOracle();

        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditConfigurator.setCreditFacade(DUMB_ADDRESS, false);

        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditConfigurator.upgradeCreditConfigurator(DUMB_ADDRESS);

        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditConfigurator.setBotList(FRIEND);

        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditConfigurator.setMaxCumulativeLoss(0);

        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditConfigurator.resetCumulativeLoss();

        vm.stopPrank();
    }

    function test_CC_02A_forbidBorrowing_on_non_pausable_admin() public {
        vm.expectRevert(CallerNotPausableAdminException.selector);
        creditConfigurator.forbidBorrowing();

        vm.prank(CONFIGURATOR);
        creditConfigurator.forbidBorrowing();
    }

    function test_CC_02B_controllerOnly_functions_revert_on_non_controller() public {
        vm.expectRevert(CallerNotControllerException.selector);
        creditConfigurator.setLiquidationThreshold(DUMB_ADDRESS, uint16(0));

        vm.expectRevert(CallerNotPausableAdminException.selector);
        creditConfigurator.forbidToken(DUMB_ADDRESS);

        vm.expectRevert(CallerNotControllerException.selector);
        creditConfigurator.forbidContract(DUMB_ADDRESS);

        vm.expectRevert(CallerNotControllerException.selector);
        creditConfigurator.setLimits(0, 0);

        vm.expectRevert(CallerNotControllerException.selector);
        creditConfigurator.setMaxDebtPerBlockMultiplier(0);

        vm.expectRevert(CallerNotControllerException.selector);
        creditConfigurator.setMaxEnabledTokens(1);

        vm.expectRevert(CallerNotControllerException.selector);
        creditConfigurator.rampLiquidationThreshold(DUMB_ADDRESS, 0, 0, 0);
    }

    //
    // TOKEN MANAGEMENT
    //

    /// @dev [CC-3]: addCollateralToken reverts for zero address or in priceFeed
    function test_CC_03_addCollateralToken_reverts_for_zero_address_or_in_priceFeed() public {
        vm.startPrank(CONFIGURATOR);

        vm.expectRevert(ZeroAddressException.selector);
        creditConfigurator.addCollateralToken(address(0), 9300);

        vm.expectRevert(abi.encodeWithSelector(AddressIsNotContractException.selector, DUMB_ADDRESS));
        creditConfigurator.addCollateralToken(DUMB_ADDRESS, 9300);

        vm.expectRevert(IncorrectTokenContractException.selector);
        creditConfigurator.addCollateralToken(address(this), 9300);

        address unknownPricefeedToken = address(new ERC20("TWPF", "Token without priceFeed"));

        vm.expectRevert(IncorrectPriceFeedException.selector);
        creditConfigurator.addCollateralToken(unknownPricefeedToken, 9300);

        vm.stopPrank();
    }

    /// @dev [CC-4]: addCollateralToken adds new token to creditManager
    function test_CC_04_addCollateralToken_adds_new_token_to_creditManager_and_set_lt() public {
        uint256 tokensCountBefore = creditManager.collateralTokensCount();

        address cLINKToken = tokenTestSuite.addressOf(Tokens.LUNA);

        vm.expectEmit(true, false, false, false);
        emit AllowToken(cLINKToken);

        vm.prank(CONFIGURATOR);
        creditConfigurator.addCollateralToken(cLINKToken, 8800);

        assertEq(creditManager.collateralTokensCount(), tokensCountBefore + 1, "Incorrect tokens count");

        (address token,) = creditManager.collateralTokens(tokensCountBefore);

        assertEq(token, cLINKToken, "Token is not added to list");

        assertTrue(creditManager.getTokenMaskOrRevert(cLINKToken) > 0, "Incorrect token mask");

        assertEq(creditManager.liquidationThresholds(cLINKToken), 8800, "Threshold wasn't set");
    }

    /// @dev [CC-5]: setLiquidationThreshold reverts for underling token and incorrect values
    function test_CC_05_setLiquidationThreshold_reverts_for_underling_token_and_incorrect_values() public {
        vm.startPrank(CONFIGURATOR);

        vm.expectRevert(SetLTForUnderlyingException.selector);
        creditConfigurator.setLiquidationThreshold(underlying, 1);

        address usdcToken = tokenTestSuite.addressOf(Tokens.USDC);

        uint16 maxAllowedLT = creditManager.liquidationThresholds(underlying);
        vm.expectRevert(IncorrectLiquidationThresholdException.selector);
        creditConfigurator.setLiquidationThreshold(usdcToken, maxAllowedLT + 1);

        vm.stopPrank();
    }

    /// @dev [CC-6]: setLiquidationThreshold sets liquidation threshold in creditManager
    function test_CC_06_setLiquidationThreshold_sets_liquidation_threshold_in_creditManager() public {
        address usdcToken = tokenTestSuite.addressOf(Tokens.USDC);
        uint16 newLT = 24;

        vm.expectEmit(true, false, false, true);
        emit SetTokenLiquidationThreshold(usdcToken, newLT);

        vm.prank(CONFIGURATOR);
        creditConfigurator.setLiquidationThreshold(usdcToken, newLT);

        assertEq(creditManager.liquidationThresholds(usdcToken), newLT);
    }

    /// @dev [CC-7]: allowToken and forbidToken reverts for unknown or underlying token
    function test_CC_07_allowToken_and_forbidToken_reverts_for_unknown_or_underlying_token() public {
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

    /// @dev [CC-8]: allowToken doesn't change forbidden mask if its already allowed
    function test_CC_08_allowToken_doesnt_change_forbidden_mask_if_its_already_allowed() public {
        address usdcToken = tokenTestSuite.addressOf(Tokens.USDC);
        uint256 forbiddenMask = creditFacade.forbiddenTokenMask();

        vm.prank(CONFIGURATOR);
        creditConfigurator.allowToken(usdcToken);

        assertEq(creditFacade.forbiddenTokenMask(), forbiddenMask, "Incorrect forbidden mask");
    }

    // TODO: change tests

    // /// @dev [CC-9]: allowToken allows token if it was forbidden
    // function test_CC_09_allows_token_if_it_was_forbidden() public {
    //     address usdcToken = tokenTestSuite.addressOf(Tokens.USDC);
    //     uint256 tokenMask = creditManager.getTokenMaskOrRevert(usdcToken);

    //     vm.prank(address(creditConfigurator));
    //     creditManager.setForbidMask(tokenMask);

    //     vm.expectEmit(true, false, false, false);
    //     emit AllowToken(usdcToken);

    //     vm.prank(CONFIGURATOR);
    //     creditConfigurator.allowToken(usdcToken);

    //     assertEq(creditManager.forbiddenTokenMask(), 0, "Incorrect forbidden mask");
    // }

    // /// @dev [CC-10]: forbidToken doesn't change forbidden mask if its already forbidden
    // function test_CC_10_forbidToken_doesnt_change_forbidden_mask_if_its_already_forbidden() public {
    //     address usdcToken = tokenTestSuite.addressOf(Tokens.USDC);
    //     uint256 tokenMask = creditManager.getTokenMaskOrRevert(usdcToken);

    //     vm.prank(address(creditConfigurator));
    //     creditManager.setForbidMask(tokenMask);

    //     uint256 forbiddenMask = creditManager.forbiddenTokenMask();

    //     vm.prank(CONFIGURATOR);
    //     creditConfigurator.forbidToken(usdcToken);

    //     assertEq(creditManager.forbiddenTokenMask(), forbiddenMask, "Incorrect forbidden mask");
    // }

    // /// @dev [CC-11]: forbidToken forbids token and enable IncreaseDebtForbidden mode if it was allowed
    // function test_CC_11_forbidToken_forbids_token_if_it_was_allowed() public {
    //     address usdcToken = tokenTestSuite.addressOf(Tokens.USDC);
    //     uint256 tokenMask = creditManager.getTokenMaskOrRevert(usdcToken);

    //     vm.prank(address(creditConfigurator));
    //     creditManager.setForbidMask(0);

    //     vm.expectEmit(true, false, false, false);
    //     emit ForbidToken(usdcToken);

    //     vm.prank(CONFIGURATOR);
    //     creditConfigurator.forbidToken(usdcToken);

    //     assertEq(creditManager.forbiddenTokenMask(), tokenMask, "Incorrect forbidden mask");
    // }

    //
    // CONFIGURATION: CONTRACTS & ADAPTERS MANAGEMENT
    //

    /// @dev [CC-12]: allowContract and forbidContract reverts for zero address
    function test_CC_12_allowContract_and_forbidContract_reverts_for_zero_address() public {
        vm.startPrank(CONFIGURATOR);

        vm.expectRevert(ZeroAddressException.selector);
        creditConfigurator.allowContract(address(0), address(this));

        vm.expectRevert(ZeroAddressException.selector);
        creditConfigurator.allowContract(address(this), address(0));

        vm.expectRevert(ZeroAddressException.selector);
        creditConfigurator.forbidContract(address(0));

        vm.stopPrank();
    }

    /// @dev [CC-12A]: allowContract reverts for non contract addresses
    function test_CC_12A_allowContract_reverts_for_non_contract_addresses() public {
        vm.startPrank(CONFIGURATOR);

        vm.expectRevert(abi.encodeWithSelector(AddressIsNotContractException.selector, DUMB_ADDRESS));
        creditConfigurator.allowContract(address(this), DUMB_ADDRESS);

        vm.expectRevert(abi.encodeWithSelector(AddressIsNotContractException.selector, DUMB_ADDRESS));
        creditConfigurator.allowContract(DUMB_ADDRESS, address(this));

        vm.stopPrank();
    }

    /// @dev [CC-12B]: allowContract reverts for non compartible adapter contract
    function test_CC_12B_allowContract_reverts_for_non_compartible_adapter_contract() public {
        vm.startPrank(CONFIGURATOR);

        // Should be reverted, cause undelring token has no .creditManager() method
        vm.expectRevert(IncompatibleContractException.selector);
        creditConfigurator.allowContract(address(this), underlying);

        // Should be reverted, cause it's conncted to another creditManager
        vm.expectRevert(IncompatibleContractException.selector);
        creditConfigurator.allowContract(address(this), address(adapterDifferentCM));

        vm.stopPrank();
    }

    /// @dev [CC-13]: allowContract reverts for creditManager and creditFacade contracts
    function test_CC_13_allowContract_reverts_for_creditManager_and_creditFacade_contracts() public {
        vm.startPrank(CONFIGURATOR);

        vm.expectRevert(TargetContractNotAllowedException.selector);
        creditConfigurator.allowContract(address(creditManager), DUMB_COMPARTIBLE_CONTRACT);

        vm.expectRevert(TargetContractNotAllowedException.selector);
        creditConfigurator.allowContract(DUMB_COMPARTIBLE_CONTRACT, address(creditFacade));

        vm.expectRevert(TargetContractNotAllowedException.selector);
        creditConfigurator.allowContract(address(creditFacade), DUMB_COMPARTIBLE_CONTRACT);

        vm.stopPrank();
    }

    /// @dev [CC-14]: allowContract: adapter could not be used twice
    function test_CC_14_allowContract_adapter_cannot_be_used_twice() public {
        vm.startPrank(CONFIGURATOR);

        creditConfigurator.allowContract(DUMB_COMPARTIBLE_CONTRACT, address(adapter1));

        vm.expectRevert(AdapterUsedTwiceException.selector);
        creditConfigurator.allowContract(address(adapterDifferentCM), address(adapter1));

        vm.stopPrank();
    }

    /// @dev [CC-15]: allowContract allows targetContract <-> adapter and emits event
    function test_CC_15_allowContract_allows_targetContract_adapter_and_emits_event() public {
        address[] memory allowedContracts = creditConfigurator.allowedContracts();
        uint256 allowedContractCount = allowedContracts.length;

        vm.prank(CONFIGURATOR);

        vm.expectEmit(true, true, false, false);
        emit AllowContract(TARGET_CONTRACT, address(adapter1));

        assertTrue(!allowedContracts.includes(TARGET_CONTRACT), "Contract already added");

        creditConfigurator.allowContract(TARGET_CONTRACT, address(adapter1));

        assertEq(
            creditManager.adapterToContract(address(adapter1)), TARGET_CONTRACT, "adapterToContract wasn't udpated"
        );

        assertEq(
            creditManager.contractToAdapter(TARGET_CONTRACT), address(adapter1), "contractToAdapter wasn't udpated"
        );

        allowedContracts = creditConfigurator.allowedContracts();

        assertEq(allowedContracts.length, allowedContractCount + 1, "Incorrect allowed contracts count");

        assertTrue(allowedContracts.includes(TARGET_CONTRACT), "Target contract wasnt found");
    }

    // /// @dev [CC-15A]: allowContract allows universal adapter for universal contract
    // function test_CC_15A_allowContract_allows_universal_contract() public {
    //     vm.prank(CONFIGURATOR);

    //     vm.expectEmit(true, true, false, false);
    //     emit AllowContract(UNIVERSAL_CONTRACT, address(adapter1));

    //     creditConfigurator.allowContract(UNIVERSAL_CONTRACT, address(adapter1));

    //     assertEq(creditManager.universalAdapter(), address(adapter1), "Universal adapter wasn't updated");
    // }

    /// @dev [CC-15A]: allowContract removes existing adapter
    function test_CC_15A_allowContract_removes_old_adapter_if_it_exists() public {
        vm.prank(CONFIGURATOR);
        creditConfigurator.allowContract(TARGET_CONTRACT, address(adapter1));

        AdapterMock adapter2 = new AdapterMock(
            address(creditManager),
            TARGET_CONTRACT
        );

        vm.prank(CONFIGURATOR);
        creditConfigurator.allowContract(TARGET_CONTRACT, address(adapter2));

        assertEq(creditManager.contractToAdapter(TARGET_CONTRACT), address(adapter2), "Incorrect adapter");

        assertEq(
            creditManager.adapterToContract(address(adapter2)),
            TARGET_CONTRACT,
            "Incorrect target contract for new adapter"
        );

        assertEq(creditManager.adapterToContract(address(adapter1)), address(0), "Old adapter was not removed");
    }

    /// @dev [CC-16]: forbidContract reverts for unknown contract
    function test_CC_16_forbidContract_reverts_for_unknown_contract() public {
        vm.expectRevert(ContractIsNotAnAllowedAdapterException.selector);

        vm.prank(CONFIGURATOR);
        creditConfigurator.forbidContract(TARGET_CONTRACT);
    }

    /// @dev [CC-17]: forbidContract forbids contract and emits event
    function test_CC_17_forbidContract_forbids_contract_and_emits_event() public {
        vm.startPrank(CONFIGURATOR);
        creditConfigurator.allowContract(DUMB_COMPARTIBLE_CONTRACT, address(adapter1));

        address[] memory allowedContracts = creditConfigurator.allowedContracts();

        uint256 allowedContractCount = allowedContracts.length;

        assertTrue(allowedContracts.includes(DUMB_COMPARTIBLE_CONTRACT), "Target contract wasnt found");

        vm.expectEmit(true, false, false, false);
        emit ForbidContract(DUMB_COMPARTIBLE_CONTRACT);

        creditConfigurator.forbidContract(DUMB_COMPARTIBLE_CONTRACT);

        //
        allowedContracts = creditConfigurator.allowedContracts();

        assertEq(creditManager.adapterToContract(address(adapter1)), address(0), "CreditManagerV3 wasn't udpated");

        assertEq(
            creditManager.contractToAdapter(DUMB_COMPARTIBLE_CONTRACT), address(0), "CreditFacadeV3 wasn't udpated"
        );

        assertEq(allowedContracts.length, allowedContractCount - 1, "Incorrect allowed contracts count");

        assertTrue(!allowedContracts.includes(DUMB_COMPARTIBLE_CONTRACT), "Target contract wasn't removed");

        vm.stopPrank();
    }

    //
    // CREDIT MANAGER MGMT
    //

    /// @dev [CC-18]: setLimits reverts if minAmount > maxAmount
    function test_CC_18_setLimits_reverts_if_minAmount_gt_maxAmount() public {
        (uint128 minBorrowedAmount, uint128 maxBorrowedAmount) = creditFacade.debtLimits();

        vm.expectRevert(IncorrectLimitsException.selector);

        vm.prank(CONFIGURATOR);
        creditConfigurator.setLimits(maxBorrowedAmount, minBorrowedAmount);
    }

    /// @dev [CC-19]: setLimits sets limits
    function test_CC_19_setLimits_sets_limits() public {
        (uint128 minBorrowedAmount, uint128 maxBorrowedAmount) = creditFacade.debtLimits();
        uint128 newMinBorrowedAmount = minBorrowedAmount + 1000;
        uint128 newMaxBorrowedAmount = maxBorrowedAmount + 1000;

        vm.expectEmit(false, false, false, true);
        emit SetBorrowingLimits(newMinBorrowedAmount, newMaxBorrowedAmount);
        vm.prank(CONFIGURATOR);
        creditConfigurator.setLimits(newMinBorrowedAmount, newMaxBorrowedAmount);
        (minBorrowedAmount, maxBorrowedAmount) = creditFacade.debtLimits();
        assertEq(minBorrowedAmount, newMinBorrowedAmount, "Incorrect minBorrowedAmount");
        assertEq(maxBorrowedAmount, newMaxBorrowedAmount, "Incorrect maxBorrowedAmount");
    }

    /// @dev [CC-23]: setFees reverts for incorrect fees
    function test_CC_23_setFees_reverts_for_incorrect_fees() public {
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

    /// @dev [CC-25]: setFees updates LT for underlying and for all tokens which bigger than new LT
    function test_CC_25_setFees_updates_LT_for_underlying_and_for_all_tokens_which_bigger_than_new_LT() public {
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

    /// @dev [CC-26]: setFees sets fees and doesn't change others
    function test_CC_26_setFees_sets_fees_and_doesnt_change_others() public {
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
        emit FeesUpdated(
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

    //
    // CONTRACT UPGRADES
    //

    /// @dev [CC-28]: setPriceOracle upgrades priceOracleCorrectly and doesnt change facade
    function test_CC_28_setPriceOracle_upgrades_priceOracleCorrectly_and_doesnt_change_facade() public {
        vm.startPrank(CONFIGURATOR);
        cct.addressProvider().setPriceOracle(DUMB_ADDRESS);

        vm.expectEmit(true, false, false, false);
        emit SetPriceOracle(DUMB_ADDRESS);

        creditConfigurator.setPriceOracle();

        assertEq(address(creditManager.priceOracle()), DUMB_ADDRESS);
        vm.stopPrank();
    }

    /// @dev [CC-29]: setPriceOracle upgrades priceOracleCorrectly and doesnt change facade
    function test_CC_29_setCreditFacade_upgradeCreditConfigurator_reverts_for_incompatible_contracts() public {
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

        vm.expectRevert(IncompatibleContractException.selector);
        creditConfigurator.setCreditFacade(address(adapterDifferentCM), false);

        vm.expectRevert(IncompatibleContractException.selector);
        creditConfigurator.upgradeCreditConfigurator(address(adapterDifferentCM));
    }

    /// @dev [CC-30]: setCreditFacade upgrades creditFacade and doesnt change priceOracle
    function test_CC_30_setCreditFacade_upgrades_creditFacade_and_doesnt_change_priceOracle() public {
        for (uint256 ex = 0; ex < 2; ex++) {
            bool isExpirable = ex != 0;
            for (uint256 ms = 0; ms < 2; ms++) {
                bool migrateSettings = ms != 0;

                setUp();

                if (isExpirable) {
                    CreditFacadeV3 initialCf = new CreditFacadeV3(
                            address(creditManager),
                            address(0),

                            true
                        );

                    vm.prank(CONFIGURATOR);
                    creditConfigurator.setCreditFacade(address(initialCf), migrateSettings);

                    vm.prank(CONFIGURATOR);
                    creditConfigurator.setExpirationDate(uint40(block.timestamp + 1));

                    creditFacade = initialCf;
                }

                CreditFacadeV3 cf = new CreditFacadeV3(
                        address(creditManager),
                        address(0),
                        isExpirable
                    );

                uint8 maxDebtPerBlockMultiplier = creditFacade.maxDebtPerBlockMultiplier();

                uint40 expirationDate = creditFacade.expirationDate();
                (uint128 minBorrowedAmount, uint128 maxBorrowedAmount) = creditFacade.debtLimits();

                vm.expectEmit(true, false, false, false);
                emit SetCreditFacade(address(cf));

                vm.prank(CONFIGURATOR);
                creditConfigurator.setCreditFacade(address(cf), migrateSettings);

                assertEq(address(creditManager.priceOracle()), cct.addressProvider().getPriceOracle());

                assertEq(address(creditManager.creditFacade()), address(cf));
                assertEq(address(creditConfigurator.creditFacade()), address(cf));

                uint8 maxDebtPerBlockMultiplier2 = cf.maxDebtPerBlockMultiplier();

                uint40 expirationDate2 = cf.expirationDate();

                (uint128 minBorrowedAmount2, uint128 maxBorrowedAmount2) = cf.debtLimits();

                assertEq(
                    maxDebtPerBlockMultiplier2,
                    migrateSettings ? maxDebtPerBlockMultiplier : 0,
                    "Incorrwect limitPerBlock"
                );
                assertEq(minBorrowedAmount2, migrateSettings ? minBorrowedAmount : 0, "Incorrwect minBorrowedAmount");
                assertEq(maxBorrowedAmount2, migrateSettings ? maxBorrowedAmount : 0, "Incorrwect maxBorrowedAmount");

                assertEq(expirationDate2, migrateSettings ? expirationDate : 0, "Incorrect expirationDate");
            }
        }
    }

    /// @dev [CC-30A]: usetCreditFacade transfers bot list
    function test_CC_30A_botList_is_transferred_on_CreditFacade_upgrade() public {
        for (uint256 ms = 0; ms < 2; ms++) {
            bool migrateSettings = ms != 0;

            setUp();

            address botList = address(new BotList(address(cct.addressProvider())));

            vm.prank(CONFIGURATOR);
            creditConfigurator.setBotList(botList);

            CreditFacadeV3 cf = new CreditFacadeV3(
                address(creditManager),
                address(0),
                false
            );

            vm.prank(CONFIGURATOR);
            creditConfigurator.setCreditFacade(address(cf), migrateSettings);

            address botList2 = cf.botList();

            assertEq(botList2, migrateSettings ? botList : address(0), "Bot list was not transferred");
        }
    }

    /// @dev [CC-31]: uupgradeCreditConfigurator upgrades creditConfigurator
    function test_CC_31_upgradeCreditConfigurator_upgrades_creditConfigurator() public {
        vm.expectEmit(true, false, false, false);
        emit CreditConfiguratorUpgraded(DUMB_COMPARTIBLE_CONTRACT);

        vm.prank(CONFIGURATOR);
        creditConfigurator.upgradeCreditConfigurator(DUMB_COMPARTIBLE_CONTRACT);

        assertEq(address(creditManager.creditConfigurator()), DUMB_COMPARTIBLE_CONTRACT);
    }

    /// @dev [CC-32]: setBorrowingAllowance sets IncreaseDebtForbidden
    function test_CC_32_setBorrowingAllowance_sets_IncreaseDebtForbidden() public {
        /// TODO: Change test
        // for (uint256 id = 0; id < 2; id++) {
        //     bool isIDF = id != 0;
        //     for (uint256 ii = 0; ii < 2; ii++) {
        //         bool initialIDF = ii != 0;

        //         setUp();

        //         vm.prank(CONFIGURATOR);
        //         creditConfigurator.setBorrowingAllowance(initialIDF);

        //         (, bool isIncreaseDebtFobidden,) = creditFacade.params();

        //         if (isIncreaseDebtFobidden != isIDF) {
        //             vm.expectEmit(false, false, false, true);
        //             emit SetIncreaseDebtForbiddenMode(isIDF);
        //         }

        //         vm.prank(CONFIGURATOR);
        //         creditConfigurator.setBorrowingAllowance(isIDF);

        //         (, isIncreaseDebtFobidden,) = creditFacade.params();

        //         assertTrue(isIncreaseDebtFobidden == isIDF, "Incorrect isIncreaseDebtFobidden");
        //     }
        // }
    }

    /// @dev [CC-33]: setMaxDebtLimitPerBlock reverts if it lt maxLimit otherwise sets limitPerBlock
    function test_CC_33_setMaxDebtLimitPerBlock_reverts_if_it_lt_maxLimit_otherwise_sets_limitPerBlock() public {
        // (, uint128 maxBorrowedAmount) = creditFacade.debtLimits();

        // vm.prank(CONFIGURATOR);
        // vm.expectRevert(IncorrectLimitsException.selector);
        // creditConfigurator.setMaxDebtLimitPerBlock(maxBorrowedAmount - 1);

        // uint128 newLimitBlock = (maxBorrowedAmount * 12) / 10;

        // vm.expectEmit(false, false, false, true);
        // emit SetMaxDebtPerBlockMultiplier(newLimitBlock);

        // vm.prank(CONFIGURATOR);
        // creditConfigurator.setMaxDebtLimitPerBlock(newLimitBlock);

        // (uint128 maxBorrowedAmountPerBlock,,) = creditFacade.params();

        // assertEq(maxBorrowedAmountPerBlock, newLimitBlock, "Incorrect new limits block");
    }

    /// @dev [CC-34]: setExpirationDate reverts if the new expiration date is stale, otherwise sets it
    function test_CC_34_setExpirationDate_reverts_on_incorrect_newExpirationDate_otherwise_sets() public {
        // cct.testFacadeWithExpiration();
        // creditFacade = cct.creditFacade();

        _setUp({withDegenNFT: false, expirable: true, supportQuotas: true});

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

    /// @dev [CC-37]: setMaxEnabledTokens works correctly and emits event
    function test_CC_37_setMaxEnabledTokens_works_correctly() public {
        vm.expectRevert(CallerNotControllerException.selector);
        creditConfigurator.setMaxEnabledTokens(255);

        vm.expectEmit(false, false, false, true);
        emit SetMaxEnabledTokens(255);

        vm.prank(CONFIGURATOR);
        creditConfigurator.setMaxEnabledTokens(255);

        assertEq(creditManager.maxAllowedEnabledTokenLength(), 255, "Credit manager max enabled tokens incorrect");
    }

    /// @dev [CC-38]: addEmergencyLiquidator works correctly and emits event
    function test_CC_38_addEmergencyLiquidator_works_correctly() public {
        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditConfigurator.addEmergencyLiquidator(DUMB_ADDRESS);

        vm.expectEmit(false, false, false, true);
        emit AddEmergencyLiquidator(DUMB_ADDRESS);

        vm.prank(CONFIGURATOR);
        creditConfigurator.addEmergencyLiquidator(DUMB_ADDRESS);

        assertTrue(
            creditFacade.canLiquidateWhilePaused(DUMB_ADDRESS), "Credit manager emergency liquidator status incorrect"
        );
    }

    /// @dev [CC-39]: removeEmergencyLiquidator works correctly and emits event
    function test_CC_39_removeEmergencyLiquidator_works_correctly() public {
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
    }

    /// @dev [CC-40]: forbidAdapter works correctly and emits event
    function test_CC_40_forbidAdapter_works_correctly() public {
        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditConfigurator.forbidAdapter(DUMB_ADDRESS);

        vm.prank(CONFIGURATOR);
        creditConfigurator.allowContract(TARGET_CONTRACT, address(adapter1));

        vm.expectEmit(true, false, false, false);
        emit ForbidAdapter(address(adapter1));

        vm.prank(CONFIGURATOR);
        creditConfigurator.forbidAdapter(address(adapter1));

        assertEq(
            creditManager.adapterToContract(address(adapter1)), address(0), "Adapter to contract link was not removed"
        );

        assertEq(
            creditManager.contractToAdapter(TARGET_CONTRACT), address(adapter1), "Contract to adapter link was removed"
        );
    }

    /// @dev [CC-41]: allowedContracts migrate correctly
    function test_CC_41_allowedContracts_are_migrated_correctly_for_new_CC() public {
        vm.prank(CONFIGURATOR);
        creditConfigurator.allowContract(TARGET_CONTRACT, address(adapter1));

        CollateralToken[] memory cTokens;

        CreditManagerOpts memory creditOpts = CreditManagerOpts({
            minBorrowedAmount: uint128(50 * WAD),
            maxBorrowedAmount: uint128(150000 * WAD),
            collateralTokens: cTokens,
            degenNFT: address(0),
            withdrawalManager: address(0),
            expirable: false
        });

        CreditConfigurator newCC = new CreditConfigurator(
            creditManager,
            creditFacade,
            creditOpts
        );

        assertEq(
            creditConfigurator.allowedContracts().length,
            newCC.allowedContracts().length,
            "Incorrect new allowed contracts array"
        );

        uint256 len = newCC.allowedContracts().length;

        for (uint256 i = 0; i < len;) {
            assertEq(
                creditConfigurator.allowedContracts()[i],
                newCC.allowedContracts()[i],
                "Allowed contracts migrated incorrectly"
            );

            unchecked {
                ++i;
            }
        }
    }

    function test_CC_42_rampLiquidationThreshold_works_correctly() public {
        address dai = tokenTestSuite.addressOf(Tokens.DAI);
        address usdc = tokenTestSuite.addressOf(Tokens.USDC);

        vm.expectRevert(SetLTForUnderlyingException.selector);
        vm.prank(CONFIGURATOR);
        creditConfigurator.rampLiquidationThreshold(dai, 9000, uint40(block.timestamp), 1);

        vm.expectRevert(IncorrectLiquidationThresholdException.selector);
        vm.prank(CONFIGURATOR);
        creditConfigurator.rampLiquidationThreshold(usdc, 9999, uint40(block.timestamp), 1);

        uint16 initialLT = creditManager.liquidationThresholds(usdc);

        // vm.expectCall(
        //     address(creditManager),
        //     abi.encodeCall(CreditManagerV3.rampLiquidationThreshold, (usdc, 8900, uint40(block.timestamp + 5), 1000))
        // );

        vm.expectEmit(true, false, false, true);
        emit ScheduleTokenLiquidationThresholdRamp(
            usdc, initialLT, 8900, uint40(block.timestamp), uint40(block.timestamp + 1000)
        );

        vm.prank(CONFIGURATOR);
        creditConfigurator.rampLiquidationThreshold(usdc, 8900, uint40(block.timestamp), 1000);
    }
}
