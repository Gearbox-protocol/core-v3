// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {IVersion} from "@gearbox-protocol/core-v2/contracts/interfaces/IVersion.sol";

struct QuotaRate {
    address token;
    uint16 rate;
}

interface IRateKeeperV3Events {
    /// @notice Emitted when new quoted token is added
    event AddQuotedToken(address indexed token);

    /// @notice Emitted when new quota rate is set for a token
    event SetQuotaRate(address indexed token, uint16 rate);
}

/// @title Rate keeper V3 interface
interface IRateKeeperV3 is IVersion, IRateKeeperV3Events {
    function pool() external view returns (address);

    function underlying() external view returns (address);

    function poolQuotaKeeper() external view returns (address);

    function getQuotedTokens() external view returns (address[] memory);

    function getRates(address[] calldata tokens) external view returns (uint16[] memory);

    function setQuotaRates(QuotaRate[] calldata rates) external;
}
