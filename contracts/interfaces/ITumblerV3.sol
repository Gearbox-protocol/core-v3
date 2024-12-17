// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {IACLTrait} from "./base/IACLTrait.sol";
import {IRateKeeper} from "./base/IRateKeeper.sol";

interface ITumblerV3Events {
    /// @notice Emitted when new token is added
    event AddToken(address indexed token);

    /// @notice Emitted when new quota rate is set for a token
    event SetRate(address indexed token, uint16 rate);
}

/// @title Tumbler V3 interface
interface ITumblerV3 is IRateKeeper, IACLTrait, ITumblerV3Events {
    function underlying() external view returns (address);

    function poolQuotaKeeper() external view returns (address);

    function epochLength() external view returns (uint256);

    function getTokens() external view returns (address[] memory);

    function getRates(address[] calldata tokens) external view returns (uint16[] memory);

    function setRate(address token, uint16 rate) external;

    function updateRates() external;
}
