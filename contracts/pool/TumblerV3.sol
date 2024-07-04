// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.23;

import {IPoolQuotaKeeperV3} from "../interfaces/IPoolQuotaKeeperV3.sol";
import {IPoolV3} from "../interfaces/IPoolV3.sol";
import {ITumblerV3} from "../interfaces/ITumblerV3.sol";

import {ACLTrait} from "../traits/ACLTrait.sol";

import "../interfaces/IExceptions.sol";

/// @title  Tumbler V3
/// @notice Extremely simplified version of `GaugeV3` contract for quota rates management, which,
///         instead of voting, allows controller to set rates directly with custom epoch length
contract TumblerV3 is ITumblerV3, ACLTrait {
    /// @notice Contract version
    uint256 public constant override version = 3_10;

    /// @notice Contract type
    bytes32 public constant override contractType = "RK_TUMBLER";

    /// @notice Quota keeper rates are provided for
    address public immutable override quotaKeeper;

    /// @notice Epoch length in seconds
    uint256 public immutable override epochLength;

    /// @dev Mapping from token to its quota rate
    mapping(address => uint16) internal _rates;

    /// @notice Constructor
    /// @param  acl_ ACL contract address
    /// @param  quotaKeeper_ Address of the quota keeper to provide rates for
    /// @param  epochLength_ Epoch length in seconds
    /// @custom:tests U:[TU-1]
    constructor(address acl_, address quotaKeeper_, uint256 epochLength_) ACLTrait(acl_) nonZeroAddress(quotaKeeper_) {
        quotaKeeper = quotaKeeper_;
        epochLength = epochLength_;
    }

    /// @notice Whether `token` is added to the tumbler
    /// @custom:tests U:[TU-2]
    function isTokenAdded(address token) public view override returns (bool) {
        return _rates[token] != 0;
    }

    /// @notice Returns rates for a given list of tokens
    /// @custom:tests U:[TU-2], U:[TU-3]
    function getRates(address[] calldata tokens) external view override returns (uint16[] memory rates) {
        uint256 len = tokens.length;
        rates = new uint16[](len);
        for (uint256 i; i < len; ++i) {
            if (!isTokenAdded(tokens[i])) revert TokenIsNotQuotedException();
            rates[i] = _rates[tokens[i]];
        }
    }

    /// @notice Adds `token` to the set of supported tokens and to the quota keeper unless it's already there,
    ///         sets its rate to `rate`
    /// @dev    Reverts if caller is not configurator
    /// @dev    Reverts if `token` is zero address, is already added, or `rate` is zero
    /// @custom:tests U:[TU-2]
    function addToken(address token, uint16 rate) external override configuratorOnly nonZeroAddress(token) {
        if (isTokenAdded(token)) revert TokenNotAllowedException();
        if (!IPoolQuotaKeeperV3(quotaKeeper).isQuotedToken(token)) {
            IPoolQuotaKeeperV3(quotaKeeper).addQuotaToken(token);
        }
        emit AddToken(token);

        _setRate(token, rate);
    }

    /// @notice Sets `token`'s rate to `rate`
    /// @dev    Reverts if caller is not controller or configurator
    /// @dev    Reverts if `token` is not added or `rate` is zero
    /// @custom:tests U:[TU-3]
    function setRate(address token, uint16 rate) external override controllerOrConfiguratorOnly {
        if (!isTokenAdded(token)) revert TokenIsNotQuotedException();
        _setRate(token, rate);
    }

    /// @notice Updates rates in the quota keeper if time passed since the last update is greater than epoch length
    /// @dev    Reverts if caller is not controller or configurator
    /// @custom:tests U:[TU-4], I:[QR-1]
    function updateRates() external override controllerOrConfiguratorOnly {
        if (block.timestamp < IPoolQuotaKeeperV3(quotaKeeper).lastQuotaRateUpdate() + epochLength) return;
        IPoolQuotaKeeperV3(quotaKeeper).updateRates();
    }

    /// @dev `setRate` implementation
    function _setRate(address token, uint16 rate) internal {
        if (rate == 0) revert IncorrectParameterException();
        if (_rates[token] == rate) return;
        _rates[token] = rate;
        emit SetRate(token, rate);
    }
}
