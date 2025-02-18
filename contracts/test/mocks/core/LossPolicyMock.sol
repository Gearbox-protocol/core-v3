// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {ILossPolicy} from "../../../interfaces/base/ILossPolicy.sol";

contract LossPolicyMock is ILossPolicy {
    uint256 public constant override version = 3_10;
    bytes32 public constant override contractType = "LOSS_POLICY::MOCK";

    AccessMode public override accessMode;
    bool public override checksEnabled;

    bool public isLiquidatableResult = true;

    function serialize() external pure override returns (bytes memory) {
        return "";
    }

    function isLiquidatable(address, address, Params calldata) external view override returns (bool) {
        return isLiquidatableResult;
    }

    function setAccessMode(AccessMode mode) external override {
        accessMode = mode;
    }

    function setChecksEnabled(bool enabled) external override {
        checksEnabled = enabled;
    }

    function setIsLiquidatableResult(bool result) external {
        isLiquidatableResult = result;
    }
}
