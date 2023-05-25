// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2023
pragma solidity ^0.8.17;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";

import {AbstractAdapter} from "../../../adapters/AbstractAdapter.sol";
import {AdapterType} from "../../../interfaces/IAdapter.sol";

contract AdapterCallMock {
    using Address for address;

    function makeCall(address target, bytes memory data) external returns (uint256, uint256) {
        target.functionCall(data);
    }
}
