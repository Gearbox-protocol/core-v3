// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import {MetaParamManager} from "./MetaParamManager.sol";

import {IControllerTimelock, QueuedTransactionData} from "../../interfaces/IControllerTimelock.sol";

import {ICreditManagerV3} from "../../interfaces/ICreditManagerV3.sol";
import {ICreditConfigurator} from "../../interfaces/ICreditConfiguratorV3.sol";
import {ICreditFacade} from "../../interfaces/ICreditFacade.sol";
import {IPool4626} from "../../interfaces/IPool4626.sol";
import {ILPPriceFeed} from "../../interfaces/ILPPriceFeed.sol";

/// @dev
contract ControllerTimelock is MetaParamManager, IControllerTimelock {
    /// @dev Period before a mature transaction becomes stale
    uint256 public constant GRACE_PERIOD = 14 days;

    /// @dev Admin address that can configure risk-related parameters
    address public riskAdmin;

    /// @dev Admin address that can perform operational actions
    address public opsAdmin;

    /// @dev Admin address that can cancel transactions
    address public vetoAdmin;

    /// @dev Delay before a risk-related transaction can be executed
    uint256 public riskAdminDelay = 1 days;

    /// @dev Delay before an ops-related transaction can be executed
    uint256 public opsAdminDelay = 1 days;

    /// @dev Address of the corresponding Credit Manager
    ICreditManagerV3 public immutable creditManager;

    /// @dev Address of the corresponding Credit Facade
    ICreditFacade public immutable creditFacade;

    /// @dev Address of the corresponding Credit Configurator
    ICreditConfigurator public immutable creditConfigurator;

    /// @dev Address of the corresponding pool
    IPool4626 public immutable pool;

    /// @dev Mapping of transaction hashes to their data
    mapping(bytes32 => QueuedTransactionData) public queuedTransactions;

    constructor(
        address _addressProvider,
        address _creditManager,
        address _riskAdmin,
        address _opsAdmin,
        address _vetoAdmin
    ) MetaParamManager(_addressProvider) {
        riskAdmin = _riskAdmin;
        opsAdmin = _opsAdmin;
        vetoAdmin = _vetoAdmin;

        creditManager = ICreditManagerV3(_creditManager);
        creditFacade = ICreditFacade(creditManager.creditFacade());
        creditConfigurator = ICreditConfigurator(creditManager.creditConfigurator());
        pool = IPool4626(creditManager.pool());
    }

    modifier controllerAdminOnly(address requiredAdmin) {
        if (msg.sender != requiredAdmin) {
            revert CallerNotCorrectAdminException();
        }
        _;
    }

    /// @dev Queues a transaction to set a new expiration date in the Credit Facade
    /// @dev Requires metaparameters for keccak("EXPIRATION_DATE") to be initialized, otherwise auto-fails the check
    /// @param expirationDate The new expiration date
    function setExpirationDate(uint40 expirationDate) external controllerAdminOnly(opsAdmin) {
        uint40 oldExpirationDate = creditFacade.expirationDate();
        uint256 totalBorrowed = pool.creditManagerBorrowed(address(creditManager));

        if (
            !_checkParameter(string("EXPIRATION_DATE"), uint256(oldExpirationDate), uint256(expirationDate))
                || totalBorrowed != 0
        ) {
            revert ParameterChecksFailedException();
        }

        _queueTransaction({
            target: address(creditConfigurator),
            signature: "setExpirationDate(uint40)",
            data: abi.encode(expirationDate),
            eta: block.timestamp + opsAdminDelay
        });
    }

    /// @dev Queues a transaction to set a new limiter value in a price feed
    /// @dev Requires metaparameters for keccak("LP_PRICE_FEED_LIMITER", priceFeed) to be initialized, otherwise auto-fails the check
    /// @param priceFeed The price feed to update the limiter in
    /// @param lowerBound The new limiter lower bound value
    function setLPPriceFeedLimiter(address priceFeed, uint256 lowerBound) external controllerAdminOnly(opsAdmin) {
        bytes32 paramHash = keccak256(abi.encode("LP_PRICE_FEED_LIMITER", priceFeed));

        uint256 currentLowerBound = ILPPriceFeed(priceFeed).lowerBound();

        if (!_checkParameter(paramHash, currentLowerBound, lowerBound)) {
            revert ParameterChecksFailedException();
        }

        _queueTransaction({
            target: address(priceFeed),
            signature: "setLimiter(uint256)",
            data: abi.encode(lowerBound),
            eta: block.timestamp + opsAdminDelay
        });
    }

    /// @dev Queues a transaction to set a new max debt per block multiplier
    /// @dev Requires metaparameters for keccak("MAX_DEBT_PER_BLOCK_MULTIPLIER") to be initialized, otherwise auto-fails the check
    /// @param multiplier The new multiplier value
    function setMaxDebtPerBlockMultiplier(uint8 multiplier) external controllerAdminOnly(riskAdmin) {
        uint8 currentMultiplier = creditFacade.maxDebtPerBlockMultiplier();

        if (!_checkParameter(string("MAX_DEBT_PER_BLOCK_MULTIPLIER"), uint256(currentMultiplier), uint256(multiplier)))
        {
            revert ParameterChecksFailedException();
        }

        _queueTransaction({
            target: address(creditConfigurator),
            signature: "setMaxDebtPerBlockMultiplier(uint8)",
            data: abi.encode(multiplier),
            eta: block.timestamp + riskAdminDelay
        });
    }

    /// @dev Queues a transaction to set a new max debt per block multiplier
    /// @dev Requires metaparameters for keccak("MIN_DEBT") and keccak("MAX_DEBT") to be initialized, otherwise auto-fails the check
    /// @param minDebt The minimal debt amount
    /// @param maxDebt The maximal debt amount
    function setDebtLimits(uint128 minDebt, uint128 maxDebt) external controllerAdminOnly(riskAdmin) {
        (uint128 minDebtCurrent, uint128 maxDebtCurrent) = creditFacade.debtLimits();

        if (
            !_checkParameter(string("MIN_DEBT"), uint256(minDebtCurrent), uint256(minDebt))
                || !_checkParameter(string("MAX_DEBT"), uint256(maxDebtCurrent), uint256(maxDebt))
        ) {
            revert ParameterChecksFailedException();
        }

        _queueTransaction({
            target: address(creditConfigurator),
            signature: "setLimits(uint128,uint128)",
            data: abi.encode(minDebt, maxDebt),
            eta: block.timestamp + riskAdminDelay
        });
    }

    /// @dev Queues a transaction to set a new debt limit for the Credit Manager
    /// @dev Requires metaparameters for keccak("CREDIT_MANAGER_DEBT_LIMIT") to be initialized, otherwise auto-fails the check
    /// @param debtLimit The new debt limit
    function setCreditManagerDebtLimit(uint256 debtLimit) external controllerAdminOnly(riskAdmin) {
        uint256 debtLimitCurrent = pool.creditManagerLimit(address(creditManager));

        if (!_checkParameter(string("CREDIT_MANAGER_DEBT_LIMIT"), uint256(debtLimitCurrent), uint256(debtLimit))) {
            revert ParameterChecksFailedException();
        }

        _queueTransaction({
            target: address(pool),
            signature: "setCreditManagerLimit(address,uint256)",
            data: abi.encode(address(creditManager), debtLimit),
            eta: block.timestamp + riskAdminDelay
        });
    }

    /// @dev Queues a transaction to start a liquidation threshold ramp
    /// @dev Requires metaparameters for keccak("TOKEN_LT", token) to be initialized, otherwise auto-fails the check
    /// @param token Token to ramp the LT for
    /// @param liquidationThresholdFinal The liquidation threshold value after the ramp
    /// @param rampDuration Duration of the ramp
    function rampLiquidationThreshold(address token, uint16 liquidationThresholdFinal, uint24 rampDuration)
        external
        controllerAdminOnly(riskAdmin)
    {
        bytes32 paramHash = keccak256(abi.encode("TOKEN_LT", token));

        uint256 ltCurrent = creditManager.liquidationThresholds(token);

        if (
            !_checkParameter(paramHash, uint256(ltCurrent), uint256(liquidationThresholdFinal)) || rampDuration < 7 days
        ) {
            revert ParameterChecksFailedException();
        }

        _queueTransaction({
            target: address(creditConfigurator),
            signature: "rampLiquidationThreshold(address,uint16,uint24)",
            data: abi.encode(token, liquidationThresholdFinal, rampDuration),
            eta: block.timestamp + riskAdminDelay
        });
    }

    /// @dev Internal function that records the transaction into the queued tx map
    /// @param target The contract to call
    /// @param signature The signature of the called function
    /// @param data The call data
    /// @param eta The timestamp at which the transaction matures
    function _queueTransaction(address target, string memory signature, bytes memory data, uint256 eta)
        internal
        returns (bytes32)
    {
        bytes32 txHash = keccak256(abi.encode(target, signature, data, eta));

        queuedTransactions[txHash] =
            QueuedTransactionData({queued: true, target: target, eta: uint40(eta), signature: signature, data: data});

        emit QueueTransaction(txHash, target, signature, data, uint40(eta));
        return txHash;
    }

    /// @dev Sets the transaction's queued status as false, effectively cancelling it
    /// @param txHash Hash of the transaction to be cancelled
    function cancelTransaction(bytes32 txHash) external controllerAdminOnly(vetoAdmin) {
        queuedTransactions[txHash].queued = false;
        emit CancelTransaction(txHash);
    }

    /// @dev Executes a queued transaction
    /// @param txHash Hash of the transaction to be executed
    function executeTransaction(bytes32 txHash) external controllerAdminOnly(opsAdmin) {
        QueuedTransactionData memory qtd = queuedTransactions[txHash];

        if (!qtd.queued) {
            revert TxNotQueuedException();
        }

        address target = qtd.target;
        uint40 eta = qtd.eta;
        string memory signature = qtd.signature;
        bytes memory data = qtd.data;

        if (block.timestamp < eta || block.timestamp > eta + GRACE_PERIOD) {
            revert TxExecutedOutsideTimeWindowException();
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
            revert TxExecutionRevertedException();
        }

        emit ExecuteTransaction(txHash);
    }

    /// CONFIGURATION

    /// @dev Sets a new risk admin address
    function setRiskAdmin(address newAdmin) external configuratorOnly {
        riskAdmin = newAdmin;
        emit SetRiskAdmin(newAdmin);
    }

    /// @dev Sets a new ops admin address
    function setOpsAdmin(address newAdmin) external configuratorOnly {
        opsAdmin = newAdmin;
        emit SetOpsAdmin(opsAdmin);
    }

    /// @dev Sets a new veto admin address
    function setVetoAdmin(address newAdmin) external configuratorOnly {
        vetoAdmin = newAdmin;
        emit SetVetoAdmin(newAdmin);
    }

    /// @dev Sets a new risk admin delay
    function setRiskAdminDelay(uint256 newDelay) external configuratorOnly {
        riskAdminDelay = newDelay;
        emit SetRiskAdminDelay(newDelay);
    }

    /// @dev Sets a new ops admin delay
    function setOpsAdminDelay(uint256 newDelay) external configuratorOnly {
        opsAdminDelay = newDelay;
        emit SetOpsAdminDelay(newDelay);
    }
}
