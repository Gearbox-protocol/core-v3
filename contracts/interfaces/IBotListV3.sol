// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {IVersion} from "@gearbox-protocol/core-v2/contracts/interfaces/IVersion.sol";

/// @notice Bot funding params
struct BotFunding {
    uint72 totalFundingAllowance;
    uint72 maxWeeklyAllowance;
    uint72 remainingWeeklyAllowance;
    uint40 lastAllowanceUpdate;
}

/// @notice Bot info
/// @param forbidden Whether bot is forbidden
/// @param specialPermissions Mapping credit manager => bot's special permissions
/// @param permissions Mapping credit manager => credit account => bot's permissions
/// @param funding Mapping credit manager => credit account => bot's funding params
struct BotInfo {
    bool forbidden;
    mapping(address => uint192) specialPermissions;
    mapping(address => mapping(address => uint192)) permissions;
    mapping(address => mapping(address => BotFunding)) funding;
}

interface IBotListV3Events {
    // ----------- //
    // PERMISSIONS //
    // ----------- //

    /// @notice Emitted when new `bot`'s permissions and funding params are set for `creditAccount` in `creditManager`
    event SetBotPermissions(
        address indexed bot,
        address indexed creditManager,
        address indexed creditAccount,
        uint192 permissions,
        uint72 totalFundingAllowance,
        uint72 weeklyFundingAllowance
    );

    /// @notice Emitted when `bot`'s permissions and funding params are removed for `creditAccount` in `creditManager`
    event EraseBot(address indexed bot, address indexed creditManager, address indexed creditAccount);

    // -------- //
    // PAYMENTS //
    // -------- //

    /// @notice Emitted when `bot` is paid for operation on `creditAccount` in `creditManager`
    event PayBot(
        address indexed bot,
        address indexed creditManager,
        address indexed creditAccount,
        address payer,
        uint72 paymentAmount,
        uint72 feeAmount
    );

    /// @notice Emitted when `account` deposits funds to their funding balance
    event Deposit(address indexed account, uint256 amount);

    /// @notice Emitted when `account` withdraws funds from their funding balance
    event Withdraw(address indexed account, uint256 amount);

    /// @notice Emitted when collected payment fees are transferred to the treasury
    event TransferCollectedPaymentFees(uint256 amount);

    // ------------- //
    // CONFIGURATION //
    // ------------- //

    /// @notice Emitted when `bot`'s forbidden status is set
    event SetBotForbiddenStatus(address indexed bot, bool forbidden);

    /// @notice Emitted when `bot`'s special permissions in `creditManager` are set
    event SetBotSpecialPermissions(address indexed bot, address indexed creditManager, uint192 permissions);

    /// @notice Emitted when new fee on bot payments is set
    event SetPaymentFee(uint16 newPaymentFee);

    /// @notice Emitted when `creditManager`'s approved status is set
    event SetCreditManagerApprovedStatus(address indexed creditManager, bool approved);
}

/// @title Bot list V3 interface
interface IBotListV3 is IBotListV3Events, IVersion {
    function weth() external view returns (address);

    function treasury() external view returns (address);

    // ----------- //
    // PERMISSIONS //
    // ----------- //

    function botPermissions(address bot, address creditManager, address creditAccount)
        external
        view
        returns (uint192);

    function botFunding(address bot, address creditManager, address creditAccount)
        external
        view
        returns (BotFunding memory);

    function activeBots(address creditManager, address creditAccount) external view returns (address[] memory);

    function getBotStatus(address bot, address creditManager, address creditAccount)
        external
        view
        returns (uint192 permissions, bool forbidden, bool hasSpecialPermissions);

    function setBotPermissions(
        address bot,
        address creditManager,
        address creditAccount,
        uint192 permissions,
        uint72 totalFundingAllowance,
        uint72 weeklyFundingAllowance
    ) external returns (uint256 activeBotsRemaining);

    function eraseAllBotPermissions(address creditManager, address creditAccount) external;

    // -------- //
    // PAYMENTS //
    // -------- //

    function name() external view returns (string memory);

    function symbol() external view returns (string memory);

    function balanceOf(address payer) external view returns (uint256);

    function collectedPaymentFees() external view returns (uint64);

    function payBot(address bot, address creditManager, address creditAccount, address payer, uint72 paymentAmount)
        external;

    function deposit() external payable;

    function withdraw(uint256 amount) external;

    function transferCollectedPaymentFees() external;

    // ------------- //
    // CONFIGURATION //
    // ------------- //

    function botForbiddenStatus(address bot) external view returns (bool);

    function botSpecialPermissions(address bot, address creditManager) external view returns (uint192);

    function paymentFee() external view returns (uint16);

    function approvedCreditManager(address creditManager) external view returns (bool);

    function setBotForbiddenStatus(address bot, bool forbidden) external;

    function setBotSpecialPermissions(address bot, address creditManager, uint192 permissions) external;

    function setPaymentFee(uint16 newPaymentFee) external;

    function setCreditManagerApprovedStatus(address creditManager, bool approved) external;
}
