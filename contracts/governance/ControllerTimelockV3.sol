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

    /// @dev Minimum liquidation threshold ramp duration
    uint256 constant MIN_LT_RAMP_DURATION = 7 days;

    /// @notice Period before a mature transaction becomes stale
    uint256 public constant override GRACE_PERIOD = 14 days;

    /// @notice Admin address that can cancel transactions
    address public override vetoAdmin;

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
        address creditConfigurator = ICreditManagerV3(creditManager).creditConfigurator();
        IPoolV3 pool = IPoolV3(ICreditManagerV3(creditManager).pool());

        address creditFacade = ICreditManagerV3(creditManager).creditFacade();

        uint40 oldExpirationDate = getExpirationDate(creditFacade);

        if (!_checkPolicy(creditManager, "EXPIRATION_DATE", uint256(oldExpirationDate), uint256(expirationDate))) {
            revert ParameterChecksFailedException(); // U:[CT-1]
        }

        uint256 totalBorrowed = pool.creditManagerBorrowed(address(creditManager));

        if (totalBorrowed != 0) {
            revert ParameterChecksFailedException(); // U:[CT-1]
        }

        _queueTransaction({
            target: creditConfigurator,
            signature: "setExpirationDate(uint40)",
            data: abi.encode(expirationDate),
            delay: _getPolicyDelay(creditManager, "EXPIRATION_DATE"),
            sanityCheckValue: oldExpirationDate,
            sanityCheckCallData: abi.encodeCall(this.getExpirationDate, (creditFacade))
        }); // U:[CT-1]
    }

    /// @dev Retrieves current expiration date for a credit manager
    function getExpirationDate(address creditFacade) public view returns (uint40) {
        return ICreditFacadeV3(creditFacade).expirationDate();
    }

    /// @notice Queues a transaction to set a new limiter value in a price feed
    /// @dev Requires the policy for keccak(group(priceFeed), "LP_PRICE_FEED_LIMITER") to be enabled,
    ///      otherwise auto-fails the check
    /// @param priceFeed The price feed to update the limiter in
    /// @param lowerBound The new limiter lower bound value
    function setLPPriceFeedLimiter(address priceFeed, uint256 lowerBound) external override {
        uint256 currentLowerBound = getPriceFeedLowerBound(priceFeed);

        if (!_checkPolicy(priceFeed, "LP_PRICE_FEED_LIMITER", currentLowerBound, lowerBound)) {
            revert ParameterChecksFailedException(); // U:[CT-2]
        }

        _queueTransaction({
            target: priceFeed,
            signature: "setLimiter(uint256)",
            data: abi.encode(lowerBound),
            delay: _getPolicyDelay(priceFeed, "LP_PRICE_FEED_LIMITER"),
            sanityCheckValue: currentLowerBound,
            sanityCheckCallData: abi.encodeCall(this.getPriceFeedLowerBound, (priceFeed))
        }); // U:[CT-2]
    }

    /// @dev Retrieves current lower bound for a price feed
    function getPriceFeedLowerBound(address priceFeed) public view returns (uint256) {
        return ILPPriceFeedV2(priceFeed).lowerBound();
    }

    /// @notice Queues a transaction to set a new max debt per block multiplier
    /// @dev Requires the policy for keccak(group(creditManager), "MAX_DEBT_PER_BLOCK_MULTIPLIER") to be enabled,
    ///      otherwise auto-fails the check
    /// @param creditManager Adress of CM to update the multiplier for
    /// @param multiplier The new multiplier value
    function setMaxDebtPerBlockMultiplier(address creditManager, uint8 multiplier) external override {
        address creditConfigurator = ICreditManagerV3(creditManager).creditConfigurator();

        address creditFacade = ICreditManagerV3(creditManager).creditFacade();

        uint8 currentMultiplier = getMaxDebtPerBlockMultiplier(creditFacade);

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
            data: abi.encode(multiplier),
            delay: _getPolicyDelay(creditManager, "MAX_DEBT_PER_BLOCK_MULTIPLIER"),
            sanityCheckValue: currentMultiplier,
            sanityCheckCallData: abi.encodeCall(this.getMaxDebtPerBlockMultiplier, (creditFacade))
        }); // U:[CT-3]
    }

    /// @dev Retrieves current max debt per block multiplier for a Credit Facade
    function getMaxDebtPerBlockMultiplier(address creditFacade) public view returns (uint8) {
        return ICreditFacadeV3(creditFacade).maxDebtPerBlockMultiplier();
    }

    /// @notice Queues a transaction to set a new min debt per account
    /// @dev Requires the policy for keccak(group(creditManager), "MIN_DEBT") to be enabled,
    ///      otherwise auto-fails the check
    /// @param creditManager Adress of CM to update the limits for
    /// @param minDebt The new minimal debt amount
    function setMinDebtLimit(address creditManager, uint128 minDebt) external override {
        address creditConfigurator = ICreditManagerV3(creditManager).creditConfigurator();

        address creditFacade = ICreditManagerV3(creditManager).creditFacade();

        uint128 minDebtCurrent = getMinDebtLimit(creditFacade);

        if (!_checkPolicy(creditManager, "MIN_DEBT", uint256(minDebtCurrent), uint256(minDebt))) {
            revert ParameterChecksFailedException(); // U:[CT-4A]
        }

        _queueTransaction({
            target: creditConfigurator,
            signature: "setMinDebtLimit(uint128)",
            data: abi.encode(minDebt),
            delay: _getPolicyDelay(creditManager, "MIN_DEBT"),
            sanityCheckValue: minDebtCurrent,
            sanityCheckCallData: abi.encodeCall(this.getMinDebtLimit, (creditFacade))
        }); // U:[CT-4A]
    }

    /// @dev Retrieves the current min debt limit for a Credit Manager
    function getMinDebtLimit(address creditFacade) public view returns (uint128) {
        (uint128 minDebtCurrent,) = ICreditFacadeV3(creditFacade).debtLimits();
        return minDebtCurrent;
    }

    /// @notice Queues a transaction to set a new max debt per account
    /// @dev Requires the policy for keccak(group(creditManager), "MAX_DEBT") to be enabled,
    ///      otherwise auto-fails the check
    /// @param creditManager Adress of CM to update the limits for
    /// @param maxDebt The new maximal debt amount
    function setMaxDebtLimit(address creditManager, uint128 maxDebt) external override {
        address creditConfigurator = ICreditManagerV3(creditManager).creditConfigurator();

        address creditFacade = ICreditManagerV3(creditManager).creditFacade();

        uint128 maxDebtCurrent = getMaxDebtLimit(creditFacade);

        if (!_checkPolicy(creditManager, "MAX_DEBT", uint256(maxDebtCurrent), uint256(maxDebt))) {
            revert ParameterChecksFailedException(); // U:[CT-4B]
        }

        _queueTransaction({
            target: creditConfigurator,
            signature: "setMaxDebtLimit(uint128)",
            data: abi.encode(maxDebt),
            delay: _getPolicyDelay(creditManager, "MAX_DEBT"),
            sanityCheckValue: maxDebtCurrent,
            sanityCheckCallData: abi.encodeCall(this.getMaxDebtLimit, (creditFacade))
        }); // U:[CT-4B]
    }

    /// @dev Retrieves the current max debt limit for a Credit Manager
    function getMaxDebtLimit(address creditFacade) public view returns (uint128) {
        (, uint128 maxDebtCurrent) = ICreditFacadeV3(creditFacade).debtLimits();
        return maxDebtCurrent;
    }

    /// @notice Queues a transaction to set a new debt limit for a Credit Manager
    /// @dev Requires the policy for keccak(group(creditManager), "CREDIT_MANAGER_DEBT_LIMIT") to be enabled,
    ///      otherwise auto-fails the check
    /// @param creditManager Adress of CM to update the debt limit for
    /// @param debtLimit The new debt limit
    function setCreditManagerDebtLimit(address creditManager, uint256 debtLimit) external override {
        IPoolV3 pool = IPoolV3(ICreditManagerV3(creditManager).pool());

        uint256 debtLimitCurrent = getCreditManagerDebtLimit(address(pool), creditManager);

        if (!_checkPolicy(creditManager, "CREDIT_MANAGER_DEBT_LIMIT", uint256(debtLimitCurrent), uint256(debtLimit))) {
            revert ParameterChecksFailedException(); // U:[CT-5]
        }

        _queueTransaction({
            target: address(pool),
            signature: "setCreditManagerDebtLimit(address,uint256)",
            data: abi.encode(address(creditManager), debtLimit),
            delay: _getPolicyDelay(creditManager, "CREDIT_MANAGER_DEBT_LIMIT"),
            sanityCheckValue: debtLimitCurrent,
            sanityCheckCallData: abi.encodeCall(this.getCreditManagerDebtLimit, (address(pool), creditManager))
        }); // U:[CT-5]
    }

    /// @dev Retrieves the current total debt limit for Credit Manager from its pool
    function getCreditManagerDebtLimit(address pool, address creditManager) public view returns (uint256) {
        return IPoolV3(pool).creditManagerDebtLimit(creditManager);
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

        uint256 ltCurrent = ICreditManagerV3(creditManager).liquidationThresholds(token);

        uint256 delay = _getPolicyDelay(policyHash);

        if (
            !_checkPolicy(policyHash, uint256(ltCurrent), uint256(liquidationThresholdFinal))
                || rampDuration < MIN_LT_RAMP_DURATION || rampStart < block.timestamp + delay
        ) {
            revert ParameterChecksFailedException(); // U: [CT-6]
        }

        _queueTransaction({
            target: ICreditManagerV3(creditManager).creditConfigurator(),
            signature: "rampLiquidationThreshold(address,uint16,uint40,uint24)",
            data: abi.encode(token, liquidationThresholdFinal, rampStart, rampDuration),
            delay: delay,
            sanityCheckValue: uint256(getLTRampParamsHash(creditManager, token)),
            sanityCheckCallData: abi.encodeCall(this.getLTRampParamsHash, (creditManager, token))
        }); // U: [CT-6]
    }

    /// @dev Retrives the keccak of liquidation threshold params for a token
    function getLTRampParamsHash(address creditManager, address token) public view returns (bytes32) {
        (uint16 ltInitial, uint16 ltFinal, uint40 timestampRampStart, uint24 rampDuration) =
            ICreditManagerV3(creditManager).ltParams(token);
        return keccak256(abi.encode(ltInitial, ltFinal, timestampRampStart, rampDuration));
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

        _queueTransaction({
            target: creditConfigurator,
            signature: "forbidAdapter(address)",
            data: abi.encode(adapter),
            delay: _getPolicyDelay(policyHash),
            sanityCheckValue: 0,
            sanityCheckCallData: ""
        }); // U: [CT-10]
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

        uint96 oldLimit = getTokenLimit(poolQuotaKeeper, token);

        if (!_checkPolicy(policyHash, uint256(oldLimit), uint256(limit))) {
            revert ParameterChecksFailedException(); // U: [CT-11]
        }

        _queueTransaction({
            target: poolQuotaKeeper,
            signature: "setTokenLimit(address,uint96)",
            data: abi.encode(token, limit),
            delay: _getPolicyDelay(policyHash),
            sanityCheckValue: oldLimit,
            sanityCheckCallData: abi.encodeCall(this.getTokenLimit, (poolQuotaKeeper, token))
        }); // U: [CT-11]
    }

    /// @dev Retrieves the per-token quota limit from pool quota keeper
    function getTokenLimit(address poolQuotaKeeper, address token) public view returns (uint96) {
        (,,,, uint96 oldLimit,) = IPoolQuotaKeeperV3(poolQuotaKeeper).getTokenQuotaParams(token);
        return oldLimit;
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

        uint16 quotaIncreaseFeeOld = getTokenQuotaIncreaseFee(poolQuotaKeeper, token);

        if (!_checkPolicy(policyHash, uint256(quotaIncreaseFeeOld), uint256(quotaIncreaseFee))) {
            revert ParameterChecksFailedException(); // U: [CT-12]
        }

        _queueTransaction({
            target: poolQuotaKeeper,
            signature: "setTokenQuotaIncreaseFee(address,uint16)",
            data: abi.encode(token, quotaIncreaseFee),
            delay: _getPolicyDelay(policyHash),
            sanityCheckValue: quotaIncreaseFeeOld,
            sanityCheckCallData: abi.encodeCall(this.getTokenQuotaIncreaseFee, (poolQuotaKeeper, token))
        }); // U: [CT-12]
    }

    /// @dev Retrieves the quota increase fee for a token
    function getTokenQuotaIncreaseFee(address poolQuotaKeeper, address token) public view returns (uint16) {
        (,, uint16 quotaIncreaseFeeOld,,,) = IPoolQuotaKeeperV3(poolQuotaKeeper).getTokenQuotaParams(token);
        return quotaIncreaseFeeOld;
    }

    /// @notice Queues a transaction to set a new total debt limit for the entire pool
    /// @dev Requires the policy for keccak(group(pool), "TOTAL_DEBT_LIMIT") to be enabled,
    ///      otherwise auto-fails the check
    /// @param pool Pool to update the limit for
    /// @param newLimit The new value of the limit
    function setTotalDebtLimit(address pool, uint256 newLimit) external override {
        bytes32 policyHash = keccak256(abi.encode(_group[pool], "TOTAL_DEBT_LIMIT"));

        uint256 totalDebtLimitOld = getTotalDebtLimit(pool);

        if (!_checkPolicy(policyHash, uint256(totalDebtLimitOld), uint256(newLimit))) {
            revert ParameterChecksFailedException(); // U: [CT-13]
        }

        _queueTransaction({
            target: pool,
            signature: "setTotalDebtLimit(uint256)",
            data: abi.encode(newLimit),
            delay: _getPolicyDelay(policyHash),
            sanityCheckValue: totalDebtLimitOld,
            sanityCheckCallData: abi.encodeCall(this.getTotalDebtLimit, (pool))
        }); // U: [CT-13]
    }

    /// @dev Retrieves the total debt limit for a pool
    function getTotalDebtLimit(address pool) public view returns (uint256) {
        return IPoolV3(pool).totalDebtLimit();
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

        _queueTransaction({
            target: pool,
            signature: "setWithdrawFee(uint256)",
            data: abi.encode(newFee),
            delay: _getPolicyDelay(policyHash),
            sanityCheckValue: withdrawFeeOld,
            sanityCheckCallData: abi.encodeCall(this.getWithdrawFee, (pool))
        }); // U: [CT-14]
    }

    /// @dev Retrieves the withdrawal fee for a pool
    function getWithdrawFee(address pool) public view returns (uint256) {
        return IPoolV3(pool).withdrawFee();
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

        uint16 minRateCurrent = getMinQuotaRate(gauge, token);

        if (!_checkPolicy(policyHash, uint256(minRateCurrent), uint256(rate))) {
            revert ParameterChecksFailedException(); // U: [CT-15A]
        }

        _queueTransaction({
            target: gauge,
            signature: "changeQuotaMinRate(address,uint16)",
            data: abi.encode(token, rate),
            delay: _getPolicyDelay(policyHash),
            sanityCheckValue: minRateCurrent,
            sanityCheckCallData: abi.encodeCall(this.getMinQuotaRate, (gauge, token))
        }); // U: [CT-15A]
    }

    /// @dev Retrieves the current minimal quota rate for a token in a gauge
    function getMinQuotaRate(address gauge, address token) public view returns (uint16) {
        (uint16 minRateCurrent,,,) = IGaugeV3(gauge).quotaRateParams(token);
        return minRateCurrent;
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

        uint16 maxRateCurrent = getMaxQuotaRate(gauge, token);

        if (!_checkPolicy(policyHash, uint256(maxRateCurrent), uint256(rate))) {
            revert ParameterChecksFailedException(); // U: [CT-15B]
        }

        _queueTransaction({
            target: gauge,
            signature: "changeQuotaMaxRate(address,uint16)",
            data: abi.encode(token, rate),
            delay: _getPolicyDelay(policyHash),
            sanityCheckValue: maxRateCurrent,
            sanityCheckCallData: abi.encodeCall(this.getMaxQuotaRate, (gauge, token))
        }); // U: [CT-15B]
    }

    /// @dev Retrieves the current maximal quota rate for a token in a gauge
    function getMaxQuotaRate(address gauge, address token) public view returns (uint16) {
        (, uint16 maxRateCurrent,,) = IGaugeV3(gauge).quotaRateParams(token);
        return maxRateCurrent;
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
            data: abi.encode(token, active),
            delay: _getPolicyDelay(policyHash),
            sanityCheckValue: 0,
            sanityCheckCallData: ""
        }); // U:[CT-16]
    }

    /// @notice Queues a transaction to forbid permissionless bounds update in an LP price feed
    /// @dev Requires the policy for keccak(group(priceFeed), "UPDATE_BOUNDS_ALLOWED") to be enabled,
    ///      otherwise auto-fails the check
    /// @param priceFeed The price feed to forbid bounds update for
    function forbidBoundsUpdate(address priceFeed) external override {
        if (!_checkPolicy(priceFeed, "UPDATE_BOUNDS_ALLOWED", 0, 0)) {
            revert ParameterChecksFailedException(); // U:[CT-17]
        }

        _queueTransaction({
            target: priceFeed,
            signature: "forbidBoundsUpdate()",
            data: "",
            delay: _getPolicyDelay(priceFeed, "UPDATE_BOUNDS_ALLOWED"),
            sanityCheckValue: 0,
            sanityCheckCallData: ""
        }); // U:[CT-17]
    }

    /// @dev Internal function that stores the transaction in the queued tx map
    /// @param target The contract to call
    /// @param signature The signature of the called function
    /// @param data The call data
    /// @return Hash of the queued transaction
    function _queueTransaction(
        address target,
        string memory signature,
        bytes memory data,
        uint256 delay,
        uint256 sanityCheckValue,
        bytes memory sanityCheckCallData
    ) internal returns (bytes32) {
        uint256 eta = block.timestamp + delay;

        bytes32 txHash = keccak256(abi.encode(msg.sender, target, signature, data, eta));

        queuedTransactions[txHash] = QueuedTransactionData({
            queued: true,
            executor: msg.sender,
            target: target,
            eta: uint40(eta),
            signature: signature,
            data: data,
            sanityCheckValue: sanityCheckValue,
            sanityCheckCallData: sanityCheckCallData
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

        // In order to ensure that we do not accidentally override a change
        // made by configurator or another admin, the current value of the parameter
        // is compared to the value at the moment of tx being queued
        if (qtd.sanityCheckCallData.length != 0) {
            (, bytes memory returndata) = address(this).staticcall(qtd.sanityCheckCallData);

            if (abi.decode(returndata, (uint256)) != qtd.sanityCheckValue) {
                revert ParameterChangedAfterQueuedTxException();
            }
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
}
