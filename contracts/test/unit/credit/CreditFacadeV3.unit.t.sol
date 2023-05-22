// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import "../../../interfaces/IAddressProviderV3.sol";
import {AddressProviderV3ACLMock} from "../../mocks/core/AddressProviderV3ACLMock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IWETH} from "@gearbox-protocol/core-v2/contracts/interfaces/external/IWETH.sol";

import {CreditFacadeV3Harness} from "./CreditFacadeV3Harness.sol";
import {CreditManagerV3} from "../../../credit/CreditManagerV3.sol";
import {CreditManagerMock} from "../../mocks/credit/CreditManagerMock.sol";
import {DegenNFTMock} from "../../mocks/token/DegenNFTMock.sol";

import {BotList} from "../../../support/BotList.sol";

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

uint256 constant WETH_TEST_AMOUNT = 5 * WAD;
uint16 constant REFERRAL_CODE = 23;

/// @title CreditFacadeTest
/// @notice Designed for unit test purposes only
contract CreditFacadeUnitTest is BalanceHelper, ICreditFacadeEvents {
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

        assertTrue(creditFacade.whitelisted() == whitelisted, "Incorrect whitelisted");
    }

    /// @dev U:[FA-2]: user functions revert if called on pause
    function test_U_FA_02_user_functions_revert_if_called_on_pause() public notExpirableCase {
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

        vm.warp(block.timestamp + 1);

        vm.expectRevert(NotAllowedAfterExpirationException.selector);
        creditFacade.openCreditAccount({debt: 0, onBehalfOf: USER, calls: new MultiCall[](0), referralCode: 0});
    }
}
