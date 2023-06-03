// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import {IVersion} from "@gearbox-protocol/core-v2/contracts/interfaces/IVersion.sol";

struct TokenQuotaParams {
    uint16 rate; // current rate update
    uint192 cumulativeIndexLU; // max 10^57
    uint16 quotaIncreaseFee;
    uint96 totalQuoted;
    uint96 limit;
}

struct AccountQuota {
    uint96 quota;
    uint192 cumulativeIndexLU;
}

interface IPoolQuotaKeeperV3Events {
    /// @dev Emits when a quota for an account is updated
    event UpdateQuota(address indexed creditAccount, address indexed token, int96 realQuotaChange);

    /// @dev Emits when a quota for an account is updated
    event RemoveQuota(address indexed creditAccount, address indexed token);

    /// @dev Emits when the quota rate is updated
    event UpdateTokenQuotaRate(address indexed token, uint16 rate);

    /// @dev Emits when the gauge address is updated
    event SetGauge(address indexed newGauge);

    /// @dev Emits when a new Credit Manager is allowed in PoolQuotaKeeper
    event AddCreditManager(address indexed creditManager);

    /// @dev Emits when a new token added to PoolQuotaKeeper
    event NewQuotaTokenAdded(address indexed token);

    /// @dev Emits when a new limit is set for a token
    event SetTokenLimit(address indexed token, uint96 limit);

    /// @dev Emits when a new one-time quota increase fee is set
    event SetQuotaIncreaseFee(address indexed token, uint16 fee);
}

/// @title Pool Quotas Interface
interface IPoolQuotaKeeperV3 is IPoolQuotaKeeperV3Events, IVersion {
    /// @dev Updates credit account's quotas for multiple tokens
    /// @param creditAccount Address of credit account
    /// @param token Address of the token to change the quota for
    /// @param quotaChange Requested quota change in pool's underlying asset units
    function updateQuota(address creditAccount, address token, int96 quotaChange, uint96 minQuota, uint96 maxQuota)
        external
        returns (uint128 caQuotaInterestChange, uint128 tradingFees, int96 change, bool enableToken, bool disableToken);

    /// @dev Updates all quotas to zero when closing a credit account, and computes the final quota interest change
    /// @param creditAccount Address of the Credit Account being closed
    /// @param tokens Array of all active quoted tokens on the account
    function removeQuotas(address creditAccount, address[] calldata tokens, bool setLimitsToZero) external;

    /// @dev Computes the accrued quota interest and updates interest indexes
    /// @param creditAccount Address of the Credit Account to accrue interest for
    /// @param tokens Array of all active quoted tokens on the account
    function accrueQuotaInterest(address creditAccount, address[] calldata tokens) external;

    /// @dev Gauge management

    /// @dev Registers a new quoted token in the keeper
    function addQuotaToken(address token) external;

    /// @dev Batch updates the quota rates and changes the combined quota revenue
    function updateRates() external;

    //
    // GETTERS
    //

    /// @dev Returns the gauge address
    function pool() external view returns (address);

    /// @dev Returns the gauge address
    function gauge() external view returns (address);

    /// @dev Returns quota rate in PERCENTAGE FORMAT
    function getQuotaRate(address) external view returns (uint16);

    /// @dev Returns cumulative index in RAY for a quoted token. Returns 0 for non-quoted tokens.
    function cumulativeIndex(address token) external view returns (uint192);

    /// @dev Returns an array of all quoted tokens
    function quotedTokens() external view returns (address[] memory);

    /// @dev Returns whether a token is quoted
    function isQuotedToken(address token) external view returns (bool);

    /// @dev Returns quota parameters for a single (account, token) pair
    function getQuota(address creditAccount, address token)
        external
        view
        returns (uint96 quota, uint192 cumulativeIndexLU);

    /// @dev Returns the global quota-related parameters for a token
    function getTokenQuotaParams(address token)
        external
        view
        returns (uint16 rate, uint192 cumulativeIndexLU, uint16 quotaIncreaseFee, uint96 totalQuoted, uint96 limit);

    /// @dev Computes collateral value for quoted tokens on the account, as well as accrued quota interest
    function getQuotaAndOutstandingInterest(address creditAccount, address token)
        external
        view
        returns (uint96 quoted, uint128 outstandingInterest);

    /// @dev Returns the current total annual quota revenue to the pool
    function poolQuotaRevenue() external view returns (uint256);
}
