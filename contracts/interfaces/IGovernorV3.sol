pragma solidity ^0.8.17;

struct TimeLockTx {
    address target;
    uint256 value;
    string signature;
    bytes data;
    uint256 eta;
}

interface IGovernorV3Events {
    event SealBatch(uint256 indexed batchNum, uint256 length);

    event ExecuteBatch(uint256 indexed batchNum);

    event CancelBatch(uint256 indexed batchNum);

    event AddQueueAdmin(address indexed admin);

    event RemoveQueueAdmin(address indexed admin);

    event UpdateVetoAdmin(address indexed vetoAdmin);
}

interface IGovernorV3 is IGovernorV3Events {
    error CallerNotQueueAdminException();

    error CallerNotTimelockException();

    error CallerNotVetoAdminException();

    error CantRemoveLastQueueAdminException();

    error TxHashCollisionException(address target, uint256 value, string signature, bytes data, uint256 eta);

    error TxIncorrectOrder(address target, uint256 value, string signature, bytes data, uint256 eta);

    error TxCouldNotBeExecutedOutsideTheBatchException();

    error IncorrectBatchLengthException();

    error BatchNotFoundException();

    function queueTransaction(address target, uint256 value, string memory signature, bytes memory data, uint256 eta)
        external
        returns (bytes32);

    function executeTransaction(address target, uint256 value, string memory signature, bytes memory data, uint256 eta)
        external
        payable
        returns (bytes memory);

    function sealBatch(TimeLockTx[] calldata txs) external;

    function executeBatch(TimeLockTx[] calldata txs) external payable;

    function cancelBatch(TimeLockTx[] calldata txs) external;

    /// GETTERS

    function getTxHash(TimeLockTx calldata ttx) external pure returns (bytes32);

    function timeLock() external view returns (address);

    function vetoAdmin() external view returns (address);

    function batchNum() external view returns (uint240);

    function batchedTransactions(bytes32) external view returns (uint256);

    function batchedTransactionsCount(uint240) external view returns (uint256);

    // CONFIGURE

    function addQueueAdmin(address _admin) external;

    function removeQueueAdmin(address _admin) external;

    function updateVetoAdmin(address _admin) external;
}
