pragma solidity ^0.8.17;

interface ITimeLock {
    function queueTransaction(address target, uint256 value, string memory signature, bytes memory data, uint256 eta)
        external
        returns (bytes32);

    function executeTransaction(address target, uint256 value, string memory signature, bytes memory data, uint256 eta)
        external
        payable
        returns (bytes memory);

    function cancelTransaction(address target, uint256 value, string memory signature, bytes memory data, uint256 eta)
        external;

    function acceptAdmin() external;
}
