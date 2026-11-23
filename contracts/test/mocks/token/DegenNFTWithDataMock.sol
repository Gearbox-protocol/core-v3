// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {IDegenNFTWithData} from "../../../interfaces/base/IDegenNFT.sol";
import {InsufficientBalanceException} from "../../../interfaces/IExceptions.sol";

/// @notice Mock DegenNFT that supports burning with extra data (e.g. SignatureDegenNFT)
contract DegenNFTWithDataMock is IDegenNFTWithData {
    uint256 public constant override version = 3_10;
    bytes32 public constant override contractType = "DEGEN_NFT::MOCK_WITH_DATA";

    mapping(address => uint256) public balances;

    address public lastBurnFrom;
    uint256 public lastBurnAmount;
    bytes public lastBurnData;
    uint256 public burnWithDataCalls;

    function serialize() external view override returns (bytes memory) {}

    function mint(address to, uint256 amount) external {
        balances[to] += amount;
    }

    function burn(address from, uint256 amount) external {
        uint256 balance = balances[from];
        if (balance < amount) revert InsufficientBalanceException();
        balances[from] = balance - amount;

        lastBurnFrom = from;
        lastBurnAmount = amount;
        lastBurnData = "";
    }

    function burn(address from, uint256 amount, bytes calldata data) external {
        uint256 balance = balances[from];
        if (balance < amount) revert InsufficientBalanceException();
        balances[from] = balance - amount;

        lastBurnFrom = from;
        lastBurnAmount = amount;
        lastBurnData = data;
        burnWithDataCalls++;
    }
}
