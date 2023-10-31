// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {WithdrawalManagerV3} from "../../../core/WithdrawalManagerV3.sol";

contract WithdrawalManagerV3Harness is WithdrawalManagerV3 {
    constructor(address _addressProvider) WithdrawalManagerV3(_addressProvider) {}
}
