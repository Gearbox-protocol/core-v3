// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {TumblerV3} from "../../../pool/TumblerV3.sol";

contract TumblerV3Harness is TumblerV3 {
    constructor(address acl, address pool_, uint256 epochLength_) TumblerV3(acl, pool_, epochLength_) {}

    function exposed_addToken(address token) external {
        _addToken(token);
    }

    function exposed_setRate(address token, uint16 rate) external {
        _setRate(token, rate);
    }
}
