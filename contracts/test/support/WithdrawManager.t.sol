// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.10;

import {WithdrawManager} from "../../support/WithdrawManager.sol";
import {IWithdrawManagerEvents} from "../../interfaces/IWithdrawManager.sol";

// TEST
import "../lib/constants.sol";

// MOCKS
import {AddressProviderACLMock} from "../mocks/core/AddressProviderACLMock.sol";
import {ERC20BlacklistableMock} from "../mocks/token/ERC20Blacklistable.sol";

// SUITES
import {TokensTestSuite} from "../suites/TokensTestSuite.sol";
import {Tokens} from "../config/Tokens.sol";

// EXCEPTIONS

import "../../interfaces/IExceptions.sol";

/// @title LPPriceFeedTest
/// @notice Designed for unit test purposes only
contract WithdrawManagerTest is IWithdrawManagerEvents, DSTest {
    CheatCodes evm = CheatCodes(HEVM_ADDRESS);

    AddressProviderACLMock public addressProvider;

    WithdrawManager withdrawManager;

    TokensTestSuite tokenTestSuite;

    address usdc;

    bool public isBlacklistableUnderlying = true;

    function setUp() public {
        evm.prank(CONFIGURATOR);
        addressProvider = new AddressProviderACLMock();

        tokenTestSuite = new TokensTestSuite();

        usdc = tokenTestSuite.addressOf(Tokens.USDC);

        withdrawManager = new WithdrawManager(
            address(addressProvider)
          
        );
    }

    ///
    ///
    ///  TESTS
    ///
    ///

    /// @dev [BH-1]: constructor sets correct values
    function test_BH_01_constructor_sets_correct_values() public {
        // assertEq(withdrawManager.usdc(), usdc, "USDC address incorrect");

        // assertEq(withdrawManager.usdt(), DUMB_ADDRESS, "USDT address incorrect");
    }

    // /// @dev [BH-2]: isBlacklisted works correctly for all tokens
    // function test_BH_02_isBlacklisted_works_correctly() public {
    //     ERC20BlacklistableMock(usdc).setBlacklisted(USER, true);
    //     ERC20BlacklistableMock(usdc).setBlackListed(USER, true);

    //     evm.expectCall(usdc, abi.encodeWithSignature("isBlacklisted(address)", USER));

    //     bool status = withdrawManager.isBlacklisted(usdc, USER);

    //     assertTrue(status, "Blacklisted status incorrect");

    //     withdrawManager = new WithdrawManager(
    //         address(addressProvider)
    //     );

    //     evm.expectCall(usdc, abi.encodeWithSignature("isBlackListed(address)", USER));

    //     status = withdrawManager.isBlacklisted(usdc, USER);

    //     assertTrue(status, "Blacklisted status incorrect");
    // }

    // /// @dev [BH-3]: addCreditFacade / removeCreditFacade work correctly and revert on non-configurator
    // function test_BH_03_add_removeCreditFacade_work_correctly() public {
    //     evm.prank(CONFIGURATOR);
    //     withdrawManager.addCreditFacade(address(this));

    //     assertTrue(withdrawManager.isSupportedCreditFacade(address(this)), "Incorrect credit facade status");

    //     evm.prank(CONFIGURATOR);
    //     withdrawManager.removeCreditFacade(address(this));

    //     assertTrue(!withdrawManager.isSupportedCreditFacade(address(this)), "Incorrect credit facade status");

    //     evm.expectRevert(CallerNotConfiguratorException.selector);
    //     evm.prank(DUMB_ADDRESS);
    //     withdrawManager.addCreditFacade(address(this));

    //     isBlacklistableUnderlying = false;

    //     evm.expectRevert(CreditFacadeNonBlacklistable.selector);
    //     evm.prank(CONFIGURATOR);
    //     withdrawManager.addCreditFacade(address(this));
    // }

    // /// @dev [BH-4]: addClaimable works correctly and reverts on non-Credit Facade
    // function test_BH_04_addClaimable_works_correctly() public {
    //     evm.prank(CONFIGURATOR);
    //     withdrawManager.addCreditFacade(address(this));

    //     withdrawManager.addClaimable(usdc, USER, 10000);

    //     assertEq(withdrawManager.claimable(usdc, USER), 10000);

    //     evm.expectRevert(CallerNotCreditFacadeException.selector);
    //     evm.prank(DUMB_ADDRESS);
    //     withdrawManager.addClaimable(usdc, USER, 10000);
    // }

    // /// @dev [BH-5]: claim works correctly
    // function test_BH_05_claim_works_correctly() public {
    //     evm.prank(CONFIGURATOR);
    //     withdrawManager.addCreditFacade(address(this));

    //     withdrawManager.addClaimable(usdc, USER, 10000);

    //     tokenTestSuite.mint(Tokens.USDC, address(withdrawManager), 10000);

    //     evm.prank(USER);
    //     withdrawManager.claim(usdc, FRIEND);

    //     assertEq(tokenTestSuite.balanceOf(Tokens.USDC, FRIEND), 10000);

    //     evm.expectRevert(NothingToClaimException.selector);
    //     evm.prank(USER);
    //     withdrawManager.claim(usdc, FRIEND);
    // }
}
