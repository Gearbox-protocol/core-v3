// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {IVersion} from "@gearbox-protocol/core-v2/contracts/interfaces/IVersion.sol";

/// @title Credit account base interface
/// @notice Functions shared accross newer and older versions
interface ICreditAccountBase is IVersion {
    function creditManager() external view returns (address);
    function safeTransfer(address token, address to, uint256 amount) external;
    function execute(address target, bytes calldata data) external returns (bytes memory result);
}

/// @title Credit account V3 interface
interface ICreditAccountV3 is ICreditAccountBase {
    function factory() external view returns (address);

    function creditManager() external view override returns (address);

    function safeTransfer(address token, address to, uint256 amount) external override;

    function execute(address target, bytes calldata data) external override returns (bytes memory result);

    function rescue(address target, bytes calldata data) external;
}
