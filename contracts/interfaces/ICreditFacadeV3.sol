// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {AllowanceAction} from "./ICreditConfiguratorV3.sol";
import "./ICreditFacadeV3Multicall.sol";
import {PriceUpdate} from "./IPriceOracleV3.sol";
import {IACLTrait} from "./base/IACLTrait.sol";
import {IVersion} from "./base/IVersion.sol";

/// @notice Multicall element
/// @param target Call target, which is either credit facade or adapter
/// @param callData Call data
struct MultiCall {
    address target;
    bytes callData;
}

/// @notice Debt limits packed into a single slot
/// @param minDebt Minimum debt amount per credit account
/// @param maxDebt Maximum debt amount per credit account
struct DebtLimits {
    uint128 minDebt;
    uint128 maxDebt;
}

/// @notice Collateral check params
/// @param collateralHints Optional array of token masks to check first to reduce the amount of computation
///        when known subset of account's collateral tokens covers all the debt
/// @param minHealthFactor Min account's health factor in bps in order not to revert
struct FullCheckParams {
    uint256[] collateralHints;
    uint16 minHealthFactor;
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

    /// @notice Emitted when account is partially liquidated
    event PartiallyLiquidateCreditAccount(
        address indexed creditAccount,
        address indexed token,
        address indexed liquidator,
        uint256 repaidDebt,
        uint256 seizedCollateral,
        uint256 fee
    );

    /// @notice Emitted when collateral is added to account
    event AddCollateral(address indexed creditAccount, address indexed token, uint256 amount);

    /// @notice Emitted when collateral is withdrawn from account
    event WithdrawCollateral(address indexed creditAccount, address indexed token, uint256 amount, address to);

    /// @notice Emitted when a multicall is started
    event StartMultiCall(address indexed creditAccount, address indexed caller);

    /// @notice Emitted when phantom token is withdrawn by account
    event WithdrawPhantomToken(address indexed creditAccount, address indexed token, uint256 amount);

    /// @notice Emitted when a call from account to an external contract is made during a multicall
    event Execute(address indexed creditAccount, address indexed targetContract);

    /// @notice Emitted when a multicall is finished
    event FinishMultiCall();
}

/// @title Credit facade V3 interface
interface ICreditFacadeV3 is IVersion, IACLTrait, ICreditFacadeV3Events {
    function creditManager() external view returns (address);

    function underlying() external view returns (address);

    function treasury() external view returns (address);

    function degenNFT() external view returns (address);

    function weth() external view returns (address);

    function botList() external view returns (address);

    function maxDebtPerBlockMultiplier() external view returns (uint8);

    function maxQuotaMultiplier() external view returns (uint256);

    function expirable() external view returns (bool);

    function expirationDate() external view returns (uint40);

    function debtLimits() external view returns (uint128 minDebt, uint128 maxDebt);

    function lossLiquidator() external view returns (address);

    function forbiddenTokenMask() external view returns (uint256);

    // ------------------ //
    // ACCOUNT MANAGEMENT //
    // ------------------ //

    function openCreditAccount(address onBehalfOf, MultiCall[] calldata calls, uint256 referralCode)
        external
        payable
        returns (address creditAccount);

    function closeCreditAccount(address creditAccount, MultiCall[] calldata calls) external payable;

    function liquidateCreditAccount(address creditAccount, address to, MultiCall[] calldata calls)
        external
        returns (uint256 reportedLoss);

    function partiallyLiquidateCreditAccount(
        address creditAccount,
        address token,
        uint256 repaidAmount,
        uint256 minSeizedAmount,
        address to,
        PriceUpdate[] calldata priceUpdates
    ) external returns (uint256 seizedAmount);

    function multicall(address creditAccount, MultiCall[] calldata calls) external payable;

    function botMulticall(address creditAccount, MultiCall[] calldata calls) external;

    // ------------- //
    // CONFIGURATION //
    // ------------- //

    function setExpirationDate(uint40 newExpirationDate) external;

    function setDebtLimits(uint128 newMinDebt, uint128 newMaxDebt, uint8 newMaxDebtPerBlockMultiplier) external;

    function setLossLiquidator(address newLossLiquidator) external;

    function setTokenAllowance(address token, AllowanceAction allowance) external;

    function pause() external;

    function unpause() external;
}
