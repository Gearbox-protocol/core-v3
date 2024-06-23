// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity 0.8.23;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {
    IncorrectParameterException,
    TokenIsNotQuotedException,
    TokenNotAllowedException,
    ZeroAddressException
} from "../interfaces/IExceptions.sol";
import {IPoolQuotaKeeperV3} from "../interfaces/IPoolQuotaKeeperV3.sol";
import {IPoolV3} from "../interfaces/IPoolV3.sol";
import {ITumblerV3} from "../interfaces/ITumblerV3.sol";
import {ACLNonReentrantTrait} from "../traits/ACLNonReentrantTrait.sol";

/// @title Tumbler V3
/// @notice Extremely simplified version of `GaugeV3` contract for quota rates management, which,
///         instead of voting, allows controller to set rates directly with custom epoch length
contract TumblerV3 is ITumblerV3, ACLNonReentrantTrait {
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @notice Contract version
    uint256 public constant override version = 3_10;

    /// @notice Pool whose quota rates are set by this contract
    address public immutable override pool;

    /// @notice Pool's underlying token
    address public immutable override underlying;

    /// @notice Pool's quota keeper
    address public immutable override poolQuotaKeeper;

    /// @notice Epoch length in seconds
    uint256 public immutable override epochLength;

    /// @dev Set of all supported tokens
    EnumerableSet.AddressSet internal _tokensSet;

    /// @dev Mapping from token to its quota rate
    mapping(address => uint16) internal _rates;

    /// @notice Constructor
    /// @param acl_ ACL contract address
    /// @param pool_ Pool whose quota rates to set by this contract
    /// @param epochLength_ Epoch length in seconds
    /// @custom:tests U:[TU-1]
    constructor(address acl_, address pool_, uint256 epochLength_) ACLNonReentrantTrait(acl_) {
        pool = pool_;
        underlying = IPoolV3(pool_).underlyingToken();
        poolQuotaKeeper = IPoolV3(pool_).poolQuotaKeeper();
        epochLength = epochLength_;
    }

    /// @notice Returns all supported tokens
    /// @custom:tests U:[TU-2]
    function getTokens() external view override returns (address[] memory) {
        return _tokensSet.values();
    }

    /// @notice Returns rates for a given list of tokens
    /// @custom:tests U:[TU-2], U:[TU-3]
    function getRates(address[] calldata tokens) external view override returns (uint16[] memory rates) {
        uint256 len = tokens.length;
        rates = new uint16[](len);
        unchecked {
            for (uint256 i; i < len; ++i) {
                if (!_tokensSet.contains(tokens[i])) revert TokenIsNotQuotedException();
                rates[i] = _rates[tokens[i]];
            }
        }
    }

    /// @notice Adds `token` to the set of supported tokens and to the quota keeper unless it's already there,
    ///         sets its rate to `rate`
    /// @dev Reverts if `token` is zero address, pool's underlying or is already added
    /// @custom:tests U:[TU-2]
    function addToken(address token, uint16 rate) external override configuratorOnly nonZeroAddress(token) {
        if (token == underlying || !_tokensSet.add(token)) revert TokenNotAllowedException();
        if (!IPoolQuotaKeeperV3(poolQuotaKeeper).isQuotedToken(token)) {
            IPoolQuotaKeeperV3(poolQuotaKeeper).addQuotaToken(token);
        }
        emit AddToken(token);

        _setRate(token, rate);
    }

    /// @dev Sets `token`'s rate to `rate`
    /// @dev Reverts if `token` is not added or `rate` is zero
    /// @custom:tests U:[TU-3]
    function setRate(address token, uint16 rate) external override controllerOnly {
        if (!_tokensSet.contains(token)) revert TokenIsNotQuotedException();
        if (rate == 0) revert IncorrectParameterException();
        _setRate(token, rate);
    }

    /// @notice Updates rates in the quota keeper if time passed since the last update is greater than epoch length
    /// @custom:tests U:[TU-4], I:[QR-1]
    function updateRates() external override controllerOnly {
        if (block.timestamp < IPoolQuotaKeeperV3(poolQuotaKeeper).lastQuotaRateUpdate() + epochLength) return;
        IPoolQuotaKeeperV3(poolQuotaKeeper).updateRates();
    }

    /// @dev `setRate` implementation
    function _setRate(address token, uint16 rate) internal {
        if (_rates[token] == rate) return;
        _rates[token] = rate;
        emit SetRate(token, rate);
    }
}
