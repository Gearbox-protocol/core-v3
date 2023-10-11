pragma solidity ^0.8.17;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {TimeLockTx, IGovernorV3} from "../interfaces/IGovernorV3.sol";
import {ITimeLock} from "../interfaces/ITimeLock.sol";

enum TxAction {
    Execute,
    Cancel
}

uint256 constant BATCH_SIZE_BITS = 16;

contract GovernorV3 is IGovernorV3 {
    using EnumerableSet for EnumerableSet.AddressSet;

    address public immutable override timeLock;

    EnumerableSet.AddressSet internal queueAdmins;

    address public override vetoAdmin;

    /// Batches
    uint240 public override batchNum;
    uint16 index;
    bool _batchMode;

    mapping(bytes32 => uint256) public override batchedTransactions;
    mapping(uint240 => uint256) public override batchedTransactionsCount;

    modifier queueAdminOnly() {
        if (!queueAdmins.contains(msg.sender)) revert CallerNotQueueAdminException();
        _;
    }

    modifier timeLockOnly() {
        if (msg.sender != timeLock) revert CallerNotTimelockException();

        _;
    }

    modifier vetoAdminOnly() {
        if (msg.sender != vetoAdmin) revert CallerNotVetoAdminException();

        _;
    }

    constructor(address _timeLock, address _queueAdmin, address _vetoAdmin) {
        timeLock = _timeLock;
        _addQueueAdmin(_queueAdmin);
        _updateVetoAdmin(_vetoAdmin);
        batchNum = 1;
    }

    // QUEUE

    function queueTransaction(address target, uint256 value, string memory signature, bytes memory data, uint256 eta)
        external
        override
        queueAdminOnly
        returns (bytes32)
    {
        if (_batchMode) {
            if (batchNum == block.number) {
                bytes32 txHash = keccak256(abi.encode(target, value, signature, data, eta));
                if (batchedTransactions[txHash] != 0) {
                    revert TxHashCollisionException(target, value, signature, data, eta);
                }

                uint16 indexCached = index;

                batchedTransactions[txHash] = uint256(batchNum) << BATCH_SIZE_BITS | indexCached;
                ++indexCached;

                index = indexCached;
                batchedTransactionsCount[batchNum] = indexCached;
            } else {
                _batchMode = false;
                index = 0;
            }
        }
        return ITimeLock(timeLock).queueTransaction(target, value, signature, data, eta);
    }

    function startBatch() external override queueAdminOnly {
        if (batchNum == block.number) {
            revert CantStartTwoBatchesInOneBlockException();
        }

        index = 0;
        batchNum = uint240(block.number);
        _batchMode = true;

        emit StartBatch();
    }

    function finishBatch() external override queueAdminOnly {
        if (batchNum == block.number) {
            _batchMode = false;
            emit FinishBatch();
        }
    }

    // EXECUTE

    function executeTransaction(address target, uint256 value, string memory signature, bytes memory data, uint256 eta)
        external
        payable
        override
        returns (bytes memory)
    {
        return _operation(target, value, signature, data, eta, TxAction.Execute);
    }

    function executeBatch(TimeLockTx[] calldata txs) external payable override {
        uint240 _batchNum = _batch(txs, TxAction.Execute);
        emit ExecuteBatch(_batchNum);
    }

    // CANCELLATION
    function cancelTransaction(address target, uint256 value, string memory signature, bytes memory data, uint256 eta)
        external
        override
        vetoAdminOnly
    {
        _operation(target, value, signature, data, eta, TxAction.Cancel);
    }

    function cancelBatch(TimeLockTx[] calldata txs) external override vetoAdminOnly {
        uint240 _batchNum = _batch(txs, TxAction.Cancel);
        emit CancelBatch(_batchNum);
    }

    // INTERNAL

    function _operation(
        address target,
        uint256 value,
        string memory signature,
        bytes memory data,
        uint256 eta,
        TxAction action
    ) internal returns (bytes memory result) {
        bytes32 txHash = keccak256(abi.encode(target, value, signature, data, eta));
        if (batchedTransactions[txHash] != 0) revert TxCouldNotBeExecutedOutsideTheBatchException();

        if (action == TxAction.Execute) {
            result = ITimeLock(timeLock).executeTransaction{value: value}(target, value, signature, data, eta);
        } else {
            ITimeLock(timeLock).cancelTransaction(target, value, signature, data, eta);
        }
    }

    function _batch(TimeLockTx[] calldata txs, TxAction action) internal returns (uint240) {
        uint256 len = txs.length;
        if (len == 0) revert IncorrectBatchLengthException();

        uint256 batchShifted = batchedTransactions[getTxHash(txs[0])];
        uint240 _batchNum = uint240(batchShifted >> BATCH_SIZE_BITS);
        if (_batchNum == 0) revert BatchNotFoundException();

        if (batchedTransactionsCount[_batchNum] != len) revert IncorrectBatchLengthException();

        unchecked {
            for (uint256 i = 0; i < len; ++i) {
                TimeLockTx calldata ttx = txs[i];
                bytes32 txHash = getTxHash(ttx);

                if (batchedTransactions[txHash] != batchShifted | i) {
                    revert TxIncorrectOrder(ttx.target, ttx.value, ttx.signature, ttx.data, ttx.eta);
                }

                if (action == TxAction.Execute) {
                    ITimeLock(timeLock).executeTransaction{value: ttx.value}(
                        ttx.target, ttx.value, ttx.signature, ttx.data, ttx.eta
                    );
                } else {
                    ITimeLock(timeLock).cancelTransaction(ttx.target, ttx.value, ttx.signature, ttx.data, ttx.eta);
                }

                delete batchedTransactions[txHash];
            }
        }

        delete batchedTransactionsCount[_batchNum];

        return _batchNum;
    }

    // GETTERS

    function getTxHash(TimeLockTx calldata ttx) public pure returns (bytes32) {
        return keccak256(abi.encode(ttx.target, ttx.value, ttx.signature, ttx.data, ttx.eta));
    }

    function getQueueAdmins() external view override returns (address[] memory) {
        return queueAdmins.values();
    }

    /// Setting admins
    function addQueueAdmin(address _admin) external override timeLockOnly {
        _addQueueAdmin(_admin);
    }

    function _addQueueAdmin(address _admin) internal {
        if (!queueAdmins.contains(_admin)) {
            queueAdmins.add(_admin);
            emit AddQueueAdmin(_admin);
        }
    }

    function removeQueueAdmin(address _admin) external override timeLockOnly {
        if (queueAdmins.contains(_admin)) {
            if (queueAdmins.length() == 1) revert CantRemoveLastQueueAdminException();

            queueAdmins.remove(_admin);
            emit RemoveQueueAdmin(_admin);
        }
    }

    function updateVetoAdmin(address _admin) external override timeLockOnly {
        _updateVetoAdmin(_admin);
    }

    function _updateVetoAdmin(address _vetoAdmin) internal {
        vetoAdmin = _vetoAdmin;
        emit UpdateVetoAdmin(vetoAdmin);
    }

    function claimTimeLockOwnership() external queueAdminOnly {
        ITimeLock(timeLock).acceptAdmin();
    }
}
