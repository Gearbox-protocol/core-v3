// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {IVersion} from "./base/IVersion.sol";

/// @notice Debt management type
///         - `INCREASE_DEBT` borrows additional funds from the pool, updates account's debt and cumulative interest index
///         - `DECREASE_DEBT` repays debt components (base interest and fees -> debt principal)
///           and updates all corresponding state variables (base interest index, debt).
///           When repaying all the debt, ensures that account has no enabled quotas.
enum ManageDebtAction {
    INCREASE_DEBT,
    DECREASE_DEBT
}

/// @notice Collateral/debt calculation mode
///         - `GENERIC_PARAMS` returns generic data like account debt and cumulative indexes
///         - `DEBT_ONLY` is same as `GENERIC_PARAMS` but includes more detailed debt info, like accrued base/quota
///           interest and fees
///         - `FULL_COLLATERAL_CHECK_LAZY` checks whether account is sufficiently collateralized in a lazy fashion,
///           i.e. it stops iterating over collateral tokens once TWV reaches the desired target.
///           Since it may return underestimated TWV, it's only available for internal use.
///         - `DEBT_COLLATERAL` is same as `DEBT_ONLY` but also returns total value and total LT-weighted value of
///           account's tokens, this mode is used during account liquidation
///         - `DEBT_COLLATERAL_SAFE_PRICES` is same as `DEBT_COLLATERAL` but uses safe prices from price oracle
enum CollateralCalcTask {
    GENERIC_PARAMS,
    DEBT_ONLY,
    FULL_COLLATERAL_CHECK_LAZY,
    DEBT_COLLATERAL,
    DEBT_COLLATERAL_SAFE_PRICES
}

struct CollateralTokenData {
    address token;
    uint16 lt;
}

struct CreditAccountInfo {
    uint256 debt;
    uint256 cumulativeIndexLastUpdate;
    uint16 flags;
    uint64 lastDebtUpdate;
    uint40 openingTimestamp;
    uint40 maturityTimestamp;
    uint40 forcedClosureTimestamp;
    address interestRateModel;
    address borrower;
    CollateralTokenData[] collateralTokens;
    address priceOracle;
}

struct CollateralDebtData {
    uint256 debt;
    uint256 cumulativeIndexNow;
    uint256 cumulativeIndexLastUpdate;
    uint16 earlyClosurePenalty;
    uint256 accruedInterest;
    uint256 accruedFees;
    uint256 totalDebtUSD;
    uint256 totalValue;
    uint256 totalValueUSD;
    uint256 twvUSD;
}

interface ICreditManagerV3Events {
    /// @notice Emitted when new credit configurator is set
    event SetCreditConfigurator(address indexed newConfigurator);
}

/// @title Credit manager V3 interface
interface ICreditManagerV3 is IVersion, ICreditManagerV3Events {
    function matchingEngine() external view returns (address);

    function underlying() external view returns (address);

    function creditFacade() external view returns (address);

    function creditConfigurator() external view returns (address);

    function accountFactory() external view returns (address);

    function name() external view returns (string memory);

    // ------------------ //
    // ACCOUNT MANAGEMENT //
    // ------------------ //

    function openCreditAccount(
        address onBehalfOf,
        address interestRateModel,
        address priceOracle,
        uint40 maturityTimestamp,
        CollateralTokenData[] calldata collateralTokens
    ) external returns (address creditAccount);

    function closeCreditAccount(address creditAccount) external;

    function forceClosure(address creditAccount) external;

    function liquidateCreditAccount(address creditAccount, CollateralDebtData calldata collateralDebtData, address to)
        external
        returns (uint256 remainingFunds, uint256 loss);

    function manageDebt(address creditAccount, uint256 amount, ManageDebtAction action)
        external
        returns (uint256 newDebt, uint256, uint256);

    function addCollateral(address payer, address creditAccount, address token, uint256 amount)
        external
        returns (uint256);

    function withdrawCollateral(address creditAccount, address token, uint256 amount, address to)
        external
        returns (uint256);

    function externalCall(address creditAccount, address target, bytes calldata callData)
        external
        returns (bytes memory result);

    function approveToken(address creditAccount, address token, address spender, uint256 amount) external;

    // -------- //
    // ADAPTERS //
    // -------- //

    function adapterToContract(address adapter) external view returns (address targetContract);

    function contractToAdapter(address targetContract) external view returns (address adapter);

    function execute(bytes calldata data) external returns (bytes memory result);

    function approveCreditAccount(address token, uint256 amount) external;

    function setActiveCreditAccount(address creditAccount) external;

    function getActiveCreditAccountOrRevert() external view returns (address creditAccount);

    // ----------------- //
    // COLLATERAL CHECKS //
    // ----------------- //

    function fullCollateralCheck(address creditAccount, uint16 minHealthFactor, bool useSafePrices) external;

    function isLiquidatable(address creditAccount, uint16 minHealthFactor) external view returns (bool);

    function calcDebtAndCollateral(address creditAccount, CollateralCalcTask task)
        external
        view
        returns (CollateralDebtData memory cdd);

    function revertIfNotAllowedCollateral(address token) external view;

    function isAllowedCollateral(address token) external view returns (bool);

    function getTokenMaskOrRevert(address token) external view returns (uint256);

    // --------------------- //
    // CREDIT MANAGER PARAMS //
    // --------------------- //

    function ltUnderlying() external view returns (uint16);

    function maxEnabledTokens() external view returns (uint8);

    function fees()
        external
        view
        returns (uint16 feeInterest, uint16 feeLiquidation, uint16 liquidationDiscount, uint16 maxEarlyClosurePenalty);

    function collateralTokensCount() external view returns (uint8);

    // ------------ //
    // ACCOUNT INFO //
    // ------------ //

    function getBorrowerOrRevert(address creditAccount) external view returns (address borrower);

    function borrowerOf(address creditAccount) external view returns (address borrower);

    function collateralTokensOf(address creditAccount) external view returns (CollateralTokenData[] memory);

    function priceOracleOf(address creditAccount) external view returns (address priceOracle);

    function earlyClosurePenaltyOf(address creditAccount) external view returns (uint16 earlyExitPenalty);

    function isAccountForceClosable(address creditAccount) external view returns (bool);

    function isAccountMature(address creditAccount) external view returns (bool);

    function liquidationThresholds(address creditAccount, address token) external view returns (uint16 lt);

    function flagsOf(address creditAccount) external view returns (uint16);

    function setFlagFor(address creditAccount, uint16 flag, bool value) external;

    function creditAccounts() external view returns (address[] memory);

    function creditAccounts(uint256 offset, uint256 limit) external view returns (address[] memory);

    function creditAccountsLen() external view returns (uint256);

    // ------------- //
    // CONFIGURATION //
    // ------------- //

    function addToken(address token) external;

    function setFees(
        uint16 feeInterest,
        uint16 feeLiquidation,
        uint16 liquidationDiscount,
        uint16 maxEarlyClosurePenalty
    ) external;

    function setContractAllowance(address adapter, address targetContract) external;

    function setCreditFacade(address creditFacade) external;

    function setCreditConfigurator(address creditConfigurator) external;
}
