// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {GaugeV3Harness} from "./GaugeV3Harness.sol";
import {IGaugeV3Events, IGaugeV3, QuotaRateParams, UserVotes} from "../../../interfaces/IGaugeV3.sol";

import {IPoolQuotaKeeperV3} from "../../../interfaces/IPoolQuotaKeeperV3.sol";
import {IGearStakingV3} from "../../../interfaces/IGearStakingV3.sol";
// Mocks
import {PoolMock} from "../../mocks/pool/PoolMock.sol";
import {GearStakingMock} from "../../mocks/governance/GearStakingMock.sol";
import {GeneralMock} from "../../mocks/GeneralMock.sol";

// TEST
import "../../lib/constants.sol";

// MOCKS
import {AddressProviderV3ACLMock} from "../../mocks/core/AddressProviderV3ACLMock.sol";

// SUITES
import {TokensTestSuite} from "../../suites/TokensTestSuite.sol";
import {Tokens} from "@gearbox-protocol/sdk-gov/contracts/Tokens.sol";
import {TestHelper} from "../../lib/helper.sol";

// EXCEPTIONS
import "../../../interfaces/IExceptions.sol";

contract GauageV3UnitTest is TestHelper, IGaugeV3Events {
    address gearToken;
    address underlying;

    AddressProviderV3ACLMock public addressProvider;

    GaugeV3Harness gauge;
    PoolMock poolMock;
    GearStakingMock gearStakingMock;

    TokensTestSuite tokenTestSuite;

    address poolQuotaKeeperMock;

    function setUp() public {
        tokenTestSuite = new TokensTestSuite();

        tokenTestSuite.topUpWETH{value: 100 * WAD}();

        underlying = tokenTestSuite.addressOf(Tokens.DAI);

        vm.prank(CONFIGURATOR);
        addressProvider = new AddressProviderV3ACLMock();

        poolMock = new PoolMock(address(addressProvider), underlying);

        poolQuotaKeeperMock = address(new GeneralMock());
        poolMock.setPoolQuotaKeeper(poolQuotaKeeperMock);

        gearStakingMock = new GearStakingMock();
        gearStakingMock.setCurrentEpoch(900);

        gauge = new GaugeV3Harness(address(poolMock), address(gearStakingMock));
    }

    /// @dev U:[GA-01]: constructor sets correct values
    function test_U_GA_01_constructor_sets_correct_values() public {
        vm.expectEmit(false, false, false, true);
        emit SetFrozenEpoch(true);
        gauge = new GaugeV3Harness(address(poolMock), address(gearStakingMock));

        assertEq(gauge.pool(), address(poolMock), "Incorrect pool");
        assertEq(gauge.voter(), address(gearStakingMock), "Incorrect voter");
        assertEq(gauge.epochLastUpdate(), 900, "Incorrect epoch");
        assertTrue(gauge.epochFrozen(), "Epoch not frozen");

        vm.expectRevert(ZeroAddressException.selector);
        new GaugeV3Harness(address(poolMock), address(0));
    }

    /// @dev U:[GA-02]: voterOnly functions reverts if called by non-voter
    function test_U_GA_02_voterOnly_functions_reverts_if_called_by_non_voter() public {
        vm.expectRevert(CallerNotVoterException.selector);
        gauge.vote(DUMB_ADDRESS, 12, "");

        vm.expectRevert(CallerNotVoterException.selector);
        gauge.unvote(DUMB_ADDRESS, 12, "");
    }

    /// @dev U:[GA-03]: configuratorOnly functions reverts if called by non-configurator
    function test_U_GA_03_configuratorOnly_functions_reverts_if_called_by_non_configurator() public {
        vm.expectRevert(CallerNotConfiguratorException.selector);
        gauge.addQuotaToken(DUMB_ADDRESS, 0, 0);

        vm.expectRevert(CallerNotControllerException.selector);
        gauge.changeQuotaMinRate(DUMB_ADDRESS, 0);

        vm.expectRevert(CallerNotControllerException.selector);
        gauge.changeQuotaMaxRate(DUMB_ADDRESS, 0);
    }

    /// @dev U:[GA-04]: addQuotaToken and quota rate function revert for incorrect params
    function test_U_GA_04_addQuotaToken_reverts_for_incorrect_params() public {
        address token = DUMB_ADDRESS;
        vm.startPrank(CONFIGURATOR);

        vm.expectRevert(ZeroAddressException.selector);
        gauge.addQuotaToken(address(0), 0, 0);

        vm.expectRevert(TokenNotAllowedException.selector);
        gauge.addQuotaToken(underlying, 0, 0);

        vm.expectRevert(IncorrectParameterException.selector);
        gauge.addQuotaToken(token, 0, 0);

        vm.expectRevert(IncorrectParameterException.selector);
        gauge.addQuotaToken(token, 5, 2);

        gauge.setQuotaRateParams({token: token, minRate: 0, maxRate: 1, totalVotesLpSide: 0, totalVotesCaSide: 0});

        vm.expectRevert(TokenNotAllowedException.selector);
        gauge.addQuotaToken(token, 0, 0);

        vm.expectRevert(ZeroAddressException.selector);
        gauge.changeQuotaMinRate(address(0), 0);

        vm.expectRevert(ZeroAddressException.selector);
        gauge.changeQuotaMaxRate(address(0), 0);

        vm.expectRevert(IncorrectParameterException.selector);
        gauge.changeQuotaMinRate(token, 0);

        vm.expectRevert(IncorrectParameterException.selector);
        gauge.changeQuotaMaxRate(token, 0);

        vm.expectRevert(IncorrectParameterException.selector);
        gauge.changeQuotaMinRate(token, 5);

        vm.stopPrank();
    }

    /// @dev U:[GA-05]: addQuotaToken works as expected
    function test_U_GA_05_addQuotaToken_works_as_expected() public {
        address token = makeAddr("TOKEN");
        uint16 minRate = 100;
        uint16 maxRate = 500;

        address poolQuotaKeeper = address(new GeneralMock());

        poolMock.setPoolQuotaKeeper(poolQuotaKeeper);

        vm.mockCall(poolQuotaKeeper, abi.encodeCall(IPoolQuotaKeeperV3.isQuotedToken, (token)), abi.encode(false));
        vm.expectCall(poolQuotaKeeper, abi.encodeCall(IPoolQuotaKeeperV3.addQuotaToken, (token)));

        vm.expectEmit(true, true, false, true);
        emit AddQuotaToken({token: token, minRate: minRate, maxRate: maxRate});

        vm.prank(CONFIGURATOR);
        gauge.addQuotaToken(token, minRate, maxRate);

        (uint16 _minRate, uint16 _maxRate, uint96 totalVotesLpSide, uint96 totalVotesCaSide) =
            gauge.quotaRateParams(token);

        assertEq(_minRate, minRate, "Incorrect minRate");
        assertEq(_maxRate, maxRate, "Incorrect maxRate");

        assertEq(totalVotesLpSide, 0, "Incorrect totalVotesLpSide");
        assertEq(totalVotesCaSide, 0, "Incorrect totalVotesCaSide");

        // must not try to add token to quota keeper in case it's already quoted
        address token2 = makeAddr("TOKEN2");

        vm.mockCall(poolQuotaKeeper, abi.encodeCall(IPoolQuotaKeeperV3.isQuotedToken, (token2)), abi.encode(true));
        vm.mockCallRevert(
            poolQuotaKeeper, abi.encodeCall(IPoolQuotaKeeperV3.addQuotaToken, (token2)), "should not be called"
        );

        vm.prank(CONFIGURATOR);
        gauge.addQuotaToken(token2, minRate, maxRate);
    }

    /// @dev U:[GA-06A]: changeQuotaMinRate works as expected
    function test_U_GA_06A_changeQuotaMinRate_works_as_expected() public {
        address token = makeAddr("TOKEN");
        uint16 minRate = 100;

        // Case: it reverts if token is not added before
        vm.expectRevert(TokenNotAllowedException.selector);
        vm.prank(CONFIGURATOR);
        gauge.changeQuotaMinRate(token, minRate);

        // Case: it updates rates only if token added

        uint96 totalVotesLpSide = 9323;
        uint96 totalVotesCaSide = 12323;

        gauge.setQuotaRateParams({
            token: token,
            minRate: minRate + 1312,
            maxRate: 2000,
            totalVotesLpSide: totalVotesLpSide,
            totalVotesCaSide: totalVotesCaSide
        });

        vm.expectEmit(true, true, false, true);
        emit SetQuotaTokenParams({token: token, minRate: minRate, maxRate: 2000});

        vm.prank(CONFIGURATOR);
        gauge.changeQuotaMinRate(token, minRate);

        (uint16 _minRate,,,) = gauge.quotaRateParams(token);

        assertEq(_minRate, minRate, "Incorrect minRate");
    }

    /// @dev U:[GA-06B]: changeQuotaMaxRate works as expected
    function test_U_GA_06B_changeQuotaMaxRate_works_as_expected() public {
        address token = makeAddr("TOKEN");
        uint16 maxRate = 3000;

        // Case: it reverts if token is not added before
        vm.expectRevert(TokenNotAllowedException.selector);
        vm.prank(CONFIGURATOR);
        gauge.changeQuotaMaxRate(token, maxRate);

        // Case: it updates rates only if token added

        uint96 totalVotesLpSide = 9323;
        uint96 totalVotesCaSide = 12323;

        gauge.setQuotaRateParams({
            token: token,
            minRate: 500,
            maxRate: maxRate + 1000,
            totalVotesLpSide: totalVotesLpSide,
            totalVotesCaSide: totalVotesCaSide
        });

        vm.expectEmit(true, true, false, true);
        emit SetQuotaTokenParams({token: token, minRate: 500, maxRate: maxRate});

        vm.prank(CONFIGURATOR);
        gauge.changeQuotaMaxRate(token, maxRate);

        (, uint16 _maxRate,,) = gauge.quotaRateParams(token);

        assertEq(_maxRate, maxRate, "Incorrect maxRate");
    }

    /// @dev U:[GA-08]: isTokenAdded works as expected
    function test_U_GA_08_isTokenAdded_works_as_expected() public {
        address token = makeAddr("TOKEN");

        gauge.setQuotaRateParams({token: token, minRate: 0, maxRate: 0, totalVotesLpSide: 0, totalVotesCaSide: 0});

        assertEq(gauge.isTokenAdded(token), false, "token incorrectly added");

        gauge.setQuotaRateParams({token: token, minRate: 0, maxRate: 1, totalVotesLpSide: 0, totalVotesCaSide: 0});

        assertEq(gauge.isTokenAdded(token), true, "token incorrectly not added");
    }

    //
    // VOTE AND UNVOTE WORKS CORRECTLY
    //

    // @dev U:[GA-10]: vote and unvote reverts in token isn't added
    function test_U_GA_10_vote_and_unvote_reverts_in_token_isnt_added() public {
        vm.startPrank(address(gearStakingMock));
        vm.expectRevert(TokenNotAllowedException.selector);
        gauge.vote(USER, 122, abi.encode(DUMB_ADDRESS, true));

        vm.expectRevert(TokenNotAllowedException.selector);
        gauge.unvote(USER, 122, abi.encode(DUMB_ADDRESS, true));

        vm.stopPrank();
    }

    // @dev U:[GA-11]: vote and unvote checks and updates epoch
    function test_U_GA_11_vote_unvote_and_updates_epoch() public {
        address token = makeAddr("TOKEN");

        gauge.setQuotaRateParams({
            token: token,
            minRate: 1,
            maxRate: 10_000,
            totalVotesLpSide: 200,
            totalVotesCaSide: 200
        });

        vm.startPrank(address(gearStakingMock));

        for (uint16 i = 0; i < 2; ++i) {
            gearStakingMock.setCurrentEpoch(i + 1000);
            bytes memory voteData = abi.encode(token, true);

            vm.expectCall(address(gearStakingMock), abi.encodeCall(IGearStakingV3.getCurrentEpoch, ()));

            if (i == 0) {
                gauge.vote(USER, 2, voteData);
            } else {
                gauge.unvote(USER, 2, voteData);
            }
        }
        vm.stopPrank();
    }

    // @dev U:[GA-12]: vote correctly updates votes
    function test_U_GA_12_vote_correctly_updates_votes(uint96 votes) public {
        vm.assume(votes < type(uint96).max - 200);

        address token = makeAddr("TOKEN");

        gauge.setQuotaRateParams({
            token: token,
            minRate: 1,
            maxRate: 10_000,
            totalVotesLpSide: 200,
            totalVotesCaSide: 200
        });

        vm.prank(address(gearStakingMock));

        bool lpSide = getHash(votes, 22) % 2 == 1;

        vm.expectEmit(true, true, false, true);
        emit Vote(USER, token, votes, lpSide);

        gauge.vote(USER, votes, abi.encode(token, lpSide));

        (,, uint96 totalVotesLpSide, uint96 totalVotesCaSide) = gauge.quotaRateParams(token);

        assertEq(totalVotesLpSide, 200 + (lpSide ? votes : 0), "Incorrect quotaRateParams totalVotesLpSide update");
        assertEq(totalVotesCaSide, 200 + (lpSide ? 0 : votes), "Incorrect quotaRateParams totalVotesCaSide update");

        (uint96 votesLpSide, uint96 votesCaSide) = gauge.userTokenVotes(USER, token);
        assertEq(votesLpSide, (lpSide ? votes : 0), "Incorrect userTokenVotes votesLpSide update");
        assertEq(votesCaSide, (lpSide ? 0 : votes), "Incorrect userTokenVotes votesCaSide update");
    }

    // @dev U:[GA-13]: unvote correctly updates votes
    function test_U_GA_13_unvote_correctly_updates_votes(uint96 votes) public {
        address token = makeAddr("TOKEN");

        uint96 totalVotesLpSide = votes;
        uint96 userLPVotes = totalVotesLpSide / uint96(getHash(votes, 3) % 5 + 1);

        uint96 totalVotesCaSide = uint96(getHash(votes, 5));
        uint96 userCaVotes = totalVotesCaSide / uint96(getHash(votes, 6) % 5 + 1);

        bool lpSide = getHash(votes, 32) % 5 == 0;

        uint96 unvote = uint96((lpSide ? userLPVotes : userCaVotes) * uint256(getHash(votes, 4) % 5) / 5);

        gauge.setQuotaRateParams({
            token: token,
            minRate: 1,
            maxRate: 10_000,
            totalVotesLpSide: totalVotesLpSide,
            totalVotesCaSide: totalVotesCaSide
        });

        gauge.setUserTokenVotes(USER, token, userLPVotes, userCaVotes);

        vm.prank(address(gearStakingMock));

        vm.expectEmit(true, true, false, true);
        emit Unvote(USER, token, unvote, lpSide);

        gauge.unvote(USER, unvote, abi.encode(token, lpSide));

        (,, uint96 _totalVotesLpSide, uint96 _totalVotesCaSide) = gauge.quotaRateParams(token);

        assertEq(
            _totalVotesLpSide,
            totalVotesLpSide - (lpSide ? unvote : 0),
            "Incorrect quotaRateParams totalVotesLpSide update"
        );
        assertEq(
            _totalVotesCaSide,
            totalVotesCaSide - (lpSide ? 0 : unvote),
            "Incorrect quotaRateParams totalVotesCaSide update"
        );

        (uint96 votesLpSide, uint96 votesCaSide) = gauge.userTokenVotes(USER, token);
        assertEq(votesLpSide, userLPVotes - (lpSide ? unvote : 0), "Incorrect userTokenVotes votesLpSide update");
        assertEq(votesCaSide, userCaVotes - (lpSide ? 0 : unvote), "Incorrect userTokenVotes votesCaSide update");
    }

    // @dev U:[GA-14]: updateEpoch updates epoch
    function test_U_GA_14_updateEpoch_updates_epoch() public {
        vm.prank(CONFIGURATOR);
        gauge.setFrozenEpoch(false);

        for (uint16 i = 0; i < 2; ++i) {
            uint16 epochNow = i + gauge.epochLastUpdate();

            gearStakingMock.setCurrentEpoch(epochNow);
            vm.expectCall(address(gearStakingMock), abi.encodeCall(IGearStakingV3.getCurrentEpoch, ()));

            if (i != 0) {
                vm.expectCall(address(poolQuotaKeeperMock), abi.encodeCall(IPoolQuotaKeeperV3.updateRates, ()));

                vm.expectEmit(false, false, false, true);
                emit UpdateEpoch(epochNow);
            }

            gauge.updateEpoch();

            assertEq(epochNow, gauge.epochLastUpdate(), "Incorrect epochLastUpdate");
        }
    }

    // @dev U:[GA-15]: updateEpoch updates epoch
    function test_U_GA_15_updateEpoch_updates_epoch() public {
        address link = makeAddr("LINK");
        address pepe = makeAddr("PEPE");
        address inch = makeAddr("INCH");

        gauge.setQuotaRateParams({
            token: link,
            minRate: 100,
            maxRate: 500,
            totalVotesLpSide: 4_000,
            totalVotesCaSide: 6_000
        });

        gauge.setQuotaRateParams({
            token: pepe,
            minRate: 1088,
            maxRate: 5233,
            totalVotesLpSide: 0,
            totalVotesCaSide: 6_000
        });

        gauge.setQuotaRateParams({token: inch, minRate: 19, maxRate: 50_001, totalVotesLpSide: 0, totalVotesCaSide: 0});

        uint16[] memory rates = gauge.getRates(arrayOf(link));
        assertEq(_copyU16toU256(rates), arrayOf((6_000 * 100 + 500 * 4_000) / 10_000), "Incorrect rates for link");

        rates = gauge.getRates(arrayOf(pepe, link));
        assertEq(
            _copyU16toU256(rates),
            arrayOf(1088, (6_000 * 100 + 500 * 4_000) / 10_000),
            "Incorrect rates for [pepe, link]"
        );

        rates = gauge.getRates(arrayOf(inch, pepe, link));
        assertEq(
            _copyU16toU256(rates),
            arrayOf(19, 1088, (6_000 * 100 + 500 * 4_000) / 10_000),
            "Incorrect rates for [inch, pepe, link]"
        );

        vm.expectRevert(TokenNotAllowedException.selector);
        gauge.getRates(arrayOf(inch, pepe, link, DUMB_ADDRESS));
    }

    /// @dev U:[GA-16]: updateEpoch does not update epoch and rates if `epochFrozen` is true
    function test_U_GA_16_updateEpoch_respects_frozen_epoch() public {
        vm.prank(CONFIGURATOR);
        gauge.setFrozenEpoch(false);

        gauge.updateEpoch();

        assertEq(gauge.epochLastUpdate(), 900);

        vm.expectEmit(false, false, false, true);
        emit SetFrozenEpoch(true);

        vm.prank(CONFIGURATOR);
        gauge.setFrozenEpoch(true);

        assertTrue(gauge.epochFrozen(), "Epoch was not frozen");

        gearStakingMock.setCurrentEpoch(1000);
        vm.mockCallRevert(
            address(poolQuotaKeeperMock), abi.encodeCall(IPoolQuotaKeeperV3.updateRates, ()), "should not be called"
        );

        gauge.updateEpoch();

        assertEq(gauge.epochLastUpdate(), 1000);
    }
}
