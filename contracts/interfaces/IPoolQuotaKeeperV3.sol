// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.23;

import {IACLTrait} from "./base/IACLTrait.sol";
import {IContractsRegisterTrait} from "../interfaces/base/IContractsRegisterTrait.sol";
import {IVersion} from "./base/IVersion.sol";

struct TokenQuotaParams {
    uint16 rate;
    uint192 cumulativeIndexLU;
    uint16 quotaIncreaseFee;
    uint96 totalQuoted;
    uint96 limit;
}

struct AccountQuota {
    uint96 quota;
    uint192 cumulativeIndexLU;
}

/// @title Pool quota keeper V3 interface
interface IPoolQuotaKeeperV3 is IACLTrait, IContractsRegisterTrait, IVersion {
    // ------ //
    // EVENTS //
    // ------ //

    /// @notice Emitted when account's quota for a token is updated
    event UpdateQuota(address indexed creditAccount, address indexed token, int96 quotaChange);

    /// @notice Emitted when token's quota rate is updated
    event UpdateTokenQuotaRate(address indexed token, uint16 rate);

    /// @notice Emitted when the gauge is updated
    event SetGauge(address indexed newGauge);

    /// @notice Emitted when a new credit manager is allowed
    event AddCreditManager(address indexed creditManager);

    /// @notice Emitted when a new token is added as quoted
    event AddQuotaToken(address indexed token);

    /// @notice Emitted when a new total quota limit is set for a token
    event SetTokenLimit(address indexed token, uint96 limit);

    /// @notice Emitted when a new one-time quota increase fee is set for a token
    event SetQuotaIncreaseFee(address indexed token, uint16 fee);

    // ------- //
    // GETTERS //
    // ------- //

    function pool() external view returns (address);
    function underlying() external view returns (address);
    function gauge() external view returns (address);

    function isCreditManagerAdded(address creditManager) external view returns (bool);
    function creditManagers() external view returns (address[] memory);

    function isQuotedToken(address token) external view returns (bool);
    function quotedTokens() external view returns (address[] memory);

    function tokenQuotaParams(address token) external view returns (TokenQuotaParams memory);
    function accountQuotas(address creditAccount, address token) external view returns (AccountQuota memory);
    function lastQuotaRateUpdate() external view returns (uint40);

    function getQuotaAndOutstandingInterest(address creditAccount, address token)
        external
        view
        returns (uint96 quoted, uint128 outstandingInterest);

    // ----------------- //
    // QUOTAS MANAGEMENT //
    // ----------------- //

    function updateQuota(address creditAccount, address token, int96 quotaChange, uint96 minQuota, uint96 maxQuota)
        external
        returns (uint128 outstandingInterest, uint128 fees, bool enableToken, bool disableToken);

    function removeQuotas(address creditAccount, address[] calldata tokens, bool setLimitsToZero) external;

    function accrueQuotaInterest(address creditAccount, address[] calldata tokens) external;

    // ------------- //
    // CONFIGURATION //
    // ------------- //

    function setGauge(address newGauge) external;

    function addCreditManager(address creditManager) external;

    function addQuotaToken(address token) external;

    function updateRates() external;

    function setTokenLimit(address token, uint96 limit) external;

    function setTokenQuotaIncreaseFee(address token, uint16 fee) external;
}
