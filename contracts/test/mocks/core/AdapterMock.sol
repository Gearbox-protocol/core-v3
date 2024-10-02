// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {ICreditManagerV3} from "../../../interfaces/ICreditManagerV3.sol";
import {IAdapter} from "../../../interfaces/base/IAdapter.sol";

/// @title Adapter Mock
contract AdapterMock is IAdapter {
    uint256 public constant override version = 3_10;
    bytes32 public constant override contractType = "ADAPTER_MOCK";

    address public immutable override creditManager;
    address public immutable override targetContract;

    bool internal _return_useSafePrices;

    constructor(address _creditManager, address _targetContract) {
        creditManager = _creditManager;
        targetContract = _targetContract;
    }

    function dumbCall() external returns (bool) {
        _execute(dumbCallData());
        return _return_useSafePrices;
    }

    function dumbCallData() public pure returns (bytes memory) {
        return abi.encodeWithSignature("hello(string)", "world");
    }

    fallback(bytes calldata) external returns (bytes memory) {
        (bool success,) = targetContract.call(msg.data);
        require(success);
        return abi.encode(_return_useSafePrices);
    }

    function setReturn_useSafePrices(bool value) external {
        _return_useSafePrices = value;
    }

    function _execute(bytes memory data) internal returns (bytes memory result) {
        result = ICreditManagerV3(creditManager).execute(data);
    }
}
