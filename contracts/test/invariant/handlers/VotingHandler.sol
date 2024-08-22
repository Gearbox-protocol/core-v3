// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {GearStakingV3, MultiVote} from "../../../governance/GearStakingV3.sol";
import {IGaugeV3, UserVotes} from "../../../interfaces/IGaugeV3.sol";
import {VotingContractMock} from "../../mocks/governance/VotingContractMock.sol";
import {HandlerBase} from "./HandlerBase.sol";

contract VotingHandler is HandlerBase {
    GearStakingV3 public gearStaking;
    ERC20 public gear;

    address[] _stakers;
    address _staker;

    address[] _votingContracts;
    mapping(address => address[]) _gaugeTokens;

    mapping(address => mapping(address => uint256)) _votesCasted;

    modifier withStaker(uint256 idx) {
        _staker = _get(_stakers, idx);
        vm.startPrank(_staker);
        _;
        vm.stopPrank();
    }

    constructor(GearStakingV3 gearStaking_, uint256 maxTimeDelta) HandlerBase(maxTimeDelta) {
        gearStaking = gearStaking_;
        gear = ERC20(gearStaking_.gear());
    }

    function addStaker(address staker) external {
        _stakers.push(staker);
    }

    function getStakers() external view returns (address[] memory) {
        return _stakers;
    }

    function addVotingContract(address votingContract) external {
        _votingContracts.push(votingContract);
    }

    function getVotingContracts() external view returns (address[] memory) {
        return _votingContracts;
    }

    function setGaugeTokens(address gauge, address[] memory tokens) external {
        _gaugeTokens[gauge] = tokens;
    }

    function getGaugeTokens(address gauge) external view returns (address[] memory) {
        return _gaugeTokens[gauge];
    }

    function getVotesCastedBy(address staker) external view returns (uint256 votesCasted) {
        for (uint256 i; i < _votingContracts.length; ++i) {
            votesCasted += _votesCasted[staker][_votingContracts[i]];
        }
    }

    function getVotesCastedFor(address votingContract) external view returns (uint256 votesCasted) {
        for (uint256 i; i < _stakers.length; ++i) {
            votesCasted += _votesCasted[_stakers[i]][votingContract];
        }
    }

    // ------- //
    // STAKING //
    // ------- //

    function deposit(Ctx memory ctx, uint256 stakerIdx, uint96 amount)
        external
        applyContext(ctx)
        withStaker(stakerIdx)
    {
        amount = uint96(bound(amount, 0, gear.balanceOf(_staker)));
        gear.approve(address(gearStaking), amount);
        gearStaking.deposit(amount, new MultiVote[](0));
    }

    function withdraw(Ctx memory ctx, uint256 stakerIdx, uint96 amount, uint256 toIdx)
        external
        applyContext(ctx)
        withStaker(stakerIdx)
    {
        amount = uint96(bound(amount, 0, gearStaking.availableBalance(_staker)));
        gearStaking.withdraw(amount, _get(_stakers, toIdx), new MultiVote[](0));
    }

    function claimWithdrawals(Ctx memory ctx, uint256 stakerIdx, uint256 toIdx)
        external
        applyContext(ctx)
        withStaker(stakerIdx)
    {
        gearStaking.claimWithdrawals(_get(_stakers, toIdx));
    }

    // ----------- //
    // MOCK VOTING //
    // ----------- //

    function vote(Ctx memory ctx, uint256 stakerIdx, uint96 amount, uint256 votingContractIdx)
        external
        applyContext(ctx)
        withStaker(stakerIdx)
    {
        address votingContract = _get(_votingContracts, votingContractIdx);
        amount = uint96(bound(amount, 0, gearStaking.availableBalance(_staker)));

        MultiVote[] memory votes = new MultiVote[](1);
        votes[0] = MultiVote(votingContract, amount, true, "");
        gearStaking.multivote(votes);

        _votesCasted[_staker][votingContract] += amount;
    }

    function unvote(Ctx memory ctx, uint256 stakerIdx, uint96 amount, uint256 votingContractIdx)
        external
        applyContext(ctx)
        withStaker(stakerIdx)
    {
        address votingContract = _get(_votingContracts, votingContractIdx);
        amount = uint96(bound(amount, 0, _votesCasted[_staker][votingContract]));

        MultiVote[] memory votes = new MultiVote[](1);
        votes[0] = MultiVote(votingContract, amount, false, "");
        gearStaking.multivote(votes);

        _votesCasted[_staker][votingContract] -= amount;
    }

    // ------------ //
    // GAUGE VOTING //
    // ------------ //

    function voteGauge(
        Ctx memory ctx,
        uint256 stakerIdx,
        uint96 amount,
        uint256 gaugeIdx,
        uint256 tokenIdx,
        bool lpSide
    ) external applyContext(ctx) withStaker(stakerIdx) {
        address gauge = _get(_votingContracts, gaugeIdx);
        address token = _get(_gaugeTokens[gauge], tokenIdx);
        amount = uint96(bound(amount, 0, gearStaking.availableBalance(_staker)));

        MultiVote[] memory votes = new MultiVote[](1);
        votes[0] = MultiVote(gauge, amount, true, abi.encode(token, lpSide));
        gearStaking.multivote(votes);

        _votesCasted[_staker][gauge] += amount;
    }

    function unvoteGauge(
        Ctx memory ctx,
        uint256 stakerIdx,
        uint96 amount,
        uint256 gaugeIdx,
        uint256 tokenIdx,
        bool lpSide
    ) external applyContext(ctx) withStaker(stakerIdx) {
        address gauge = _get(_votingContracts, gaugeIdx);
        address token = _get(_gaugeTokens[gauge], tokenIdx);
        (uint96 votesLP, uint96 votesCA) = IGaugeV3(gauge).userTokenVotes(_staker, token);
        amount = uint96(bound(amount, 0, lpSide ? votesLP : votesCA));

        MultiVote[] memory votes = new MultiVote[](1);
        votes[0] = MultiVote(gauge, amount, false, abi.encode(token, lpSide));
        gearStaking.multivote(votes);

        _votesCasted[_staker][gauge] -= amount;
    }
}
