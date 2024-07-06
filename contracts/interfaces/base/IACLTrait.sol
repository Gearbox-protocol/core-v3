// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.23;

interface IACLTrait {
    /// @notice Emitted when new external controller is set
    event NewController(address indexed newController);

    function acl() external view returns (address);
    function controller() external view returns (address);
    function setController(address) external;

    function pause() external;
    function unpause() external;
}
