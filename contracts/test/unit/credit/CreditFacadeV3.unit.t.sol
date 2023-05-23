// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import "../../../interfaces/IAddressProviderV3.sol";
import {AddressProviderV3ACLMock} from "../../mocks/core/AddressProviderV3ACLMock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IWETH} from "@gearbox-protocol/core-v2/contracts/interfaces/external/IWETH.sol";

/// LIBS
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {CreditFacadeV3Harness} from "./CreditFacadeV3Harness.sol";
import {CreditManagerV3} from "../../../credit/CreditManagerV3.sol";
import {CreditManagerMock} from "../../mocks/credit/CreditManagerMock.sol";
import {DegenNFTMock} from "../../mocks/token/DegenNFTMock.sol";

import {ENTERED} from "../../../traits/ReentrancyGuardTrait.sol";

import "../../../interfaces/ICreditFacade.sol";
import {ICreditManagerV3, ClosureAction, ManageDebtAction} from "../../../interfaces/ICreditManagerV3.sol";
import {AllowanceAction} from "../../../interfaces/ICreditConfiguratorV3.sol";
import {ICreditFacadeEvents} from "../../../interfaces/ICreditFacade.sol";
import {IDegenNFT, IDegenNFTExceptions} from "@gearbox-protocol/core-v2/contracts/interfaces/IDegenNFT.sol";

// DATA
import {MultiCall, MultiCallOps} from "@gearbox-protocol/core-v2/contracts/libraries/MultiCall.sol";
import {Balance} from "@gearbox-protocol/core-v2/contracts/libraries/Balances.sol";

import {CreditFacadeMulticaller, CreditFacadeCalls} from "../../../multicall/CreditFacadeCalls.sol";

// CONSTANTS
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/PercentageMath.sol";

// TESTS

import "../../lib/constants.sol";
import {BalanceHelper} from "../../helpers/BalanceHelper.sol";

// EXCEPTIONS
import "../../../interfaces/IExceptions.sol";

// SUITES
import {TokensTestSuite} from "../../suites/TokensTestSuite.sol";
import {Tokens} from "../../config/Tokens.sol";

import "forge-std/console.sol";

uint16 constant REFERRAL_CODE = 23;

contract CreditFacadeV3UnitTest is BalanceHelper, ICreditFacadeEvents {
    using CreditFacadeCalls for CreditFacadeMulticaller;

    IAddressProviderV3 addressProvider;

    CreditFacadeV3Harness creditFacade;
    CreditManagerMock creditManagerMock;

    DegenNFTMock degenNFTMock;
    bool whitelisted;

    bool expirable;

    modifier notExpirableCase() {
        _notExpirable();
        _;
    }

    modifier expirableCase() {
        _expirable();
        _;
    }

    modifier allExpirableCases() {
        uint256 snapshot = vm.snapshot();
        _notExpirable();
        _;
        vm.revertTo(snapshot);

        _expirable();
        _;
    }

    modifier withoutDegenNFT() {
        _withoutDegenNFT();
        _;
    }

    modifier withDegenNFT() {
        _withDegenNFT();
        _;
    }

    modifier allDegenNftCases() {
        uint256 snapshot = vm.snapshot();

        _withoutDegenNFT();
        _;
        vm.revertTo(snapshot);

        _withDegenNFT();
        _;
    }

    function setUp() public {
        tokenTestSuite = new TokensTestSuite();

        tokenTestSuite.topUpWETH{value: 100 * WAD}();

        addressProvider = new AddressProviderV3ACLMock();

        addressProvider.setAddress(AP_WETH_TOKEN, tokenTestSuite.addressOf(Tokens.WETH), false);

        AddressProviderV3ACLMock(address(addressProvider)).addPausableAdmin(CONFIGURATOR);

        creditManagerMock = new CreditManagerMock({
            _addressProvider: address(addressProvider),
            _pool: address(0)
        });
    }

    function _withoutDegenNFT() internal {
        degenNFTMock = DegenNFTMock(address(0));
    }

    function _withDegenNFT() internal {
        whitelisted = true;
        degenNFTMock = new DegenNFTMock();
    }

    function _notExpirable() internal {
        expirable = false;
        creditFacade = new CreditFacadeV3Harness(
            address(creditManagerMock),
            address(degenNFTMock),
            expirable
        );
    }

    function _expirable() internal {
        expirable = true;
        creditFacade = new CreditFacadeV3Harness(
            address(creditManagerMock),
            address(degenNFTMock),
            expirable
        );
    }

    /// @dev U:[FA-1]: constructor sets correct values
    function test_U_FA_01_constructor_sets_correct_values() public allDegenNftCases allExpirableCases {
        assertEq(address(creditFacade.creditManager()), address(creditManagerMock), "Incorrect creditManager");

        assertEq(creditFacade.weth(), creditManagerMock.weth(), "Incorrect weth token");

        assertEq(creditFacade.wethGateway(), creditManagerMock.wethGateway(), "Incorrect weth gateway");

        assertEq(creditFacade.degenNFT(), address(degenNFTMock), "Incorrect degenNFTMock");
    }

    /// @dev U:[FA-2]: user functions revert if called on pause
    function test_U_FA_02_user_functions_revert_if_called_on_pause() public notExpirableCase {
        creditManagerMock.setBorrower(address(this));

        vm.prank(CONFIGURATOR);
        creditFacade.pause();

        vm.expectRevert("Pausable: paused");
        creditFacade.openCreditAccount({debt: 0, onBehalfOf: USER, calls: new MultiCall[](0), referralCode: 0});

        vm.expectRevert("Pausable: paused");
        creditFacade.closeCreditAccount({
            creditAccount: DUMB_ADDRESS,
            to: DUMB_ADDRESS,
            skipTokenMask: 0,
            convertToETH: false,
            calls: new MultiCall[](0)
        });

        /// @notice We'll check that it works for emergency liquidatior as exceptions in another test
        vm.expectRevert("Pausable: paused");
        creditFacade.liquidateCreditAccount({
            creditAccount: DUMB_ADDRESS,
            to: DUMB_ADDRESS,
            skipTokenMask: 0,
            convertToETH: false,
            calls: new MultiCall[](0)
        });

        vm.expectRevert("Pausable: paused");
        creditFacade.multicall({creditAccount: DUMB_ADDRESS, calls: new MultiCall[](0)});

        vm.expectRevert("Pausable: paused");
        creditFacade.botMulticall({creditAccount: DUMB_ADDRESS, calls: new MultiCall[](0)});

        vm.expectRevert("Pausable: paused");
        creditFacade.claimWithdrawals({creditAccount: DUMB_ADDRESS, to: DUMB_ADDRESS});
    }

    /// @dev U:[FA-3]: user functions revert if credit facade is expired
    function test_U_FA_03_user_functions_revert_if_credit_facade_is_expired() public expirableCase {
        vm.prank(CONFIGURATOR);
        creditFacade.setExpirationDate(uint40(block.timestamp));
        creditManagerMock.setBorrower(address(this));

        vm.warp(block.timestamp + 1);

        vm.expectRevert(NotAllowedAfterExpirationException.selector);
        creditFacade.openCreditAccount({debt: 0, onBehalfOf: USER, calls: new MultiCall[](0), referralCode: 0});

        vm.expectRevert(NotAllowedAfterExpirationException.selector);
        creditFacade.multicall({creditAccount: DUMB_ADDRESS, calls: new MultiCall[](0)});

        vm.expectRevert(NotAllowedAfterExpirationException.selector);
        creditFacade.botMulticall({creditAccount: DUMB_ADDRESS, calls: new MultiCall[](0)});
    }

    /// @dev U:[FA-4]: non-reentrancy works for all non-cofigurable functions
    function test_U_FA_04_non_reentrancy_works_for_all_non_cofigurable_functions() public notExpirableCase {
        creditFacade.setReentrancy(ENTERED);
        creditManagerMock.setBorrower(address(this));

        vm.expectRevert("ReentrancyGuard: reentrant call");
        creditFacade.openCreditAccount({debt: 0, onBehalfOf: USER, calls: new MultiCall[](0), referralCode: 0});

        vm.expectRevert("ReentrancyGuard: reentrant call");
        creditFacade.closeCreditAccount({
            creditAccount: DUMB_ADDRESS,
            to: DUMB_ADDRESS,
            skipTokenMask: 0,
            convertToETH: false,
            calls: new MultiCall[](0)
        });

        vm.expectRevert("ReentrancyGuard: reentrant call");
        creditFacade.liquidateCreditAccount({
            creditAccount: DUMB_ADDRESS,
            to: DUMB_ADDRESS,
            skipTokenMask: 0,
            convertToETH: false,
            calls: new MultiCall[](0)
        });

        vm.expectRevert("ReentrancyGuard: reentrant call");
        creditFacade.multicall({creditAccount: DUMB_ADDRESS, calls: new MultiCall[](0)});

        vm.expectRevert("ReentrancyGuard: reentrant call");
        creditFacade.botMulticall({creditAccount: DUMB_ADDRESS, calls: new MultiCall[](0)});

        vm.expectRevert("ReentrancyGuard: reentrant call");
        creditFacade.claimWithdrawals({creditAccount: DUMB_ADDRESS, to: DUMB_ADDRESS});

        vm.expectRevert("ReentrancyGuard: reentrant call");
        creditFacade.setBotPermissions({
            creditAccount: DUMB_ADDRESS,
            bot: DUMB_ADDRESS,
            permissions: 0,
            fundingAmount: 0,
            weeklyFundingAllowance: 0
        });
    }

    /// @dev U:[FA-5]: borrower related functions revert if called not by borrower
    function test_U_FA_05_borrower_related_functions_revert_if_called_not_by_borrower() public notExpirableCase {
        vm.expectRevert(CreditAccountNotExistsException.selector);
        creditFacade.closeCreditAccount({
            creditAccount: DUMB_ADDRESS,
            to: DUMB_ADDRESS,
            skipTokenMask: 0,
            convertToETH: false,
            calls: new MultiCall[](0)
        });

        vm.expectRevert(CreditAccountNotExistsException.selector);
        creditFacade.liquidateCreditAccount({
            creditAccount: DUMB_ADDRESS,
            to: DUMB_ADDRESS,
            skipTokenMask: 0,
            convertToETH: false,
            calls: new MultiCall[](0)
        });

        vm.expectRevert(CreditAccountNotExistsException.selector);
        creditFacade.multicall({creditAccount: DUMB_ADDRESS, calls: new MultiCall[](0)});

        vm.expectRevert(CreditAccountNotExistsException.selector);
        creditFacade.claimWithdrawals({creditAccount: DUMB_ADDRESS, to: DUMB_ADDRESS});

        vm.expectRevert(CreditAccountNotExistsException.selector);
        creditFacade.setBotPermissions({
            creditAccount: DUMB_ADDRESS,
            bot: DUMB_ADDRESS,
            permissions: 0,
            fundingAmount: 0,
            weeklyFundingAllowance: 0
        });
    }

    /// @dev U:[FA-6]: all configurator functions revert if called by non-configurator
    function test_U_FA_06_all_configurator_functions_revert_if_called_by_non_configurator() public notExpirableCase {
        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditFacade.setExpirationDate(0);

        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditFacade.setDebtLimits(0, 0, 0);

        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditFacade.setBotList(address(1));

        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditFacade.setCumulativeLossParams(0, false);

        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditFacade.setTokenAllowance(address(0), AllowanceAction.ALLOW);

        vm.expectRevert(CallerNotConfiguratorException.selector);
        creditFacade.setEmergencyLiquidator(address(0), AllowanceAction.ALLOW);
    }

    /// @dev U:[FA-7]: payable functions wraps eth to msg.sender
    function test_U_FA_07_payable_functions_wraps_eth_to_msg_sender() public notExpirableCase {
        vm.deal(USER, 3 ether);

        vm.prank(CONFIGURATOR);
        creditFacade.setDebtLimits(1 ether, 9 ether, 9);

        vm.prank(USER);
        creditFacade.openCreditAccount{value: 1 ether}({
            debt: 1 ether,
            onBehalfOf: USER,
            calls: new MultiCall[](0),
            referralCode: 0
        });

        expectBalance({t: Tokens.WETH, holder: USER, expectedBalance: 1 ether});

        creditManagerMock.setBorrower(USER);

        vm.prank(USER);
        creditFacade.closeCreditAccount{value: 1 ether}({
            creditAccount: DUMB_ADDRESS,
            to: DUMB_ADDRESS,
            skipTokenMask: 0,
            convertToETH: false,
            calls: new MultiCall[](0)
        });
        expectBalance({t: Tokens.WETH, holder: USER, expectedBalance: 2 ether});

        vm.prank(USER);
        creditFacade.multicall{value: 1 ether}({creditAccount: DUMB_ADDRESS, calls: new MultiCall[](0)});

        expectBalance({t: Tokens.WETH, holder: USER, expectedBalance: 3 ether});
    }

    //
    // OPEN CREDIT ACCOUNT
    //

    /// @dev U:[FA-8]: openCreditAccount reverts if out of limits
    function test_U_FA_08_openCreditAccount_reverts_if_out_of_limits(uint128 a, uint128 b) public notExpirableCase {
        vm.assume(a > 0 && b > 0);

        uint128 minDebt = uint128(Math.min(a, b));
        uint128 maxDebt = uint128(Math.max(a, b));
        uint8 multiplier = uint8(maxDebt % 255 + 1);

        vm.assume(maxDebt < type(uint128).max / 256);

        vm.prank(CONFIGURATOR);
        creditFacade.setDebtLimits(minDebt, maxDebt, 0);

        vm.expectRevert(BorrowAmountOutOfLimitsException.selector);
        creditFacade.openCreditAccount({debt: minDebt - 1, onBehalfOf: USER, calls: new MultiCall[](0), referralCode: 0});

        vm.expectRevert(BorrowAmountOutOfLimitsException.selector);
        creditFacade.openCreditAccount({debt: maxDebt + 1, onBehalfOf: USER, calls: new MultiCall[](0), referralCode: 0});

        creditFacade.setTotalBorrowedInBlock(maxDebt * multiplier - minDebt + 1);

        vm.expectRevert(BorrowedBlockLimitException.selector);
        creditFacade.openCreditAccount({debt: minDebt, onBehalfOf: USER, calls: new MultiCall[](0), referralCode: 0});
    }

    /// @dev U:[FA-9]: openCreditAccount reverts in whitelisted if user has no rights
    function test_U_FA_09_openCreditAccount_reverts_in_whitelisted_if_user_has_no_rights()
        public
        withDegenNFT
        notExpirableCase
    {
        vm.prank(CONFIGURATOR);
        creditFacade.setDebtLimits(1, 2, 2);

        vm.prank(USER);

        vm.expectRevert(ForbiddenInWhitelistedModeException.selector);
        creditFacade.openCreditAccount({debt: 1, onBehalfOf: FRIEND, calls: new MultiCall[](0), referralCode: 0});

        degenNFTMock.setRevertOnBurn(true);

        vm.prank(USER);
        vm.expectRevert(InsufficientBalanceException.selector);
        creditFacade.openCreditAccount({debt: 1, onBehalfOf: USER, calls: new MultiCall[](0), referralCode: 0});
    }

    /// @dev U:[FA-10]: openCreditAccount wokrs as expected
    function test_U_FA_10_openCreditAccount_works_as_expected() public notExpirableCase {
        vm.prank(CONFIGURATOR);
        creditFacade.setDebtLimits(100, 200, 1);

        uint256 debt = 200;

        address expectedCreditAccount = DUMB_ADDRESS;
        creditManagerMock.setReturnOpenCreditAccount(expectedCreditAccount);

        vm.expectCall(address(creditManagerMock), abi.encodeCall(ICreditManagerV3.openCreditAccount, (debt, FRIEND)));

        vm.expectEmit(true, true, true, true);
        emit OpenCreditAccount(expectedCreditAccount, FRIEND, USER, debt, REFERRAL_CODE);

        vm.expectEmit(true, true, false, false);
        emit StartMultiCall(expectedCreditAccount);

        vm.expectEmit(true, false, false, false);
        emit FinishMultiCall();

        vm.expectCall(
            address(creditManagerMock),
            abi.encodeCall(ICreditManagerV3.fullCollateralCheck),
            (expectedCreditAccount, UNDERLYING_TOKEN_MASK, PERCENTAGE_FACTOR, new uint256[](0))
        );

        vm.prank(USER);
        address creditAccount = creditFacade.openCreditAccount({
            debt: debt,
            onBehalfOf: FRIEND,
            calls: new MultiCall[](0),
            referralCode: REFERRAL_CODE
        });

        assertEq(creditAccount, expectedCreditAccount, "Incorrect credit account");
    }
}
