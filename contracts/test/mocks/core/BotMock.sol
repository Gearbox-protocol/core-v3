// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {IBotV3} from "../../../interfaces/IBotV3.sol";

contract BotMock is IBotV3 {
    uint192 public override requiredPermissions;

    function setRequiredPermissions(uint192 permissions) external {
        requiredPermissions = permissions;
    }
}
