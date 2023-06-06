// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {IVersion} from "@gearbox-protocol/core-v2/contracts/interfaces/IVersion.sol";

struct BotFunding {
    uint72 remainingFunds;
    uint72 maxWeeklyAllowance;
    uint72 remainingWeeklyAllowance;
    uint40 allowanceLU;
}

interface IBotListV3Events {
    /// @dev Emits when a borrower enables or disables a bot for their account
    event SetBotPermissions(
        address indexed creditAccount,
        address indexed bot,
        uint256 permissions,
        uint72 fundingAmount,
        uint72 weeklyFundingAllowance
    );

    /// @dev Emits when a bot is forbidden system-wide
    event SetBotForbiddenStatus(address indexed bot, bool status);

    /// @dev Emits when the user changes the amount of funds in his bot wallet
    event Deposit(address indexed payer, uint256 amount);

    /// @dev Emits when the user changes the amount of funds in his bot wallet
    event Withdraw(address indexed payer, uint256 amount);

    /// @dev Emits when the allowed weekly amount of bot's spending is changed by the user
    event ChangeBotWeeklyAllowance(address indexed payer, address indexed bot, uint72 newWeeklyAllowance);

    /// @dev Emits when the bot is paid for performed services
    event PayBot(
        address indexed payer,
        address indexed creditAccount,
        address indexed bot,
        uint72 paymentAmount,
        uint72 daoFeeAmount
    );

    /// @dev Emits when the DAO sets a new fee on bot payments
    event SetBotDAOFee(uint16 newFee);

    /// @dev Emits when all bot permissions for a Credit Account are erased
    event EraseBot(address indexed creditAccount, address indexed bot);

    /// @dev Emits when Credit Manager's status in BotList is changed
    event SetCreditManagerStatus(address indexed creditManager, bool newStatus);
}

/// @title IBotListV3
interface IBotListV3 is IBotListV3Events, IVersion {
    /// @dev Sets approval from msg.sender to bot
    function setBotPermissions(
        address creditAccount,
        address bot,
        uint192 permissions,
        uint72 fundingAmount,
        uint72 weeklyFundingAllowance
    ) external returns (uint256 remainingBots);

    /// @dev Removes permissions and funding for all bots with non-zero permissions for a credit account
    /// @param creditAccount Credit Account to erase permissions for
    function eraseAllBotPermissions(address creditAccount) external;

    /// @dev Adds funds to the borrower's bot payment wallet
    function deposit() external payable;

    /// @dev Removes funds from the borrower's bot payment wallet
    function withdraw(uint256 amount) external;

    /// @dev Takes payment for performed services from the user's balance and sends to the bot
    /// @param payer Address to charge
    /// @param creditAccount Address of the credit account paid for
    /// @param bot Address of the bot to pay
    /// @param paymentAmount Amount to pay
    function payBot(address payer, address creditAccount, address bot, uint72 paymentAmount) external;

    //
    // GETTERS
    //

    /// @dev Returns all active bots currently on the account
    function getActiveBots(address creditAccount) external view returns (address[] memory);

    /// @dev Returns whether the bot is approved by the borrower
    function botPermissions(address borrower, address bot) external view returns (uint192);

    /// @dev Returns whether the bot is forbidden by the borrower
    function forbiddenBot(address bot) external view returns (bool);

    /// @dev Returns information about bot permissions
    function getBotStatus(address bot, address creditAccount)
        external
        view
        returns (uint192 permissions, bool forbidden);

    /// @dev Returns user funcding balance in ETH
    function balanceOf(address payer) external view returns (uint256);
}
