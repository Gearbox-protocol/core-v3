// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.10;

struct QueuedTransactionData {
    bool queued;
    address target;
    uint40 eta;
    string signature;
    bytes data;
}

interface IControllerTimelockEvents {
    /// @dev Emits when the risk admin of the controller is updated
    event SetRiskAdmin(address indexed newAdmin);

    /// @dev Emits when the ops admin of the controller is updated
    event SetOpsAdmin(address indexed newAdmin);

    /// @dev Emits when the veto admin of the controller is updated
    event SetVetoAdmin(address indexed newAdmin);

    /// @dev Emits when the risk admin transaction delay is changed
    event SetRiskAdminDelay(uint256 newDelay);

    /// @dev Emits when the ops admin transaction delay is changed
    event SetOpsAdminDelay(uint256 newDelay);

    /// @dev Emits when a transaction is queued
    event QueueTransaction(bytes32 indexed txHash, address target, string signature, bytes data, uint40 eta);

    /// @dev Emits when a transaction is executed
    event ExecuteTransaction(bytes32 indexed txHash);

    /// @dev Emits when a transaction is cancelled
    event CancelTransaction(bytes32 indexed txHash);
}

interface IControllerTimelockErrors {
    /// @dev Thrown when the access-restricted function is called by other than the required admin
    error CallerNotCorrectAdminException();

    /// @dev Thrown when the new parameter values do not satisfy required conditions
    error ParameterChecksFailedException();

    /// @dev Thrown when attempting to execute a non-queued transaction
    error TxNotQueuedException();

    /// @dev Thrown when attempting to execute a transaction that is either immature or stale
    error TxExecutedOutsideTimeWindowException();

    /// @dev Thrown when execution of a transaction fails
    error TxExecutionRevertedException();
}

interface IControllerTimelock is IControllerTimelockErrors, IControllerTimelockEvents {
    /// @dev Queues a transaction to set a new expiration date in the Credit Facade
    /// @param expirationDate The new expiration date
    function setExpirationDate(uint40 expirationDate) external;

    /// @dev Queues a transaction to set a new limiter value in a price feed
    /// @param priceFeed The price feed to update the limiter in
    /// @param lowerBound The new limiter lower bound value
    function setLPPriceFeedLimiter(address priceFeed, uint256 lowerBound) external;

    /// @dev Queues a transaction to set a new max debt per block multiplier
    /// @param multiplier The new multiplier value
    function setMaxDebtPerBlockMultiplier(uint8 multiplier) external;

    /// @dev Queues a transaction to set a new max debt per block multiplier
    /// @param minDebt The minimal debt amount
    /// @param maxDebt The maximal debt amount
    function setDebtLimits(uint128 minDebt, uint128 maxDebt) external;

    /// @dev Queues a transaction to set a new debt limit for the Credit Manager
    /// @param debtLimit The new debt limit
    function setCreditManagerDebtLimit(uint256 debtLimit) external;

    /// @dev Queues a transaction to start a liquidation threshold ramp
    /// @param token Token to ramp the LT for
    /// @param liquidationThresholdFinal The liquidation threshold value after the ramp
    /// @param rampDuration Duration of the ramp
    function rampLiquidationThreshold(address token, uint16 liquidationThresholdFinal, uint24 rampDuration) external;

    /// @dev Sets the transaction's queued status as false, effectively cancelling it
    /// @param txHash Hash of the transaction to be cancelled
    function cancelTransaction(bytes32 txHash) external;

    /// @dev Executes a queued transaction
    /// @param txHash Hash of the transaction to be executed
    function executeTransaction(bytes32 txHash) external;
}
