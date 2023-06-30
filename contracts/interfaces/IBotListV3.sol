// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
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
        address indexed creditManager,
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
    event EraseBot(address indexed creditManager, address indexed creditAccount, address indexed bot);

    /// @dev Emits when Credit Manager's status in BotList is changed
    event SetCreditManagerStatus(address indexed creditManager, bool newStatus);
}

/// @title IBotListV3
interface IBotListV3 is IBotListV3Events, IVersion {
    /// @dev Sets permissions and funding for (creditAccount, bot). Callable only through CreditFacade
    /// @param creditManager Credit Manager to set permissions in
    /// @param creditAccount CA to set permissions for
    /// @param bot Bot to set permissions for
    /// @param permissions A bit mask of permissions
    /// @param fundingAmount Total amount of ETH available to the bot for payments
    /// @param weeklyFundingAllowance Amount of ETH available to the bot weekly
    function setBotPermissions(
        address creditManager,
        address creditAccount,
        address bot,
        uint192 permissions,
        uint72 fundingAmount,
        uint72 weeklyFundingAllowance
    ) external returns (uint256 activeBotsRemaining);

    /// @notice Removes permissions and funding for all bots with non-zero permissions for a credit account
    /// @param creditManager Credit Manager to erase permissions in
    /// @param creditAccount Credit Account to erase permissions for
    function eraseAllBotPermissions(address creditManager, address creditAccount) external;

    /// @dev Adds funds to the borrower's bot payment wallet
    function deposit() external payable;

    /// @dev Removes funds from the borrower's bot payment wallet
    function withdraw(uint256 amount) external;

    /// @dev Takes payment for performed services from the user's balance and sends to the bot
    /// @param payer Address to charge
    /// @param creditManager Address of the Credit Manager where the (creditAccount, bot) pair is funded
    /// @param creditAccount Address of the Credit Account paid for
    /// @param bot Address of the bot to pay
    /// @param paymentAmount Amount to pay
    function payBot(address payer, address creditManager, address creditAccount, address bot, uint72 paymentAmount)
        external;

    //
    // GETTERS
    //

    /// @notice Returns all active bots currently on the account
    function getActiveBots(address creditManager, address creditAccount) external view returns (address[] memory);

    /// @dev Returns whether the bot is approved by the borrower
    function botPermissions(address creditManager, address borrower, address bot) external view returns (uint192);

    /// @dev Returns whether the bot is forbidden by the borrower
    function forbiddenBot(address bot) external view returns (bool);

    /// @notice Returns information about bot permissions
    function getBotStatus(address creditManager, address creditAccount, address bot)
        external
        view
        returns (uint192 permissions, bool forbidden);

    /// @dev Returns user funcding balance in ETH
    function balanceOf(address payer) external view returns (uint256);
}
