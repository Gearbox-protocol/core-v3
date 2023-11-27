// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {MultiCall} from "@gearbox-protocol/core-v2/contracts/libraries/MultiCall.sol";

import {IVersion} from "@gearbox-protocol/core-v2/contracts/interfaces/IVersion.sol";
import "./ICreditFacadeV3Multicall.sol";
import {AllowanceAction} from "../interfaces/ICreditConfiguratorV3.sol";

/// @notice Debt limits packed into a single slot
/// @param minDebt Minimum debt amount per credit account
/// @param maxDebt Maximum debt amount per credit account
struct DebtLimits {
    uint128 minDebt;
    uint128 maxDebt;
}

/// @notice Info on bad debt liquidation losses packed into a single slot
/// @param currentCumulativeLoss Current cumulative loss from bad debt liquidations
/// @param maxCumulativeLoss Max cumulative loss incurred before the facade gets paused
struct CumulativeLossParams {
    uint128 currentCumulativeLoss;
    uint128 maxCumulativeLoss;
}

/// @notice Collateral check params
/// @param collateralHints Optional array of token masks to check first to reduce the amount of computation
///        when known subset of account's collateral tokens covers all the debt
/// @param minHealthFactor Min account's health factor in bps in order not to revert
/// @param enabledTokensMaskAfter Bitmask of account's enabled collateral tokens after the multicall
/// @param revertOnForbiddenTokens Whether to revert on enabled forbidden tokens after the multicall
/// @param useSafePrices Whether to use safe pricing (min of main and reserve feeds) when evaluating collateral
struct FullCheckParams {
    uint256[] collateralHints;
    uint16 minHealthFactor;
    uint256 enabledTokensMaskAfter;
    bool revertOnForbiddenTokens;
    bool useSafePrices;
}

interface ICreditFacadeV3Events {
    /// @notice Emitted when a new credit account is opened
    event OpenCreditAccount(
        address indexed creditAccount, address indexed onBehalfOf, address indexed caller, uint256 referralCode
    );

    /// @notice Emitted when account is closed
    event CloseCreditAccount(address indexed creditAccount, address indexed borrower);

    /// @notice Emitted when account is liquidated
    event LiquidateCreditAccount(
        address indexed creditAccount, address indexed liquidator, address to, uint256 remainingFunds
    );

    /// @notice Emitted when account's debt is increased
    event IncreaseDebt(address indexed creditAccount, uint256 amount);

    /// @notice Emitted when account's debt is decreased
    event DecreaseDebt(address indexed creditAccount, uint256 amount);

    /// @notice Emitted when collateral is added to account
    event AddCollateral(address indexed creditAccount, address indexed token, uint256 amount);

    /// @notice Emitted when collateral is withdrawn from account
    event WithdrawCollateral(address indexed creditAccount, address indexed token, uint256 amount, address to);

    /// @notice Emitted when a multicall is started
    event StartMultiCall(address indexed creditAccount, address indexed caller);

    /// @notice Emitted when a call from account to an external contract is made during a multicall
    event Execute(address indexed creditAccount, address indexed targetContract);

    /// @notice Emitted when a multicall is finished
    event FinishMultiCall();
}

/// @title Credit facade V3 interface
interface ICreditFacadeV3 is IVersion, ICreditFacadeV3Events {
    function creditManager() external view returns (address);

    function degenNFT() external view returns (address);

    function weth() external view returns (address);

    function botList() external view returns (address);

    function maxDebtPerBlockMultiplier() external view returns (uint8);

    function maxQuotaMultiplier() external view returns (uint256);

    function expirable() external view returns (bool);

    function expirationDate() external view returns (uint40);

    function debtLimits() external view returns (uint128 minDebt, uint128 maxDebt);

    function lossParams() external view returns (uint128 currentCumulativeLoss, uint128 maxCumulativeLoss);

    function forbiddenTokenMask() external view returns (uint256);

    function canLiquidateWhilePaused(address) external view returns (bool);

    // ------------------ //
    // ACCOUNT MANAGEMENT //
    // ------------------ //

    function openCreditAccount(address onBehalfOf, MultiCall[] calldata calls, uint256 referralCode)
        external
        payable
        returns (address creditAccount);

    function closeCreditAccount(address creditAccount, MultiCall[] calldata calls) external payable;

    function liquidateCreditAccount(address creditAccount, address to, MultiCall[] calldata calls) external;

    function multicall(address creditAccount, MultiCall[] calldata calls) external payable;

    function botMulticall(address creditAccount, MultiCall[] calldata calls) external;

    function setBotPermissions(address creditAccount, address bot, uint192 permissions) external;

    // ------------- //
    // CONFIGURATION //
    // ------------- //

    function setExpirationDate(uint40 newExpirationDate) external;

    function setDebtLimits(uint128 newMinDebt, uint128 newMaxDebt, uint8 newMaxDebtPerBlockMultiplier) external;

    function setBotList(address newBotList) external;

    function setCumulativeLossParams(uint128 newMaxCumulativeLoss, bool resetCumulativeLoss) external;

    function setTokenAllowance(address token, AllowanceAction allowance) external;

    function setEmergencyLiquidator(address liquidator, AllowanceAction allowance) external;
}
