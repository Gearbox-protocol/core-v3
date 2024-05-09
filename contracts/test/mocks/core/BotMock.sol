// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {IBot} from "../../../interfaces/IBot.sol";

contract BotMock is IBot {
    uint192 public override requiredPermissions;

    function setRequiredPermissions(uint192 permissions) external {
        requiredPermissions = permissions;
    }
}
