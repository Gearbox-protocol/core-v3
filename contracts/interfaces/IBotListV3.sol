// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {IVersion} from "./base/IVersion.sol";

interface IBotListV3Events {
    // ----------- //
    // PERMISSIONS //
    // ----------- //

    /// @notice Emitted when new `bot`'s permissions are set for `creditAccount` in `creditManager`
    event SetBotPermissions(
        address indexed bot, address indexed creditManager, address indexed creditAccount, uint192 permissions
    );

    // ------------- //
    // CONFIGURATION //
    // ------------- //

    /// @notice Emitted when `bot` is forbidden
    event ForbidBot(address indexed bot);

    /// @notice Emitted when `creditManager` is added
    event AddCreditManager(address indexed creditManager);
}

/// @title Bot list V3 interface
interface IBotListV3 is IBotListV3Events, IVersion {
    // ----------- //
    // PERMISSIONS //
    // ----------- //

    function getActiveBots(address creditAccount) external view returns (address[] memory);

    function getBotPermissions(address bot, address creditAccount) external view returns (uint192);

    function setBotPermissions(address bot, address creditAccount, uint192 permissions) external;

    function eraseAllBotPermissions(address creditAccount) external;

    // ------------- //
    // CONFIGURATION //
    // ------------- //

    function isCreditManagerAdded(address creditManager) external view returns (bool);

    function creditManagers() external view returns (address[] memory);

    function addCreditManager(address creditManager) external;

    function isBotForbidden(address bot) external view returns (bool);

    function forbiddenBots() external view returns (address[] memory);

    function forbidBot(address bot) external;
}
