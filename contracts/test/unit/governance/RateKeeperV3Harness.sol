// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {RateKeeperV3} from "../../../governance/RateKeeperV3.sol";

contract RateKeeperV3Harness is RateKeeperV3 {
    constructor(address pool_, uint256 epochLength_) RateKeeperV3(pool_, epochLength_) {}

    function exposed_addToken(address token) external {
        _addToken(token);
    }

    function exposed_setRate(address token, uint16 rate) external {
        _setRate(token, rate);
    }
}
