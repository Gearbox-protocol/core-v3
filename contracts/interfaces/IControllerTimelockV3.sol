// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

struct QueuedTransactionData {
    bool queued;
    address executor;
    address target;
    uint40 eta;
    string signature;
    bytes data;
}

interface IControllerTimelockV3Events {
    /// @dev Emits when the veto admin of the controller is updated
    event SetVetoAdmin(address indexed newAdmin);

    /// @dev Emits when the delay is changed
    event SetDelay(uint256 newDelay);

    /// @dev Emits when a transaction is queued
    event QueueTransaction(
        bytes32 indexed txHash, address indexed executor, address target, string signature, bytes data, uint40 eta
    );

    /// @dev Emits when a transaction is executed
    event ExecuteTransaction(bytes32 indexed txHash);

    /// @dev Emits when a transaction is cancelled
    event CancelTransaction(bytes32 indexed txHash);
}

interface IControllerTimelockV3Errors {
    /// @dev Thrown when an address that is not the designated executor
    ///      attempts to execute a transaction
    error CallerNotExecutorException();

    /// @dev Thrown when the access-restricted function is called by other than the veto admin
    error CallerNotVetoAdminException();

    /// @dev Thrown when the new parameter values do not satisfy required conditions
    error ParameterChecksFailedException();

    /// @dev Thrown when attempting to execute a non-queued transaction
    error TxNotQueuedException();

    /// @dev Thrown when attempting to execute a transaction that is either immature or stale
    error TxExecutedOutsideTimeWindowException();

    /// @dev Thrown when execution of a transaction fails
    error TxExecutionRevertedException();
}

interface IControllerTimelockV3 is IControllerTimelockV3Errors, IControllerTimelockV3Events {
    /// @dev Queues a transaction to set a new expiration date in the Credit Facade
    /// @param creditManager Adress of CM to update the expiration date for
    /// @param expirationDate The new expiration date
    function setExpirationDate(address creditManager, uint40 expirationDate) external;

    /// @dev Queues a transaction to set a new limiter value in a price feed
    /// @param priceFeed The price feed to update the limiter in
    /// @param lowerBound The new limiter lower bound value
    function setLPPriceFeedLimiter(address priceFeed, uint256 lowerBound) external;

    /// @dev Queues a transaction to set a new max debt per block multiplier
    /// @param creditManager Adress of CM to update the multiplier for
    /// @param multiplier The new multiplier value
    function setMaxDebtPerBlockMultiplier(address creditManager, uint8 multiplier) external;

    /// @notice Queues a transaction to set a new min debt per account
    /// @dev Requires the policy for keccak(group(creditManager), "MIN_DEBT") to be enabled, otherwise auto-fails the check
    /// @param creditManager Adress of CM to update the limits for
    /// @param minDebt The new minimal debt amount
    function setMinDebtLimit(address creditManager, uint128 minDebt) external;

    /// @notice Queues a transaction to set a new max debt per account
    /// @dev Requires the policy for keccak(group(creditManager), "MAX_DEBT") to be enabled, otherwise auto-fails the check
    /// @param creditManager Adress of CM to update the limits for
    /// @param maxDebt The maximal debt amount
    function setMaxDebtLimit(address creditManager, uint128 maxDebt) external;

    /// @dev Queues a transaction to set a new debt limit for the Credit Manager
    /// @param creditManager Adress of CM to update the debt limit for
    /// @param debtLimit The new debt limit
    function setCreditManagerDebtLimit(address creditManager, uint256 debtLimit) external;

    /// @dev Queues a transaction to start a liquidation threshold ramp
    /// @param creditManager Adress of CM to update the LT for
    /// @param token Token to ramp the LT for
    /// @param liquidationThresholdFinal The liquidation threshold value after the ramp
    /// @param rampDuration Duration of the ramp
    function rampLiquidationThreshold(
        address creditManager,
        address token,
        uint16 liquidationThresholdFinal,
        uint40 rampStart,
        uint24 rampDuration
    ) external;

    /// @dev Sets the transaction's queued status as false, effectively cancelling it
    /// @param txHash Hash of the transaction to be cancelled
    function cancelTransaction(bytes32 txHash) external;

    /// @dev Executes a queued transaction
    /// @param txHash Hash of the transaction to be executed
    function executeTransaction(bytes32 txHash) external;
}
