// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.23;

import {IACLTrait} from "./IACLTrait.sol";

interface IControlledTrait is IACLTrait {
    /// @notice Emitted when new external controller is set
    event NewController(address indexed newController);

    function controller() external view returns (address);
    function setController(address) external;
}
