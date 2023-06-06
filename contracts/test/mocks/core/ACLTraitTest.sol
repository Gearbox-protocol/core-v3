// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {ACLNonReentrantTrait} from "../../../traits/ACLNonReentrantTrait.sol";

/**
 * @title Pausable Trait Test
 * @notice this contract is used to test how poolOnly modifier works
 */
contract ACLNonReentrantTraitTest is ACLNonReentrantTrait {
    constructor(address addressProvider) ACLNonReentrantTrait(addressProvider) {}

    function accessWhenNotPaused() external view whenNotPaused {}

    function accessWhenPaused() external view whenPaused {}

    function accessConfiguratorOnly() external view configuratorOnly {}
}
