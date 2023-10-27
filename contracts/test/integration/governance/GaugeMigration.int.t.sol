// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {Test} from "forge-std/Test.sol";

import {PoolV3} from "../../../pool/PoolV3.sol";
import {GaugeV3} from "../../../governance/GaugeV3.sol";
import {EPOCH_LENGTH, GearStakingV3, MultiVote, VotingContractStatus} from "../../../governance/GearStakingV3.sol";
import {PoolQuotaKeeperV3} from "../../../pool/PoolQuotaKeeperV3.sol";

import {CallerNotGaugeException} from "../../../interfaces/IExceptions.sol";

import {PoolMock} from "../../mocks/pool/PoolMock.sol";
import {ERC20Mock} from "../../mocks/token/ERC20Mock.sol";
import {AP_GEAR_TOKEN, AddressProviderV3ACLMock} from "../../mocks/core/AddressProviderV3ACLMock.sol";

/// @title Gauge migration integration test
/// @notice I:[GAM]: Tests that ensure that gauges can be migrated properly
contract GaugeMigrationIntegrationTest is Test {
    address user1;
    address user2;
    address configurator;

    ERC20Mock gear;
    ERC20Mock underlying;
    ERC20Mock token1;
    ERC20Mock token2;

    AddressProviderV3ACLMock addressProvider;
    PoolMock pool;
    GaugeV3 gauge;
    GearStakingV3 staking;
    PoolQuotaKeeperV3 quotaKeeper;

    function setUp() public {
        // create accounts
        user1 = makeAddr("USER1");
        user2 = makeAddr("USER2");
        configurator = makeAddr("CONFIGURATOR");

        // deploy tokens
        gear = new ERC20Mock("Gearbox", "GEAR", 18);
        underlying = new ERC20Mock("Test Token 0", "TEST0", 18);
        token1 = new ERC20Mock("Test Token 1", "TEST1", 18);
        token2 = new ERC20Mock("Test Token 2", "TEST2", 18);

        vm.startPrank(configurator);
        // deploy address provider, staking and pool
        addressProvider = new AddressProviderV3ACLMock();
        addressProvider.setAddress(AP_GEAR_TOKEN, address(gear), false);
        staking = new GearStakingV3(address(addressProvider), block.timestamp);
        pool = new PoolMock(address(addressProvider), address(underlying));

        // deploy quota keeper and connect it to the pool
        quotaKeeper = new PoolQuotaKeeperV3(address(pool));
        pool.setPoolQuotaKeeper(address(quotaKeeper));

        // deploy gauge and connect it to the quota keeper and staking
        gauge = new GaugeV3(address(pool), address(staking));
        staking.setVotingContractStatus(address(gauge), VotingContractStatus.ALLOWED);
        quotaKeeper.setGauge(address(gauge));

        // add tokens to the gauge
        gauge.addQuotaToken({token: address(token1), minRate: 600, maxRate: 3000});
        gauge.addQuotaToken({token: address(token2), minRate: 400, maxRate: 2000});
        vm.stopPrank();

        // do some voting
        deal({token: address(gear), to: user1, give: 1_000_000e18});
        deal({token: address(gear), to: user2, give: 2_000_000e18});

        vm.startPrank(user1);
        gear.approve(address(staking), 1_000_000e18);
        staking.deposit(
            1_000_000e18,
            _multiVote(
                _vote(address(gauge), address(token1), 500_000e18, false),
                _vote(address(gauge), address(token2), 500_000e18, false)
            )
        );
        vm.stopPrank();

        vm.startPrank(user2);
        gear.approve(address(staking), 2_000_000e18);
        staking.deposit(2_000_000e18, _multiVote(_vote(address(gauge), address(token1), 1_000_000e18, true)));
        vm.stopPrank();

        // unfreeze gauge
        vm.prank(configurator);
        gauge.setFrozenEpoch(false);

        // wait for the next epoch and update rates
        skip(EPOCH_LENGTH);
        gauge.updateEpoch();

        // validate correctness
        assertEq(quotaKeeper.getQuotaRate(address(token1)), 2200, "Incorrect token1 rate");
        assertEq(quotaKeeper.getQuotaRate(address(token2)), 400, "Incorrect token2 rate");
    }

    /// @notice I:[GAM-1]: Gauge migration works as expected
    function test_I_GAM_01_gauge_migration_works_as_expected() public {
        // prepare a new gauge and disable an old one
        vm.startPrank(configurator);
        GaugeV3 newGauge = new GaugeV3(address(pool), address(staking));

        staking.setVotingContractStatus(address(newGauge), VotingContractStatus.ALLOWED);
        staking.setVotingContractStatus(address(gauge), VotingContractStatus.UNVOTE_ONLY);

        quotaKeeper.setGauge(address(newGauge));
        newGauge.addQuotaToken({token: address(token1), minRate: 600, maxRate: 3000});
        newGauge.addQuotaToken({token: address(token2), minRate: 400, maxRate: 2000});
        vm.stopPrank();

        // users move their votes to the new gauge
        vm.prank(user1);
        staking.multivote(
            _multiVote(
                _unvote(address(gauge), address(token1), 500_000e18, false),
                _unvote(address(gauge), address(token2), 500_000e18, false),
                _vote(address(newGauge), address(token1), 500_000e18, false),
                _vote(address(newGauge), address(token2), 500_000e18, false)
            )
        );

        vm.prank(user2);
        staking.multivote(
            _multiVote(
                _unvote(address(gauge), address(token1), 1_000_000e18, true),
                _vote(address(newGauge), address(token1), 1_000_000e18, true),
                // inject an extra vote to change rates
                _vote(address(newGauge), address(token2), 500_000e18, true)
            )
        );

        // both gauges can't be used to update rates at this stage
        skip(EPOCH_LENGTH);

        vm.mockCallRevert(
            address(quotaKeeper), abi.encodeCall(PoolQuotaKeeperV3.updateRates, ()), "updateRates should not be called"
        );
        newGauge.updateEpoch();
        vm.clearMockedCalls();

        vm.expectRevert(CallerNotGaugeException.selector);
        gauge.updateEpoch();

        // unfreeze gauge
        vm.prank(configurator);
        newGauge.setFrozenEpoch(false);

        // wait for the next epoch and update rates
        skip(EPOCH_LENGTH);
        newGauge.updateEpoch();

        // validate correctness
        assertEq(quotaKeeper.getQuotaRate(address(token1)), 2200, "Incorrect token1 rate");
        assertEq(quotaKeeper.getQuotaRate(address(token2)), 1200, "Incorrect token2 rate");

        // check that new gauge can be used to add tokens to quota keeper
        vm.prank(configurator);
        newGauge.addQuotaToken(makeAddr("TOKEN"), 1, 2);
    }

    /// @notice I:[GAM-2]: Gauge and staking migration works as expected
    function test_I_GAM_02_gaude_and_staking_migration_works_as_expected() public {
        // prepare new staking and gauge contracts
        vm.startPrank(configurator);
        GearStakingV3 newStaking = new GearStakingV3(address(addressProvider), block.timestamp);
        GaugeV3 newGauge = new GaugeV3(address(pool), address(newStaking));

        newStaking.setMigrator(address(staking));
        staking.setSuccessor(address(newStaking));

        staking.setVotingContractStatus(address(gauge), VotingContractStatus.UNVOTE_ONLY);
        newStaking.setVotingContractStatus(address(newGauge), VotingContractStatus.ALLOWED);

        quotaKeeper.setGauge(address(newGauge));
        newGauge.addQuotaToken({token: address(token1), minRate: 600, maxRate: 3000});
        newGauge.addQuotaToken({token: address(token2), minRate: 400, maxRate: 2000});
        vm.stopPrank();

        // users move their votes to the new gauge
        vm.prank(user1);
        staking.migrate(
            1_000_000e18,
            _multiVote(
                _unvote(address(gauge), address(token1), 500_000e18, false),
                _unvote(address(gauge), address(token2), 500_000e18, false)
            ),
            _multiVote(
                _vote(address(newGauge), address(token1), 500_000e18, false),
                _vote(address(newGauge), address(token2), 500_000e18, false)
            )
        );

        vm.prank(user2);
        staking.migrate(
            2_000_000e18,
            _multiVote(_unvote(address(gauge), address(token1), 1_000_000e18, true)),
            _multiVote(
                _vote(address(newGauge), address(token1), 1_000_000e18, true),
                // inject an extra vote to change rates
                _vote(address(newGauge), address(token2), 500_000e18, true)
            )
        );

        // both gauges can't be used to update rates at this stage
        skip(EPOCH_LENGTH);

        vm.mockCallRevert(
            address(quotaKeeper), abi.encodeCall(PoolQuotaKeeperV3.updateRates, ()), "updateRates should not be called"
        );
        newGauge.updateEpoch();
        vm.clearMockedCalls();

        vm.expectRevert(CallerNotGaugeException.selector);
        gauge.updateEpoch();

        // unfreeze gauge
        vm.prank(configurator);
        newGauge.setFrozenEpoch(false);

        // wait for the next epoch and update rates
        skip(EPOCH_LENGTH);
        newGauge.updateEpoch();

        // validate correctness
        assertEq(quotaKeeper.getQuotaRate(address(token1)), 2200, "Incorrect token1 rate");
        assertEq(quotaKeeper.getQuotaRate(address(token2)), 1200, "Incorrect token2 rate");

        // check that new gauge can be used to add tokens to quota keeper
        vm.prank(configurator);
        newGauge.addQuotaToken(makeAddr("TOKEN"), 1, 2);
    }

    // --------- //
    // INTERNALS //
    // --------- //

    function _vote(address gauge_, address token, uint96 amount, bool lpSide)
        internal
        pure
        returns (MultiVote memory)
    {
        return MultiVote({
            votingContract: gauge_,
            voteAmount: amount,
            isIncrease: true,
            extraData: abi.encode(token, lpSide)
        });
    }

    function _unvote(address gauge_, address token, uint96 amount, bool lpSide)
        internal
        pure
        returns (MultiVote memory)
    {
        return MultiVote({
            votingContract: gauge_,
            voteAmount: amount,
            isIncrease: false,
            extraData: abi.encode(token, lpSide)
        });
    }

    function _multiVote(MultiVote memory vote0) internal pure returns (MultiVote[] memory votes) {
        votes = new MultiVote[](1);
        votes[0] = vote0;
    }

    function _multiVote(MultiVote memory vote0, MultiVote memory vote1)
        internal
        pure
        returns (MultiVote[] memory votes)
    {
        votes = new MultiVote[](2);
        votes[0] = vote0;
        votes[1] = vote1;
    }

    function _multiVote(MultiVote memory vote0, MultiVote memory vote1, MultiVote memory vote2)
        internal
        pure
        returns (MultiVote[] memory votes)
    {
        votes = new MultiVote[](3);
        votes[0] = vote0;
        votes[1] = vote1;
        votes[2] = vote2;
    }

    function _multiVote(MultiVote memory vote0, MultiVote memory vote1, MultiVote memory vote2, MultiVote memory vote3)
        internal
        pure
        returns (MultiVote[] memory votes)
    {
        votes = new MultiVote[](4);
        votes[0] = vote0;
        votes[1] = vote1;
        votes[2] = vote2;
        votes[3] = vote3;
    }
}
