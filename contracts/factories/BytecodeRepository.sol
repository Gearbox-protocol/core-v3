// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {IBytecodeRepository} from "./IBytecodeRepository.sol";

struct BytecodeInfo {
    string contractType;
    uint256 version;
    address[] auditors;
}

contract BytecodeRepository is IBytecodeRepository {
    using EnumerableSet for EnumerableSet.UintSet;
    /// @notice Contract version

    uint256 public constant override version = 3_10;

    error BytecodeNotFound(bytes32 _hash);
    error BytecodeAllreadyExists(string contractType, uint256 version);

    mapping(bytes32 => bytes) internal _bytecode;
    mapping(bytes32 => BytecodeInfo) public bytecodeInfo;

    EnumerableSet.UintSet internal _hashStorage;

    function deploy(string memory contactType, uint256 _version, bytes memory constructorParams, bytes32 salt)
        external
        override
        returns (address)
    {
        bytes32 _hash = computeBytecodeHash(contactType, _version);

        bytes memory bytecode = _bytecode[_hash];
        if (bytecode.length == 0) {
            revert BytecodeNotFound(_hash);
        }

        bytes memory bytecodeWithParams = abi.encodePacked(bytecode, constructorParams);

        return Create2.deploy(0, salt, bytecodeWithParams);
    }

    function loadByteCode(string memory contractType, uint256 _version, bytes calldata bytecode) external {
        bytes32 _hash = computeBytecodeHash(contractType, _version);
        if (_hashStorage.contains(uint256(_hash))) {
            revert BytecodeAllreadyExists(contractType, _version);
        }

        _bytecode[_hash] = bytecode;
        bytecodeInfo[_hash].contractType = contractType;
        bytecodeInfo[_hash].version = version;
        _hashStorage.add(uint256(_hash));
    }

    function computeBytecodeHash(string memory contractType, uint256 _version) public pure returns (bytes32) {
        return keccak256(abi.encode(contractType, _version));
    }

    function allBytecodeHashes() public view returns (bytes32[] memory result) {
        uint256[] memory poiner = _hashStorage.values();

        /// @solidity memory-safe-assembly
        assembly {
            result := poiner
        }
    }

    function allBytecodeInfo() external view returns (BytecodeInfo[] memory result) {
        bytes32[] memory _hashes = allBytecodeHashes();
        uint256 len = _hashes.length;
        result = new BytecodeInfo[](len);
        unchecked {
            for (uint256 i; i < len; ++i) {
                result[i] = bytecodeInfo[_hashes[i]];
            }
        }
    }
}
