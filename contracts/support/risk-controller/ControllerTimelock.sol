// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import {PolicyManager} from "./PolicyManager.sol";

import {IControllerTimelock, QueuedTransactionData} from "../../interfaces/IControllerTimelock.sol";

import {ICreditManagerV3} from "../../interfaces/ICreditManagerV3.sol";

import {ICreditFacade} from "../../interfaces/ICreditFacade.sol";
import {IPoolV3} from "../../interfaces/IPoolV3.sol";
import {ILPPriceFeed} from "../../interfaces/ILPPriceFeed.sol";

/// @dev
contract ControllerTimelock is PolicyManager, IControllerTimelock {
    /// @dev Period before a mature transaction becomes stale
    uint256 public constant GRACE_PERIOD = 14 days;

    /// @dev Admin address that can schedule controller transactions
    address public admin;

    /// @dev Admin address that can cancel transactions
    address public vetoAdmin;

    /// @dev Delay before a risk-related transaction can be executed
    uint256 public delay = 1 days;

    /// @dev Mapping of transaction hashes to their data
    mapping(bytes32 => QueuedTransactionData) public queuedTransactions;

    constructor(address _addressProvider, address _admin, address _vetoAdmin) PolicyManager(_addressProvider) {
        admin = _admin;
        vetoAdmin = _vetoAdmin;
    }

    modifier adminOnly() {
        if (msg.sender != admin) {
            revert CallerNotAdminException();
        }
        _;
    }

    modifier vetoAdminOnly() {
        if (msg.sender != vetoAdmin) {
            revert CallerNotVetoAdminException();
        }
        _;
    }

    /// @notice Queues a transaction to set a new expiration date in the Credit Facade
    /// @dev Requires the policy for keccak(group(creditManager), "EXPIRATION_DATE") to be enabled, otherwise auto-fails the check
    /// @param creditManager Adress of CM to update the expiration date for
    /// @param expirationDate The new expiration date
    function setExpirationDate(address creditManager, uint40 expirationDate)
        external
        adminOnly // F: [RCT-01]
    {
        ICreditFacade creditFacade = ICreditFacade(ICreditManagerV3(creditManager).creditFacade());
        address creditConfigurator = ICreditManagerV3(creditManager).creditConfigurator();
        IPoolV3 pool = IPoolV3(ICreditManagerV3(creditManager).pool());

        uint40 oldExpirationDate = creditFacade.expirationDate();
        uint256 totalBorrowed = pool.creditManagerBorrowed(address(creditManager));

        if (
            !_checkPolicy(creditManager, "EXPIRATION_DATE", uint256(oldExpirationDate), uint256(expirationDate))
                || totalBorrowed != 0
        ) {
            revert ParameterChecksFailedException(); // F: [RCT-01]
        }

        _queueTransaction({
            target: creditConfigurator,
            signature: "setExpirationDate(uint40)",
            data: abi.encode(expirationDate)
        }); // F: [RCT-01]
    }

    /// @notice Queues a transaction to set a new limiter value in a price feed
    /// @dev Requires the policy for keccak(group(priceFeed), "LP_PRICE_FEED_LIMITER") to be enabled, otherwise auto-fails the check
    /// @param priceFeed The price feed to update the limiter in
    /// @param lowerBound The new limiter lower bound value
    function setLPPriceFeedLimiter(address priceFeed, uint256 lowerBound)
        external
        adminOnly // F: [RCT-02]
    {
        uint256 currentLowerBound = ILPPriceFeed(priceFeed).lowerBound();

        if (!_checkPolicy(priceFeed, "LP_PRICE_FEED_LIMITER", currentLowerBound, lowerBound)) {
            revert ParameterChecksFailedException(); // F: [RCT-02]
        }

        _queueTransaction({target: priceFeed, signature: "setLimiter(uint256)", data: abi.encode(lowerBound)}); // F: [RCT-02]
    }

    /// @notice Queues a transaction to set a new max debt per block multiplier
    /// @dev Requires the policy for keccak(group(creditManager), "MAX_DEBT_PER_BLOCK_MULTIPLIER") to be enabled, otherwise auto-fails the check
    /// @param creditManager Adress of CM to update the multiplier for
    /// @param multiplier The new multiplier value
    function setMaxDebtPerBlockMultiplier(address creditManager, uint8 multiplier)
        external
        adminOnly // F: [RCT-03]
    {
        ICreditFacade creditFacade = ICreditFacade(ICreditManagerV3(creditManager).creditFacade());
        address creditConfigurator = ICreditManagerV3(creditManager).creditConfigurator();

        uint8 currentMultiplier = creditFacade.maxDebtPerBlockMultiplier();

        if (
            !_checkPolicy(
                creditManager, "MAX_DEBT_PER_BLOCK_MULTIPLIER", uint256(currentMultiplier), uint256(multiplier)
            )
        ) {
            revert ParameterChecksFailedException(); // F: [RCT-03]
        }

        _queueTransaction({
            target: creditConfigurator,
            signature: "setMaxDebtPerBlockMultiplier(uint8)",
            data: abi.encode(multiplier)
        }); // F: [RCT-03]
    }

    /// @notice Queues a transaction to set a new max debt per block multiplier
    /// @dev Requires policies for keccak(group(creditManager), "MIN_DEBT") and keccak(group(creditManager), "MAX_DEBT") to be enabled, otherwise auto-fails the check
    /// @param creditManager Adress of CM to update the limits for
    /// @param minDebt The minimal debt amount
    /// @param maxDebt The maximal debt amount
    function setDebtLimits(address creditManager, uint128 minDebt, uint128 maxDebt)
        external
        adminOnly // F: [RCT-04]
    {
        ICreditFacade creditFacade = ICreditFacade(ICreditManagerV3(creditManager).creditFacade());
        address creditConfigurator = ICreditManagerV3(creditManager).creditConfigurator();

        (uint128 minDebtCurrent, uint128 maxDebtCurrent) = creditFacade.debtLimits();

        if (
            !_checkPolicy(creditManager, "MIN_DEBT", uint256(minDebtCurrent), uint256(minDebt))
                || !_checkPolicy(creditManager, "MAX_DEBT", uint256(maxDebtCurrent), uint256(maxDebt))
        ) {
            revert ParameterChecksFailedException(); // F: [RCT-04]
        }

        _queueTransaction({
            target: creditConfigurator,
            signature: "setLimits(uint128,uint128)",
            data: abi.encode(minDebt, maxDebt)
        }); // F: [RCT-04]
    }

    /// @notice Queues a transaction to set a new debt limit for a Credit Manager
    /// @dev Requires the policy for keccak(group(creditManager), "CREDIT_MANAGER_DEBT_LIMIT") to be enabled, otherwise auto-fails the check
    /// @param creditManager Adress of CM to update the debt limit for
    /// @param debtLimit The new debt limit
    function setCreditManagerDebtLimit(address creditManager, uint256 debtLimit)
        external
        adminOnly // F: [RCT-05]
    {
        IPoolV3 pool = IPoolV3(ICreditManagerV3(creditManager).pool());

        uint256 debtLimitCurrent = pool.creditManagerLimit(address(creditManager));

        if (!_checkPolicy(creditManager, "CREDIT_MANAGER_DEBT_LIMIT", uint256(debtLimitCurrent), uint256(debtLimit))) {
            revert ParameterChecksFailedException(); // F: [RCT-05]
        }

        _queueTransaction({
            target: address(pool),
            signature: "setCreditManagerLimit(address,uint256)",
            data: abi.encode(address(creditManager), debtLimit)
        }); // F: [RCT-05]
    }

    /// @notice Queues a transaction to start a liquidation threshold ramp
    /// @dev Requires the policy for keccak(group(contractManager), group(token), "TOKEN_LT") to be enabled, otherwise auto-fails the check
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
    )
        external
        adminOnly // F: [RCT-06]
    {
        bytes32 policyHash = keccak256(abi.encode(_group[creditManager], _group[token], "TOKEN_LT"));

        address creditConfigurator = ICreditManagerV3(creditManager).creditConfigurator();
        uint256 ltCurrent = ICreditManagerV3(creditManager).liquidationThresholds(token);

        if (
            !_checkPolicy(policyHash, uint256(ltCurrent), uint256(liquidationThresholdFinal)) || rampDuration < 7 days
                || rampStart < block.timestamp + delay
        ) {
            revert ParameterChecksFailedException(); // F: [RCT-06]
        }

        _queueTransaction({
            target: creditConfigurator,
            signature: "rampLiquidationThreshold(address,uint16,uint40,uint24)",
            data: abi.encode(token, liquidationThresholdFinal, rampStart, rampDuration)
        }); // F: [RCT-06]
    }

    /// @notice Queues a transaction to forbid a third party contract
    /// @dev Requires the policy for keccak(group(contractManager), "FORBID_ADAPTER") to be enabled, otherwise auto-fails the check
    /// @param creditManager Adress of CM to forbid a contract for
    /// @param adapter Address of adapter to forbid
    function forbidAdapter(address creditManager, address adapter)
        external
        adminOnly // F: [RCT-10]
    {
        bytes32 policyHash = keccak256(abi.encode(_group[creditManager], "FORBID_ADAPTER"));

        address creditConfigurator = ICreditManagerV3(creditManager).creditConfigurator();

        // For `forbidAdapter`, there is no value to manipulate
        // A policy check simply verifies that this controller has access to the function in a given group
        if (!_checkPolicy(policyHash, 0, 0)) {
            revert ParameterChecksFailedException(); // F: [RCT-10]
        }

        _queueTransaction({target: creditConfigurator, signature: "forbidAdapter(address)", data: abi.encode(adapter)}); // F: [RCT-10]
    }

    /// @dev Internal function that records the transaction into the queued tx map
    /// @param target The contract to call
    /// @param signature The signature of the called function
    /// @param data The call data
    function _queueTransaction(address target, string memory signature, bytes memory data) internal returns (bytes32) {
        uint256 eta = block.timestamp + delay;

        bytes32 txHash = keccak256(abi.encode(target, signature, data, eta));

        queuedTransactions[txHash] =
            QueuedTransactionData({queued: true, target: target, eta: uint40(eta), signature: signature, data: data});

        emit QueueTransaction(txHash, target, signature, data, uint40(eta));
        return txHash;
    }

    /// @dev Sets the transaction's queued status as false, effectively cancelling it
    /// @param txHash Hash of the transaction to be cancelled
    function cancelTransaction(bytes32 txHash)
        external
        vetoAdminOnly // F: [RCT-07]
    {
        queuedTransactions[txHash].queued = false;
        emit CancelTransaction(txHash);
    }

    /// @dev Executes a queued transaction
    /// @param txHash Hash of the transaction to be executed
    function executeTransaction(bytes32 txHash)
        external
        adminOnly // F: [RCT-09]
    {
        QueuedTransactionData memory qtd = queuedTransactions[txHash];

        if (!qtd.queued) {
            revert TxNotQueuedException(); // F: [RCT-07]
        }

        address target = qtd.target;
        uint40 eta = qtd.eta;
        string memory signature = qtd.signature;
        bytes memory data = qtd.data;

        if (block.timestamp < eta || block.timestamp > eta + GRACE_PERIOD) {
            revert TxExecutedOutsideTimeWindowException(); // F: [RCT-09]
        }

        queuedTransactions[txHash].queued = false;

        bytes memory callData;

        if (bytes(signature).length == 0) {
            callData = data;
        } else {
            callData = abi.encodePacked(bytes4(keccak256(bytes(signature))), data);
        }

        (bool success,) = target.call(callData);

        if (!success) {
            revert TxExecutionRevertedException(); // F: [RCT-09] - TODO: Uncomment test after updating forge-std
        }

        emit ExecuteTransaction(txHash); // F: [RCT-09]
    }

    /// CONFIGURATION

    /// @dev Sets a new risk admin address
    function setAdmin(address newAdmin)
        external
        configuratorOnly // F: [RCT-08]
    {
        admin = newAdmin; // F: [RCT-08]
        emit SetAdmin(newAdmin); // F: [RCT-08]
    }

    /// @dev Sets a new veto admin address
    function setVetoAdmin(address newAdmin)
        external
        configuratorOnly // F: [RCT-08]
    {
        vetoAdmin = newAdmin; // F: [RCT-08]
        emit SetVetoAdmin(newAdmin); // F: [RCT-08]
    }

    /// @dev Sets a new ops admin delay
    function setDelay(uint256 newDelay)
        external
        configuratorOnly // F: [RCT-08]
    {
        delay = newDelay; // F: [RCT-08]
        emit SetDelay(newDelay); // F: [RCT-08]
    }
}
