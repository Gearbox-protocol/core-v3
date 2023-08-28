// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {PolicyManagerV3} from "./PolicyManagerV3.sol";
import {IControllerTimelockV3, QueuedTransactionData} from "../interfaces/IControllerTimelockV3.sol";
import {ICreditManagerV3} from "../interfaces/ICreditManagerV3.sol";
import {ICreditFacadeV3} from "../interfaces/ICreditFacadeV3.sol";
import {IPoolV3} from "../interfaces/IPoolV3.sol";
import {IPoolQuotaKeeperV3} from "../interfaces/IPoolQuotaKeeperV3.sol";
import {IGaugeV3} from "../interfaces/IGaugeV3.sol";
import {ILPPriceFeedV2} from "@gearbox-protocol/core-v2/contracts/interfaces/ILPPriceFeedV2.sol";
import "../interfaces/IExceptions.sol";

/// @title Controller timelock V3
/// @notice Controller timelock is a governance contract that allows special actors less trusted than Gearbox Governance
///         to modify system parameters within set boundaries. This is mostly related to risk parameters that should be
///         adjusted frequently or periodic tasks (e.g., updating price feed limiters) that are too trivial to employ
///         the full governance for.
/// @dev The contract uses `PolicyManager` as its underlying engine to set parameter change boundaries and conditions.
///      In order to schedule a change for a particular contract / function combination, a policy needs to be defined
///      for it. The policy also determines the address that can change a particular parameter.
contract ControllerTimelockV3 is PolicyManagerV3, IControllerTimelockV3 {
    /// @notice Contract version
    uint256 public constant override version = 3_00;

    /// @notice Period before a mature transaction becomes stale
    uint256 public constant override GRACE_PERIOD = 14 days;

    /// @notice Admin address that can cancel transactions
    address public override vetoAdmin;

    /// @notice Delay before a risk-related transaction can be executed
    uint256 public override delay = 1 days;

    /// @notice Mapping from transaction hashes to their data
    mapping(bytes32 => QueuedTransactionData) public override queuedTransactions;

    /// @notice Constructor
    /// @param _addressProvider Address of the address provider
    /// @param _vetoAdmin Admin that can cancel transactions
    constructor(address _addressProvider, address _vetoAdmin) PolicyManagerV3(_addressProvider) {
        vetoAdmin = _vetoAdmin;
    }

    /// @dev Ensures that function caller is the veto admin
    modifier vetoAdminOnly() {
        _revertIfCallerIsNotVetoAdmin();
        _;
    }

    /// @dev Reverts if `msg.sender` is not the veto admin
    function _revertIfCallerIsNotVetoAdmin() internal view {
        if (msg.sender != vetoAdmin) {
            revert CallerNotVetoAdminException();
        }
    }

    // -------- //
    // QUEUEING //
    // -------- //

    /// @notice Queues a transaction to set a new expiration date in the Credit Facade
    /// @dev Requires the policy for keccak(group(creditManager), "EXPIRATION_DATE") to be enabled,
    ///      otherwise auto-fails the check
    /// @param creditManager Adress of CM to update the expiration date for
    /// @param expirationDate The new expiration date
    function setExpirationDate(address creditManager, uint40 expirationDate) external override {
        ICreditFacadeV3 creditFacade = ICreditFacadeV3(ICreditManagerV3(creditManager).creditFacade());
        address creditConfigurator = ICreditManagerV3(creditManager).creditConfigurator();
        IPoolV3 pool = IPoolV3(ICreditManagerV3(creditManager).pool());

        uint40 oldExpirationDate = creditFacade.expirationDate();
        uint256 totalBorrowed = pool.creditManagerBorrowed(address(creditManager));

        if (
            !_checkPolicy(creditManager, "EXPIRATION_DATE", uint256(oldExpirationDate), uint256(expirationDate))
                || totalBorrowed != 0
        ) {
            revert ParameterChecksFailedException(); // U:[CT-1]
        }

        _queueTransaction({
            target: creditConfigurator,
            signature: "setExpirationDate(uint40)",
            data: abi.encode(expirationDate)
        }); // U:[CT-1]
    }

    /// @notice Queues a transaction to set a new limiter value in a price feed
    /// @dev Requires the policy for keccak(group(priceFeed), "LP_PRICE_FEED_LIMITER") to be enabled,
    ///      otherwise auto-fails the check
    /// @param priceFeed The price feed to update the limiter in
    /// @param lowerBound The new limiter lower bound value
    function setLPPriceFeedLimiter(address priceFeed, uint256 lowerBound) external override {
        uint256 currentLowerBound = ILPPriceFeedV2(priceFeed).lowerBound();

        if (!_checkPolicy(priceFeed, "LP_PRICE_FEED_LIMITER", currentLowerBound, lowerBound)) {
            revert ParameterChecksFailedException(); // U:[CT-2]
        }

        _queueTransaction({target: priceFeed, signature: "setLimiter(uint256)", data: abi.encode(lowerBound)}); // U:[CT-2]
    }

    /// @notice Queues a transaction to set a new max debt per block multiplier
    /// @dev Requires the policy for keccak(group(creditManager), "MAX_DEBT_PER_BLOCK_MULTIPLIER") to be enabled,
    ///      otherwise auto-fails the check
    /// @param creditManager Adress of CM to update the multiplier for
    /// @param multiplier The new multiplier value
    function setMaxDebtPerBlockMultiplier(address creditManager, uint8 multiplier) external override {
        ICreditFacadeV3 creditFacade = ICreditFacadeV3(ICreditManagerV3(creditManager).creditFacade());
        address creditConfigurator = ICreditManagerV3(creditManager).creditConfigurator();

        uint8 currentMultiplier = creditFacade.maxDebtPerBlockMultiplier();

        if (
            !_checkPolicy(
                creditManager, "MAX_DEBT_PER_BLOCK_MULTIPLIER", uint256(currentMultiplier), uint256(multiplier)
            )
        ) {
            revert ParameterChecksFailedException(); // U:[CT-3]
        }

        _queueTransaction({
            target: creditConfigurator,
            signature: "setMaxDebtPerBlockMultiplier(uint8)",
            data: abi.encode(multiplier)
        }); // U:[CT-3]
    }

    /// @notice Queues a transaction to set a new min debt per account
    /// @dev Requires the policy for keccak(group(creditManager), "MIN_DEBT") to be enabled,
    ///      otherwise auto-fails the check
    /// @param creditManager Adress of CM to update the limits for
    /// @param minDebt The new minimal debt amount
    function setMinDebtLimit(address creditManager, uint128 minDebt) external override {
        ICreditFacadeV3 creditFacade = ICreditFacadeV3(ICreditManagerV3(creditManager).creditFacade());
        address creditConfigurator = ICreditManagerV3(creditManager).creditConfigurator();

        (uint128 minDebtCurrent,) = creditFacade.debtLimits();

        if (!_checkPolicy(creditManager, "MIN_DEBT", uint256(minDebtCurrent), uint256(minDebt))) {
            revert ParameterChecksFailedException(); // U:[CT-4A]
        }

        _queueTransaction({target: creditConfigurator, signature: "setMinDebtLimit(uint128)", data: abi.encode(minDebt)}); // U:[CT-4A]
    }

    /// @notice Queues a transaction to set a new max debt per account
    /// @dev Requires the policy for keccak(group(creditManager), "MAX_DEBT") to be enabled,
    ///      otherwise auto-fails the check
    /// @param creditManager Adress of CM to update the limits for
    /// @param maxDebt The new maximal debt amount
    function setMaxDebtLimit(address creditManager, uint128 maxDebt) external override {
        ICreditFacadeV3 creditFacade = ICreditFacadeV3(ICreditManagerV3(creditManager).creditFacade());
        address creditConfigurator = ICreditManagerV3(creditManager).creditConfigurator();

        (, uint128 maxDebtCurrent) = creditFacade.debtLimits();

        if (!_checkPolicy(creditManager, "MAX_DEBT", uint256(maxDebtCurrent), uint256(maxDebt))) {
            revert ParameterChecksFailedException(); // U:[CT-4B]
        }

        _queueTransaction({target: creditConfigurator, signature: "setMaxDebtLimit(uint128)", data: abi.encode(maxDebt)}); // U:[CT-4B]
    }

    /// @notice Queues a transaction to set a new debt limit for a Credit Manager
    /// @dev Requires the policy for keccak(group(creditManager), "CREDIT_MANAGER_DEBT_LIMIT") to be enabled,
    ///      otherwise auto-fails the check
    /// @param creditManager Adress of CM to update the debt limit for
    /// @param debtLimit The new debt limit
    function setCreditManagerDebtLimit(address creditManager, uint256 debtLimit) external override {
        ICreditFacadeV3 creditFacade = ICreditFacadeV3(ICreditManagerV3(creditManager).creditFacade());

        if (creditFacade.trackTotalDebt()) {
            (, uint256 debtLimitCurrent) = creditFacade.totalDebt();

            if (
                !_checkPolicy(creditManager, "CREDIT_MANAGER_DEBT_LIMIT", uint256(debtLimitCurrent), uint256(debtLimit))
            ) {
                revert ParameterChecksFailedException(); // U:[CT-5A]
            }

            address creditConfigurator = ICreditManagerV3(creditManager).creditConfigurator();

            _queueTransaction({
                target: address(creditConfigurator),
                signature: "setTotalDebtLimit(uint128)",
                data: abi.encode(uint128(debtLimit))
            }); // U:[CT-5A]
        } else {
            IPoolV3 pool = IPoolV3(ICreditManagerV3(creditManager).pool());

            uint256 debtLimitCurrent = pool.creditManagerDebtLimit(address(creditManager));

            if (
                !_checkPolicy(creditManager, "CREDIT_MANAGER_DEBT_LIMIT", uint256(debtLimitCurrent), uint256(debtLimit))
            ) {
                revert ParameterChecksFailedException(); // U:[CT-5]
            }

            _queueTransaction({
                target: address(pool),
                signature: "setCreditManagerDebtLimit(address,uint256)",
                data: abi.encode(address(creditManager), debtLimit)
            }); // U:[CT-5]
        }
    }

    /// @notice Queues a transaction to start a liquidation threshold ramp
    /// @dev Requires the policy for keccak(group(creditManager), group(token), "TOKEN_LT") to be enabled,
    ///      otherwise auto-fails the check
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
    ) external override {
        bytes32 policyHash = keccak256(abi.encode(_group[creditManager], _group[token], "TOKEN_LT"));

        address creditConfigurator = ICreditManagerV3(creditManager).creditConfigurator();
        uint256 ltCurrent = ICreditManagerV3(creditManager).liquidationThresholds(token);

        if (
            !_checkPolicy(policyHash, uint256(ltCurrent), uint256(liquidationThresholdFinal)) || rampDuration < 7 days
                || rampStart < block.timestamp + delay
        ) {
            revert ParameterChecksFailedException(); // U: [CT-6]
        }

        _queueTransaction({
            target: creditConfigurator,
            signature: "rampLiquidationThreshold(address,uint16,uint40,uint24)",
            data: abi.encode(token, liquidationThresholdFinal, rampStart, rampDuration)
        }); // U: [CT-6]
    }

    /// @notice Queues a transaction to forbid a third party contract adapter
    /// @dev Requires the policy for keccak(group(creditManager), "FORBID_ADAPTER") to be enabled,
    ///      otherwise auto-fails the check
    /// @param creditManager Adress of CM to forbid an adapter for
    /// @param adapter Address of adapter to forbid
    function forbidAdapter(address creditManager, address adapter) external override {
        bytes32 policyHash = keccak256(abi.encode(_group[creditManager], "FORBID_ADAPTER"));

        address creditConfigurator = ICreditManagerV3(creditManager).creditConfigurator();

        // For `forbidAdapter`, there is no value to modify
        // A policy check simply verifies that this controller has access to the function in a given group
        if (!_checkPolicy(policyHash, 0, 0)) {
            revert ParameterChecksFailedException(); // U: [CT-10]
        }

        _queueTransaction({target: creditConfigurator, signature: "forbidAdapter(address)", data: abi.encode(adapter)}); // U: [CT-10]
    }

    /// @notice Queues a transaction to set a new limit on quotas for particular pool and token
    /// @dev Requires the policy for keccak(group(pool), group(token), "TOKEN_LIMIT") to be enabled,
    ///      otherwise auto-fails the check
    /// @param pool Pool to update the limit for
    /// @param token Token to update the limit for
    /// @param limit The new value of the limit
    function setTokenLimit(address pool, address token, uint96 limit) external override {
        bytes32 policyHash = keccak256(abi.encode(_group[pool], _group[token], "TOKEN_LIMIT"));

        address poolQuotaKeeper = IPoolV3(pool).poolQuotaKeeper();

        (,,,, uint96 oldLimit) = IPoolQuotaKeeperV3(poolQuotaKeeper).getTokenQuotaParams(token);

        if (!_checkPolicy(policyHash, uint256(oldLimit), uint256(limit))) {
            revert ParameterChecksFailedException(); // U: [CT-11]
        }

        _queueTransaction({
            target: poolQuotaKeeper,
            signature: "setTokenLimit(address,uint96)",
            data: abi.encode(token, limit)
        }); // U: [CT-11]
    }

    /// @notice Queues a transaction to set a new quota increase (trading) fee for a particular pool and token
    /// @dev Requires the policy for keccak(group(pool), group(token), "TOKEN_QUOTA_INCREASE_FEE") to be enabled,
    ///      otherwise auto-fails the check
    /// @param pool Pool to update the limit for
    /// @param token Token to update the limit for
    /// @param quotaIncreaseFee The new value of the fee in bp
    function setTokenQuotaIncreaseFee(address pool, address token, uint16 quotaIncreaseFee) external override {
        bytes32 policyHash = keccak256(abi.encode(_group[pool], _group[token], "TOKEN_QUOTA_INCREASE_FEE"));

        address poolQuotaKeeper = IPoolV3(pool).poolQuotaKeeper();

        (,, uint16 quotaIncreaseFeeOld,,) = IPoolQuotaKeeperV3(poolQuotaKeeper).getTokenQuotaParams(token);

        if (!_checkPolicy(policyHash, uint256(quotaIncreaseFeeOld), uint256(quotaIncreaseFee))) {
            revert ParameterChecksFailedException(); // U: [CT-12]
        }

        _queueTransaction({
            target: poolQuotaKeeper,
            signature: "setTokenQuotaIncreaseFee(address,uint16)",
            data: abi.encode(token, quotaIncreaseFee)
        }); // U: [CT-12]
    }

    /// @notice Queues a transaction to set a new total debt limit for the entire pool
    /// @dev Requires the policy for keccak(group(pool), "TOTAL_DEBT_LIMIT") to be enabled,
    ///      otherwise auto-fails the check
    /// @param pool Pool to update the limit for
    /// @param newLimit The new value of the limit
    function setTotalDebtLimit(address pool, uint256 newLimit) external override {
        bytes32 policyHash = keccak256(abi.encode(_group[pool], "TOTAL_DEBT_LIMIT"));

        uint256 totalDebtLimitOld = IPoolV3(pool).totalDebtLimit();

        if (!_checkPolicy(policyHash, uint256(totalDebtLimitOld), uint256(newLimit))) {
            revert ParameterChecksFailedException(); // U: [CT-13]
        }

        _queueTransaction({target: pool, signature: "setTotalDebtLimit(uint256)", data: abi.encode(newLimit)}); // U: [CT-13]
    }

    /// @notice Queues a transaction to set a new withdrawal fee in a pool
    /// @dev Requires the policy for keccak(group(pool), "WITHDRAW_FEE") to be enabled,
    ///      otherwise auto-fails the check
    /// @param pool Pool to update the limit for
    /// @param newFee The new value of the fee in bp
    function setWithdrawFee(address pool, uint256 newFee) external override {
        bytes32 policyHash = keccak256(abi.encode(_group[pool], "WITHDRAW_FEE"));

        uint256 withdrawFeeOld = IPoolV3(pool).withdrawFee();

        if (!_checkPolicy(policyHash, withdrawFeeOld, newFee)) {
            revert ParameterChecksFailedException(); // U: [CT-14]
        }

        _queueTransaction({target: pool, signature: "setWithdrawFee(uint256)", data: abi.encode(newFee)}); // U: [CT-14]
    }

    /// @notice Queues a transaction to set a new minimal quota interest rate for particular pool and token
    /// @dev Requires the policy for keccak(group(pool), group(token), "TOKEN_QUOTA_MIN_RATE") to be enabled,
    ///      otherwise auto-fails the check
    /// @param pool Pool to update the limit for
    /// @param token Token to set the new fee for
    /// @param rate The new minimal rate
    function setMinQuotaRate(address pool, address token, uint16 rate) external override {
        bytes32 policyHash = keccak256(abi.encode(_group[pool], _group[token], "TOKEN_QUOTA_MIN_RATE"));

        address poolQuotaKeeper = IPoolV3(pool).poolQuotaKeeper();

        address gauge = IPoolQuotaKeeperV3(poolQuotaKeeper).gauge();

        (uint16 minRateCurrent,,,) = IGaugeV3(gauge).quotaRateParams(token);

        if (!_checkPolicy(policyHash, uint256(minRateCurrent), uint256(rate))) {
            revert ParameterChecksFailedException(); // U: [CT-15A]
        }

        _queueTransaction({
            target: gauge,
            signature: "changeQuotaMinRate(address,uint16)",
            data: abi.encode(token, rate)
        }); // U: [CT-15A]
    }

    /// @notice Queues a transaction to set a new maximal quota interest rate for particular pool and token
    /// @dev Requires the policy for keccak(group(pool), group(token), "TOKEN_QUOTA_MAX_RATE") to be enabled,
    ///      otherwise auto-fails the check
    /// @param pool Pool to update the limit for
    /// @param token Token to set the new fee for
    /// @param rate The new maximal rate
    function setMaxQuotaRate(address pool, address token, uint16 rate) external override {
        bytes32 policyHash = keccak256(abi.encode(_group[pool], _group[token], "TOKEN_QUOTA_MAX_RATE"));

        address poolQuotaKeeper = IPoolV3(pool).poolQuotaKeeper();

        address gauge = IPoolQuotaKeeperV3(poolQuotaKeeper).gauge();

        (, uint16 maxRateCurrent,,) = IGaugeV3(gauge).quotaRateParams(token);

        if (!_checkPolicy(policyHash, uint256(maxRateCurrent), uint256(rate))) {
            revert ParameterChecksFailedException(); // U: [CT-15B]
        }

        _queueTransaction({
            target: gauge,
            signature: "changeQuotaMaxRate(address,uint16)",
            data: abi.encode(token, rate)
        }); // U: [CT-15B]
    }

    /// @notice Queues a transaction to activate or deactivate reserve price feed for a token in price oracle
    /// @dev Requires the policy for keccak(group(priceOracle), group(token), "RESERVE_PRICE_FEED_STATUS")
    ///      to be enabled, otherwise auto-fails the check
    /// @param priceOracle Price oracle to change reserve price feed status for
    /// @param token Token to change reserve price feed status for
    /// @param active New reserve price feed status (`true` to activate, `false` to deactivate)
    function setReservePriceFeedStatus(address priceOracle, address token, bool active) external override {
        bytes32 policyHash = keccak256(abi.encode(_group[priceOracle], _group[token], "RESERVE_PRICE_FEED_STATUS"));

        if (!_checkPolicy(policyHash, 0, 0)) {
            revert ParameterChecksFailedException(); // U:[CT-16]
        }

        _queueTransaction({
            target: priceOracle,
            signature: "setReservePriceFeedStatus(address,bool)",
            data: abi.encode(token, active)
        }); // U:[CT-16]
    }

    /// @dev Internal function that stores the transaction in the queued tx map
    /// @param target The contract to call
    /// @param signature The signature of the called function
    /// @param data The call data
    /// @return Hash of the queued transaction
    function _queueTransaction(address target, string memory signature, bytes memory data) internal returns (bytes32) {
        uint256 eta = block.timestamp + delay;

        bytes32 txHash = keccak256(abi.encode(msg.sender, target, signature, data, eta));

        queuedTransactions[txHash] = QueuedTransactionData({
            queued: true,
            executor: msg.sender,
            target: target,
            eta: uint40(eta),
            signature: signature,
            data: data
        });

        emit QueueTransaction({
            txHash: txHash,
            executor: msg.sender,
            target: target,
            signature: signature,
            data: data,
            eta: uint40(eta)
        });

        return txHash;
    }

    // --------- //
    // EXECUTION //
    // --------- //

    /// @notice Sets the transaction's queued status as false, effectively cancelling it
    /// @param txHash Hash of the transaction to be cancelled
    function cancelTransaction(bytes32 txHash)
        external
        override
        vetoAdminOnly // U: [CT-7]
    {
        queuedTransactions[txHash].queued = false;
        emit CancelTransaction(txHash);
    }

    /// @notice Executes a queued transaction
    /// @param txHash Hash of the transaction to be executed
    function executeTransaction(bytes32 txHash) external override {
        QueuedTransactionData memory qtd = queuedTransactions[txHash];

        if (!qtd.queued) {
            revert TxNotQueuedException(); // U: [CT-7]
        }

        if (msg.sender != qtd.executor) {
            revert CallerNotExecutorException(); // U: [CT-9]
        }

        address target = qtd.target;
        uint40 eta = qtd.eta;
        string memory signature = qtd.signature;
        bytes memory data = qtd.data;

        if (block.timestamp < eta || block.timestamp > eta + GRACE_PERIOD) {
            revert TxExecutedOutsideTimeWindowException(); // U: [CT-9]
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
            revert TxExecutionRevertedException(); // U: [CT-9]
        }

        emit ExecuteTransaction(txHash); // U: [CT-9]
    }

    // ------------- //
    // CONFIGURATION //
    // ------------- //

    /// @notice Sets a new veto admin address
    function setVetoAdmin(address newAdmin)
        external
        override
        configuratorOnly // U: [CT-8]
    {
        if (vetoAdmin != newAdmin) {
            vetoAdmin = newAdmin; // U: [CT-8]
            emit SetVetoAdmin(newAdmin); // U: [CT-8]
        }
    }

    /// @notice Sets a new execution delay
    function setDelay(uint256 newDelay)
        external
        override
        configuratorOnly // U: [CT-0]
    {
        if (delay != newDelay) {
            delay = newDelay; // U: [CT-8]
            emit SetDelay(newDelay); // U: [CT-8]
        }
    }
}
