// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.23;

import {IBot} from "../../../interfaces/base/IBot.sol";

contract BotMock is IBot {
    uint256 public constant version = 3_10;
    bytes32 public constant contractType = "BOT_MOCK";

    uint192 public override requiredPermissions;

    function setRequiredPermissions(uint192 permissions) external {
        requiredPermissions = permissions;
    }
}
