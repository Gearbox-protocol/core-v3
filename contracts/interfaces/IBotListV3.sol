// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {IVersion} from "@gearbox-protocol/core-v2/contracts/interfaces/IVersion.sol";

struct BotFunding {
    uint72 totalFundingAllowance;
    uint72 maxWeeklyAllowance;
    uint72 remainingWeeklyAllowance;
    uint40 allowanceLU;
}

struct BotSpecialStatus {
    bool forbidden;
    uint192 specialPermissions;
}

interface IBotListV3Events {
    /// @notice Emitted when credit account owner changes bot permissions and/or funding parameters
    event SetBotPermissions(
        address indexed creditManager,
        address indexed creditAccount,
        address indexed bot,
        uint256 permissions,
        uint72 totalFundingAllowance,
        uint72 weeklyFundingAllowance
    );

    /// @notice Emitted when a bot is forbidden in a Credit Manager
    event SetBotForbiddenStatus(address indexed creditManager, address indexed bot, bool status);

    /// @notice Emitted when a bot is granted special permissions in a Credit Manager
    event SetBotSpecialPermissions(address indexed creditManager, address indexed bot, uint192 permissions);

    /// @notice Emitted when the user deposits funds to their bot wallet
    event Deposit(address indexed payer, uint256 amount);

    /// @notice Emitted when the user withdraws funds from their bot wallet
    event Withdraw(address indexed payer, uint256 amount);

    /// @notice Emitted when the bot is paid for performed services
    event PayBot(
        address indexed payer,
        address indexed creditAccount,
        address indexed bot,
        uint72 paymentAmount,
        uint72 daoFeeAmount
    );

    /// @notice Emitted when the DAO sets a new fee on bot payments
    event SetBotDAOFee(uint16 newFee);

    /// @notice Emitted when all bot permissions for a Credit Account are erased
    event EraseBot(address indexed creditManager, address indexed creditAccount, address indexed bot);

    /// @notice Emitted when Credit Manager's status in the bot list is changed
    event SetCreditManagerStatus(address indexed creditManager, bool newStatus);
}

/// @title Bot list V3 interface
interface IBotListV3 is IBotListV3Events, IVersion {
    function weth() external view returns (address);

    function treasury() external view returns (address);

    // ----------- //
    // PERMISSIONS //
    // ----------- //

    function setBotPermissions(
        address creditManager,
        address creditAccount,
        address bot,
        uint192 permissions,
        uint72 totalFundingAllowance,
        uint72 weeklyFundingAllowance
    ) external returns (uint256 activeBotsRemaining);

    function eraseAllBotPermissions(address creditManager, address creditAccount) external;

    function getActiveBots(address creditManager, address creditAccount) external view returns (address[] memory);

    function botPermissions(address creditManager, address creditAccount, address bot)
        external
        view
        returns (uint192);

    function botFunding(address creditManager, address creditAccount, address bot)
        external
        view
        returns (uint72 remainingFunds, uint72 maxWeeklyAllowance, uint72 remainingWeeklyAllowance, uint40 allowanceLU);

    function getBotStatus(address creditManager, address creditAccount, address bot)
        external
        view
        returns (uint192 permissions, bool forbidden, bool hasSpecialPermissions);

    // ------- //
    // FUNDING //
    // ------- //

    function name() external view returns (string memory);

    function symbol() external view returns (string memory);

    function balanceOf(address payer) external view returns (uint256);

    function deposit() external payable;

    function withdraw(uint256 amount) external;

    function payBot(address payer, address creditManager, address creditAccount, address bot, uint72 paymentAmount)
        external;

    // ------------- //
    // CONFIGURATION //
    // ------------- //

    function daoFee() external view returns (uint16);

    function approvedCreditManager(address) external view returns (bool);

    function botSpecialStatus(address creditManager, address bot)
        external
        view
        returns (bool forbidden, uint192 specialPermissions);

    function setBotForbiddenStatus(address creditManager, address bot, bool status) external;

    function setBotForbiddenStatusEverywhere(address bot, bool status) external;

    function setBotSpecialPermissions(address creditManager, address bot, uint192 permissions) external;

    function setDAOFee(uint16 newFee) external;

    function setApprovedCreditManagerStatus(address creditManager, bool newStatus) external;
}
