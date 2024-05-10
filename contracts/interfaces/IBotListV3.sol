// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {IVersion} from "./base/IVersion.sol";

/// @notice Bot info
/// @param forbidden Whether bot is forbidden
/// @param permissions Mapping credit manager => credit account => bot's permissions
struct BotInfo {
    bool forbidden;
    mapping(address => mapping(address => uint192)) permissions;
}

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

    /// @notice Emitted when `bot`'s forbidden status is set
    event SetBotForbiddenStatus(address indexed bot, bool forbidden);

    /// @notice Emitted when `creditManager`'s approved status is set
    event SetCreditManagerApprovedStatus(address indexed creditManager, bool approved);
}

/// @title Bot list V3 interface
interface IBotListV3 is IBotListV3Events, IVersion {
    // ----------- //
    // PERMISSIONS //
    // ----------- //

    function botPermissions(address bot, address creditAccount) external view returns (uint192);

    function activeBots(address creditAccount) external view returns (address[] memory);

    function getBotStatus(address bot, address creditAccount)
        external
        view
        returns (uint192 permissions, bool forbidden);

    function setBotPermissions(address bot, address creditAccount, uint192 permissions)
        external
        returns (uint256 activeBotsRemaining);

    function eraseAllBotPermissions(address creditAccount) external;

    // ------------- //
    // CONFIGURATION //
    // ------------- //

    function botForbiddenStatus(address bot) external view returns (bool);

    function approvedCreditManager(address creditManager) external view returns (bool);

    function setBotForbiddenStatus(address bot, bool forbidden) external;

    function setCreditManagerApprovedStatus(address creditManager, bool approved) external;
}
