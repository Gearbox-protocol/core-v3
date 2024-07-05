// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.23;

import {IGaugeV3, QuotaRateParams, UserTokenVotes} from "../interfaces/IGaugeV3.sol";
import {IGearStakingV3} from "../interfaces/IGearStakingV3.sol";
import {IPoolQuotaKeeperV3} from "../interfaces/IPoolQuotaKeeperV3.sol";

import {EPOCH_LENGTH} from "../libraries/Constants.sol";

import {ACLTrait} from "../traits/ACLTrait.sol";

import "../interfaces/IExceptions.sol";

/// @title  Gauge V3
/// @notice In Gearbox V3, quota rates are determined by GEAR holders that vote to move the rate within a given range.
///         While there are notable mechanic differences, the overall idea of token holders controlling strategy yield
///         is similar to the Curve's gauge system, and thus the contract carries the same name.
///         For each token, there are two parameters: minimum rate determined by the risk committee, and maximum rate
///         determined by the Gearbox DAO. GEAR holders then vote either for CA side, which moves the rate towards min,
///         or for LP side, which moves it towards max.
///         Rates are only updated once per epoch (1 week), to avoid manipulation and make strategies more predictable.
contract GaugeV3 is IGaugeV3, ACLTrait {
    /// @notice Contract version
    uint256 public constant override version = 3_10;

    /// @notice Contract type
    bytes32 public constant override contractType = "RK_GAUGE";

    /// @notice Quota keeper rates are provided for
    address public immutable override quotaKeeper;

    /// @dev Mapping from token address to its rate parameters
    mapping(address => QuotaRateParams) internal _quotaRateParams;

    /// @dev Mapping from (user, token) to vote amounts submitted by user for each side
    mapping(address => mapping(address => UserTokenVotes)) internal _userTokenVotes;

    /// @notice GEAR staking and voting contract
    address public immutable override voter;

    /// @notice Epoch when the rates were last updated
    uint16 public override epochLastUpdate;

    /// @notice Whether gauge is frozen and rates cannot be updated
    bool public override epochFrozen;

    /// @dev Ensures that function caller is voter
    modifier onlyVoter() {
        _revertIfCallerNotVoter();
        _;
    }

    /// @notice Constructor
    /// @param  acl_ ACL contract address
    /// @param  quotaKeeper_ Address of the quota keeper to provide rates for
    /// @param  gearStaking_ Address of the GEAR staking contract
    /// @dev    Reverts if any of `quotaKeeper_` or `gearStaking_` is zero address
    /// @custom:tests U:[GA-1]
    constructor(address acl_, address quotaKeeper_, address gearStaking_)
        ACLTrait(acl_)
        nonZeroAddress(quotaKeeper_)
        nonZeroAddress(gearStaking_)
    {
        quotaKeeper = quotaKeeper_;
        voter = gearStaking_;
        epochLastUpdate = _getCurrentEpoch();
        epochFrozen = true;
        emit SetFrozenEpoch(true);
    }

    /// @notice Returns `token`'s quota rate params
    function quotaRateParams(address token) external view override returns (QuotaRateParams memory) {
        return _quotaRateParams[token];
    }

    /// @notice Returns `user`'s votes for `token`'s LP and CA sides
    function userTokenVotes(address user, address token) external view override returns (UserTokenVotes memory) {
        return _userTokenVotes[user][token];
    }

    /// @notice Whether token is added to the gauge as quoted
    /// @custom:tests U:[GA-8]
    function isTokenAdded(address token) public view override returns (bool) {
        return _quotaRateParams[token].maxRate != 0;
    }

    /// @notice Updates the epoch and, unless frozen, rates in the quota keeper
    /// @custom:tests U:[GA-14], U:[GA-16]
    function updateEpoch() public override {
        uint16 epochNow = _getCurrentEpoch();
        if (epochNow > epochLastUpdate) {
            epochLastUpdate = epochNow;
            if (!epochFrozen) {
                // quota keeper should callback `getRates`
                IPoolQuotaKeeperV3(quotaKeeper).updateRates();
            }
            emit UpdateEpoch(epochNow);
        }
    }

    /// @notice Returns time before the next update of rates
    /// @custom:tests U:[GA-14], U:[GA-16]
    function getTimeBeforeUpdate() external view override returns (uint256) {
        if (epochFrozen) return type(uint256).max;
        if (_getCurrentEpoch() > epochLastUpdate) return 0;
        return EPOCH_LENGTH - (block.timestamp - IGearStakingV3(voter).firstEpochTimestamp()) % EPOCH_LENGTH;
    }

    /// @notice Computes rates for an array of tokens based on the current votes
    /// @param  tokens Array of tokens to computes rates for
    /// @return rates Array of rates, in the same order as passed tokens
    /// @dev    Reverts if `tokens` contains unrecognized tokens
    /// @custom:tests U:[GA-15]
    function getRates(address[] calldata tokens) external view override returns (uint16[] memory rates) {
        uint256 len = tokens.length;
        rates = new uint16[](len);

        unchecked {
            for (uint256 i; i < len; ++i) {
                address token = tokens[i];
                if (!isTokenAdded(token)) revert TokenIsNotQuotedException();

                // unchecked arithmetics below is safe because of short data types
                QuotaRateParams memory qrp = _quotaRateParams[token];
                uint256 votesLpSide = qrp.totalVotesLpSide;
                uint256 votesCaSide = qrp.totalVotesCaSide;
                uint256 totalVotes = votesLpSide + votesCaSide;
                // cast is safe since rate is between `minRate` and `maxRate`, both of which are `uint16`
                rates[i] = totalVotes == 0
                    ? qrp.minRate
                    : uint16((qrp.minRate * votesCaSide + qrp.maxRate * votesLpSide) / totalVotes);
            }
        }
    }

    /// @notice Submits user's votes for the provided token and side and updates the epoch if necessary
    /// @param  user The user that submitted votes
    /// @param  votes Amount of votes to submit
    /// @param  extraData Gauge specific parameters (encoded into `extraData` to adhere to the voting contract interface)
    ///         * `token` - address of the token to vote for
    ///         * `lpSide` - whether the side to add votes for is the LP side
    /// @dev    Reverts if caller is not the voter contract
    /// @dev    Reverts if `token` is not added
    /// @custom:tests U:[GA-2], U:[GA-10], U:[GA-11], U:[GA-12]
    function vote(address user, uint96 votes, bytes calldata extraData) external override onlyVoter {
        (address token, bool lpSide) = abi.decode(extraData, (address, bool));
        if (!isTokenAdded(token)) revert TokenIsNotQuotedException();

        updateEpoch();

        QuotaRateParams storage qrp = _quotaRateParams[token];
        UserTokenVotes storage utv = _userTokenVotes[user][token];

        if (lpSide) {
            qrp.totalVotesLpSide += votes;
            utv.votesLpSide += votes;
        } else {
            qrp.totalVotesCaSide += votes;
            utv.votesCaSide += votes;
        }

        emit Vote({user: user, token: token, votes: votes, lpSide: lpSide});
    }

    /// @notice Removes user's existing votes for the provided token and side and updates the epoch if necessary
    /// @param  user The user that submitted votes
    /// @param  votes Amount of votes to remove
    /// @param  extraData Gauge specific parameters (encoded into `extraData` to adhere to the voting contract interface)
    ///         * `token` - address of the token to unvote for
    ///         * `lpSide` - whether the side to remove votes for is the LP side
    /// @dev    Reverts if caller is not the voter contract
    /// @dev    Reverts if `token` is not added
    /// @dev    Reverts if trying to remove more votes than previously submitted
    /// @custom:tests U:[GA-2], U:[GA-10], U:[GA-11], U:[GA-13]
    function unvote(address user, uint96 votes, bytes calldata extraData) external override onlyVoter {
        (address token, bool lpSide) = abi.decode(extraData, (address, bool));
        if (!isTokenAdded(token)) revert TokenIsNotQuotedException();

        updateEpoch();

        QuotaRateParams storage qrp = _quotaRateParams[token];
        UserTokenVotes storage utv = _userTokenVotes[user][token];

        if (lpSide) {
            if (utv.votesLpSide < votes) revert InsufficientVotesException();
            unchecked {
                qrp.totalVotesLpSide -= votes;
                utv.votesLpSide -= votes;
            }
        } else {
            if (utv.votesCaSide < votes) revert InsufficientVotesException();
            unchecked {
                qrp.totalVotesCaSide -= votes;
                utv.votesCaSide -= votes;
            }
        }

        emit Unvote({user: user, token: token, votes: votes, lpSide: lpSide});
    }

    // ------------- //
    // CONFIGURATION //
    // ------------- //

    /// @notice Sets the frozen epoch status.
    ///         The epoch can be frozen to prevent rate updates during gauge/staking contracts migration.
    /// @param  status The new status
    /// @dev    Reverts if caller is not configurator
    function setFrozenEpoch(bool status) external override configuratorOnly {
        if (status != epochFrozen) {
            epochFrozen = status;
            emit SetFrozenEpoch(status);
        }
    }

    /// @notice Adds `token` to the set of supported tokens and to the quota keeper unless it's already there,
    ///         sets its min and rates to `minRate` and `maxRate` respectively
    /// @param  token Address of the token to add
    /// @param  minRate The minimal interest rate paid on token's quotas
    /// @param  maxRate The maximal interest rate paid on token's quotas
    /// @dev    Reverts if caller is not configurator
    /// @dev    Reverts if `token` is zero address or already added
    /// @dev    Reverts if `minRate` is zero or greater than `maxRate`
    /// @custom:tests U:[GA-3], U:[GA-4], U:[GA-5]
    function addQuotaToken(address token, uint16 minRate, uint16 maxRate)
        external
        override
        nonZeroAddress(token)
        configuratorOnly
    {
        if (isTokenAdded(token)) revert TokenNotAllowedException();
        _checkParams({minRate: minRate, maxRate: maxRate});
        _quotaRateParams[token] =
            QuotaRateParams({minRate: minRate, maxRate: maxRate, totalVotesLpSide: 0, totalVotesCaSide: 0});
        if (!IPoolQuotaKeeperV3(quotaKeeper).isQuotedToken(token)) {
            IPoolQuotaKeeperV3(quotaKeeper).addQuotaToken(token);
        }
        emit AddQuotaToken({token: token, minRate: minRate, maxRate: maxRate});
    }

    /// @notice Changes the min rate for a quoted token
    /// @param  token Token to change the min rate for
    /// @param  minRate The minimal interest rate paid on token's quotas
    /// @dev    Reverts if caller is not controller or configurator
    /// @dev    Reverts if `token` is not added
    /// @dev    Reverts if `minRate` is zero or greater than the current max rate
    /// @custom:tests U:[GA-3], U:[GA-4] U:[GA-6A]
    function changeQuotaMinRate(address token, uint16 minRate) external override controllerOrConfiguratorOnly {
        _changeQuotaTokenRateParams(token, minRate, _quotaRateParams[token].maxRate);
    }

    /// @notice Changes the max rate for a quoted token
    /// @param  token Token to change the max rate for
    /// @param  maxRate The maximal interest rate paid on token's quotas
    /// @dev    Reverts if caller is not controller or configurator
    /// @dev    Reverts if `token` is not added
    /// @dev    Reverts if `maxRate` is less than the current min rate
    /// @custom:tests U:[GA-3], U:[GA-4] U:[GA-6B]
    function changeQuotaMaxRate(address token, uint16 maxRate) external override controllerOrConfiguratorOnly {
        _changeQuotaTokenRateParams(token, _quotaRateParams[token].minRate, maxRate);
    }

    /// @dev Implementation of `changeQuotaMinRate` and `changeQuotaMaxRate`
    function _changeQuotaTokenRateParams(address token, uint16 minRate, uint16 maxRate) internal {
        if (!isTokenAdded(token)) revert TokenIsNotQuotedException();
        _checkParams(minRate, maxRate);

        QuotaRateParams storage qrp = _quotaRateParams[token];
        if (minRate == qrp.minRate && maxRate == qrp.maxRate) return;
        qrp.minRate = minRate;
        qrp.maxRate = maxRate;

        emit SetQuotaTokenParams({token: token, minRate: minRate, maxRate: maxRate});
    }

    // --------- //
    // INTERNALS //
    // --------- //

    /// @dev Checks that given min and max rate are correct (`0 < minRate <= maxRate`)
    function _checkParams(uint16 minRate, uint16 maxRate) internal pure {
        if (minRate == 0 || minRate > maxRate) revert IncorrectParameterException();
    }

    /// @dev Reverts if `msg.sender` is not voter
    function _revertIfCallerNotVoter() internal view {
        if (msg.sender != voter) revert CallerNotVoterException();
    }

    /// @dev Internal wrapper for `voter.getCurrentEpoch` call to reduce contract size
    function _getCurrentEpoch() internal view returns (uint16) {
        return IGearStakingV3(voter).getCurrentEpoch();
    }
}
