// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {IVersion} from "@gearbox-protocol/core-v2/contracts/interfaces/IVersion.sol";

struct QueuedTransactionData {
    bool queued;
    address executor;
    address target;
    uint40 eta;
    string signature;
    bytes data;
    uint256 sanityCheckValue;
    bytes sanityCheckCallData;
}

interface IControllerTimelockV3Events {
    /// @notice Emitted when the veto admin of the controller is updated
    event SetVetoAdmin(address indexed newAdmin);

    /// @notice Emitted when a transaction is queued
    event QueueTransaction(
        bytes32 indexed txHash, address indexed executor, address target, string signature, bytes data, uint40 eta
    );

    /// @notice Emitted when a transaction is executed
    event ExecuteTransaction(bytes32 indexed txHash);

    /// @notice Emitted when a transaction is cancelled
    event CancelTransaction(bytes32 indexed txHash);
}

/// @title Controller timelock V3 interface
interface IControllerTimelockV3 is IControllerTimelockV3Events, IVersion {
    // -------- //
    // QUEUEING //
    // -------- //

    function setExpirationDate(address creditManager, uint40 expirationDate) external;

    function setMaxDebtPerBlockMultiplier(address creditManager, uint8 multiplier) external;

    function setMinDebtLimit(address creditManager, uint128 minDebt) external;

    function setMaxDebtLimit(address creditManager, uint128 maxDebt) external;

    function setCreditManagerDebtLimit(address creditManager, uint256 debtLimit) external;

    function rampLiquidationThreshold(
        address creditManager,
        address token,
        uint16 liquidationThresholdFinal,
        uint40 rampStart,
        uint24 rampDuration
    ) external;

    function forbidAdapter(address creditManager, address adapter) external;

    function setTotalDebtLimit(address pool, uint256 newLimit) external;

    function setTokenLimit(address pool, address token, uint96 limit) external;

    function setTokenQuotaIncreaseFee(address pool, address token, uint16 quotaIncreaseFee) external;

    function setMinQuotaRate(address pool, address token, uint16 rate) external;

    function setMaxQuotaRate(address pool, address token, uint16 rate) external;

    function setWithdrawFee(address pool, uint256 newFee) external;

    function setLPPriceFeedLimiter(address priceFeed, uint256 lowerBound) external;

    function setReservePriceFeedStatus(address priceOracle, address token, bool active) external;

    function forbidBoundsUpdate(address priceFeed) external;

    // --------- //
    // EXECUTION //
    // --------- //

    function GRACE_PERIOD() external view returns (uint256);

    function queuedTransactions(bytes32 txHash)
        external
        view
        returns (
            bool queued,
            address executor,
            address target,
            uint40 eta,
            string memory signature,
            bytes memory data,
            uint256 sanityCheckValue,
            bytes memory sanityCheckCallData
        );

    function executeTransaction(bytes32 txHash) external;

    function cancelTransaction(bytes32 txHash) external;

    // ------------- //
    // CONFIGURATION //
    // ------------- //

    function vetoAdmin() external view returns (address);

    function setVetoAdmin(address newAdmin) external;
}
