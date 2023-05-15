// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.10;

import {GearStaking} from "../../../support/GearStaking.sol";
import {IGearStakingEvents, MultiVote, VotingContractStatus} from "../../../interfaces/IGearStaking.sol";
import {IVotingContract} from "../../../interfaces/IVotingContract.sol";
import {CallerNotConfiguratorException} from "../../../interfaces/IExceptions.sol";
import "../../../interfaces/IAddressProviderV3.sol";

// TEST
import "../../lib/constants.sol";

// MOCKS
import {AddressProviderACLMock} from "../../mocks/core/AddressProviderACLMock.sol";
import {ERC20Mock} from "@gearbox-protocol/core-v2/contracts/test/mocks/token/ERC20Mock.sol";
import {TargetContractMock} from "@gearbox-protocol/core-v2/contracts/test/mocks/adapters/TargetContractMock.sol";

// SUITES
import {TokensTestSuite} from "../../suites/TokensTestSuite.sol";
import {Tokens} from "../../config/Tokens.sol";

// EXCEPTIONS
import "../../../interfaces/IExceptions.sol";

import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";

uint256 constant EPOCH_LENGTH = 7 days;

contract GearStakingTest is Test, IGearStakingEvents {
    address gearToken;

    AddressProviderACLMock public addressProvider;

    GearStaking gearStaking;

    TargetContractMock votingContract;

    TokensTestSuite tokenTestSuite;

    function setUp() public {
        vm.prank(CONFIGURATOR);
        addressProvider = new AddressProviderACLMock();

        tokenTestSuite = new TokensTestSuite();

        gearToken = tokenTestSuite.addressOf(Tokens.WETH);

        vm.prank(CONFIGURATOR);
        addressProvider.setAddress(AP_GEAR_TOKEN, gearToken, false);

        gearStaking = new GearStaking(address(addressProvider), block.timestamp + 1);

        votingContract = new TargetContractMock();

        vm.prank(CONFIGURATOR);
        gearStaking.setVotingContractStatus(address(votingContract), VotingContractStatus.ALLOWED);
    }

    /// @dev [GS-01]: constructor sets correct values
    function test_GS_01_constructor_sets_correct_values() public {
        assertEq(address(gearStaking.gear()), gearToken, "Gear token incorrect");

        assertEq(gearStaking.getCurrentEpoch(), 0, "First epoch timestamp incorrect");

        vm.warp(block.timestamp + 1);

        assertEq(gearStaking.getCurrentEpoch(), 1, "First epoch timestamp incorrect");
    }

    /// @dev [GS-02]: deposit performs operations in order and emits events
    function test_GS_02_deposit_works_correctly() public {
        MultiVote[] memory votes = new MultiVote[](1);
        votes[0] = MultiVote({
            votingContract: address(votingContract),
            voteAmount: uint96(WAD / 2),
            isIncrease: true,
            extraData: ""
        });

        tokenTestSuite.mint(gearToken, USER, WAD);
        tokenTestSuite.approve(gearToken, USER, address(gearStaking));

        vm.expectEmit(true, false, false, true);
        emit DepositGear(USER, WAD);

        vm.expectCall(address(votingContract), abi.encodeCall(IVotingContract.vote, (USER, uint96(WAD / 2), "")));

        vm.prank(USER);
        gearStaking.deposit(WAD, votes);

        assertEq(gearStaking.balanceOf(USER), WAD);

        assertEq(gearStaking.availableBalance(USER), WAD / 2);
    }

    /// @dev [GS-03]: withdraw performs operations in order and emits events
    function test_GS_03_withdraw_works_correctly() public {
        MultiVote[] memory votes = new MultiVote[](1);
        votes[0] = MultiVote({
            votingContract: address(votingContract),
            voteAmount: uint96(WAD / 2),
            isIncrease: true,
            extraData: ""
        });

        tokenTestSuite.mint(gearToken, USER, WAD);
        tokenTestSuite.approve(gearToken, USER, address(gearStaking));

        vm.prank(USER);
        gearStaking.deposit(WAD, votes);

        votes = new MultiVote[](1);
        votes[0] = MultiVote({
            votingContract: address(votingContract),
            voteAmount: uint96(WAD / 2),
            isIncrease: false,
            extraData: ""
        });

        vm.expectCall(address(votingContract), abi.encodeCall(IVotingContract.unvote, (USER, uint96(WAD / 2), "")));

        vm.expectEmit(true, false, false, true);
        emit ScheduleGearWithdrawal(USER, WAD);

        vm.prank(USER);
        gearStaking.withdraw(WAD, FRIEND, votes);

        assertEq(gearStaking.balanceOf(USER), WAD);

        assertEq(gearStaking.availableBalance(USER), 0);

        (uint256 withdrawableNow, uint256[4] memory withdrawableInEpochs) = gearStaking.getWithdrawableAmounts(USER);

        assertEq(withdrawableInEpochs[3], WAD, "Incorrect amount scheduled to withdraw");

        assertEq(withdrawableNow, 0, "Amount withdrawable now instead of scheduled");
    }

    /// @dev [GS-04]: multivote works correctly
    function test_GS_04_multivote_works_correctly() public {
        MultiVote[] memory votes = new MultiVote[](0);

        tokenTestSuite.mint(gearToken, USER, WAD);
        tokenTestSuite.approve(gearToken, USER, address(gearStaking));

        vm.prank(USER);
        gearStaking.deposit(WAD, votes);

        TargetContractMock votingContract2 = new TargetContractMock();

        vm.prank(CONFIGURATOR);
        gearStaking.setVotingContractStatus(address(votingContract2), VotingContractStatus.ALLOWED);

        votes = new MultiVote[](3);
        votes[0] = MultiVote({
            votingContract: address(votingContract),
            voteAmount: uint96(WAD / 2),
            isIncrease: true,
            extraData: "foo"
        });

        votes[1] = MultiVote({
            votingContract: address(votingContract2),
            voteAmount: uint96(WAD / 3),
            isIncrease: true,
            extraData: "bar"
        });

        votes[2] = MultiVote({
            votingContract: address(votingContract2),
            voteAmount: uint96(WAD / 4),
            isIncrease: false,
            extraData: "foobar"
        });

        vm.expectCall(address(votingContract), abi.encodeCall(IVotingContract.vote, (USER, uint96(WAD / 2), "foo")));

        vm.expectCall(address(votingContract2), abi.encodeCall(IVotingContract.vote, (USER, uint96(WAD / 3), "bar")));

        vm.expectCall(
            address(votingContract2), abi.encodeCall(IVotingContract.unvote, (USER, uint96(WAD / 4), "foobar"))
        );

        vm.prank(USER);
        gearStaking.multivote(votes);

        assertEq(gearStaking.availableBalance(USER), (WAD - WAD / 2 - WAD / 3) + WAD / 4);
    }

    /// @dev [GS-04A]: multivote reverts if voting contract status is incorrect
    function test_GS_04A_multivote_respects_voting_contract_status() public {
        MultiVote[] memory votes = new MultiVote[](1);
        votes[0] = MultiVote({
            votingContract: address(votingContract),
            voteAmount: uint96(WAD / 2),
            isIncrease: true,
            extraData: "foo"
        });

        tokenTestSuite.mint(gearToken, USER, WAD);
        tokenTestSuite.approve(gearToken, USER, address(gearStaking));

        vm.prank(USER);
        gearStaking.deposit(WAD, votes);

        vm.prank(CONFIGURATOR);
        gearStaking.setVotingContractStatus(address(votingContract), VotingContractStatus.NOT_ALLOWED);

        votes = new MultiVote[](1);
        votes[0] = MultiVote({
            votingContract: address(votingContract),
            voteAmount: uint96(WAD / 2),
            isIncrease: true,
            extraData: "foo"
        });

        vm.expectRevert(VotingContractNotAllowedException.selector);

        vm.prank(USER);
        gearStaking.multivote(votes);

        votes = new MultiVote[](1);
        votes[0] = MultiVote({
            votingContract: address(votingContract),
            voteAmount: uint96(WAD / 2),
            isIncrease: false,
            extraData: "foo"
        });

        vm.expectRevert(VotingContractNotAllowedException.selector);

        vm.prank(USER);
        gearStaking.multivote(votes);

        vm.prank(CONFIGURATOR);
        gearStaking.setVotingContractStatus(address(votingContract), VotingContractStatus.UNVOTE_ONLY);

        votes = new MultiVote[](1);
        votes[0] = MultiVote({
            votingContract: address(votingContract),
            voteAmount: uint96(WAD / 2),
            isIncrease: true,
            extraData: "foo"
        });

        vm.expectRevert(VotingContractNotAllowedException.selector);

        vm.prank(USER);
        gearStaking.multivote(votes);

        votes = new MultiVote[](1);
        votes[0] = MultiVote({
            votingContract: address(votingContract),
            voteAmount: uint96(WAD / 2),
            isIncrease: false,
            extraData: "foo"
        });

        vm.prank(USER);
        gearStaking.multivote(votes);
    }

    /// @dev [GS-05]: claimWithdrawals correctly processes pending withdrawals
    function test_GS_05_claimWithdrawals_works_correctly() public {
        MultiVote[] memory votes = new MultiVote[](0);

        tokenTestSuite.mint(gearToken, USER, WAD);
        tokenTestSuite.approve(gearToken, USER, address(gearStaking));

        vm.prank(USER);
        gearStaking.deposit(WAD, votes);

        vm.prank(USER);
        gearStaking.withdraw(1000, FRIEND, votes);

        vm.warp(block.timestamp + EPOCH_LENGTH);

        vm.prank(USER);
        gearStaking.withdraw(2000, FRIEND, votes);

        vm.warp(block.timestamp + EPOCH_LENGTH);

        vm.prank(USER);
        gearStaking.withdraw(3000, FRIEND, votes);

        vm.warp(block.timestamp + EPOCH_LENGTH);

        vm.prank(USER);
        gearStaking.withdraw(4000, FRIEND, votes);

        (uint256 withdrawableNow, uint256[4] memory withdrawableInEpochs) = gearStaking.getWithdrawableAmounts(USER);

        assertEq(withdrawableInEpochs[0], 1000, "Incorrect withdrawable in epoch 1");

        assertEq(withdrawableInEpochs[1], 2000, "Incorrect withdrawable in epoch 2");

        assertEq(withdrawableInEpochs[2], 3000, "Incorrect withdrawable in epoch 3");

        assertEq(withdrawableInEpochs[3], 4000, "Incorrect withdrawable in epoch 4");

        assertEq(withdrawableNow, 0, "Incorrect withdrawable now");

        vm.warp(block.timestamp + 2 * EPOCH_LENGTH);

        vm.expectEmit(true, false, false, true);
        emit ClaimGearWithdrawal(USER, FRIEND, 3000);

        vm.prank(USER);
        gearStaking.claimWithdrawals(FRIEND);

        (withdrawableNow, withdrawableInEpochs) = gearStaking.getWithdrawableAmounts(USER);

        assertEq(withdrawableInEpochs[0], 3000, "Incorrect withdrawable in epoch 1");

        assertEq(withdrawableInEpochs[1], 4000, "Incorrect withdrawable in epoch 2");

        assertEq(withdrawableInEpochs[2], 0, "Incorrect withdrawable in epoch 3");

        assertEq(withdrawableInEpochs[3], 0, "Incorrect withdrawable in epoch 4");

        assertEq(withdrawableNow, 0, "Incorrect withdrawable now");

        assertEq(gearStaking.balanceOf(USER), WAD - 3000, "Incorrect total balance");

        assertEq(gearStaking.availableBalance(USER), WAD - 10000, "Incorrect available balance");

        assertEq(tokenTestSuite.balanceOf(gearToken, FRIEND), 3000);

        vm.warp(block.timestamp + EPOCH_LENGTH);

        vm.expectEmit(true, false, false, true);
        emit ClaimGearWithdrawal(USER, FRIEND, 3000);

        vm.prank(USER);
        gearStaking.withdraw(10000, FRIEND, votes);

        (withdrawableNow, withdrawableInEpochs) = gearStaking.getWithdrawableAmounts(USER);

        assertEq(withdrawableInEpochs[0], 4000, "Incorrect withdrawable in epoch 1");

        assertEq(withdrawableInEpochs[1], 0, "Incorrect withdrawable in epoch 2");

        assertEq(withdrawableInEpochs[2], 0, "Incorrect withdrawable in epoch 3");

        assertEq(withdrawableInEpochs[3], 10000, "Incorrect withdrawable in epoch 4");

        assertEq(gearStaking.balanceOf(USER), WAD - 6000, "Incorrect total balance");

        assertEq(gearStaking.availableBalance(USER), WAD - 20000, "Incorrect available balance");

        assertEq(tokenTestSuite.balanceOf(gearToken, FRIEND), 6000);
    }

    /// @dev [GS-06]: setVotingContractStatus respects access control and emits event
    function test_GS_06_setVotingContractStatus_works_correctly() public {
        vm.expectRevert(CallerNotConfiguratorException.selector);
        gearStaking.setVotingContractStatus(DUMB_ADDRESS, VotingContractStatus.ALLOWED);

        vm.expectEmit(true, false, false, true);
        emit SetVotingContractStatus(DUMB_ADDRESS, VotingContractStatus.UNVOTE_ONLY);

        vm.prank(CONFIGURATOR);
        gearStaking.setVotingContractStatus(DUMB_ADDRESS, VotingContractStatus.UNVOTE_ONLY);
    }
}
