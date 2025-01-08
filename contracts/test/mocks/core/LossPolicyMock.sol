// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {ILossPolicy} from "../../../interfaces/base/ILossPolicy.sol";

contract LossPolicyMock is ILossPolicy {
    uint256 public constant override version = 3_10;
    bytes32 public constant override contractType = "LOSS_POLICY::MOCK";

    bool public enabled = true;

    function isLiquidatable(address, address, bytes calldata) external view override returns (bool) {
        return enabled;
    }

    function enable() external override {
        enabled = true;
    }

    function disable() external override {
        enabled = false;
    }
}
