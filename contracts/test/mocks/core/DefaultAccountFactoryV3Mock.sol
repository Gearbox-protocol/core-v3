// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2026.
pragma solidity ^0.8.17;

import {DefaultAccountFactoryV3} from "../../../core/DefaultAccountFactoryV3.sol";

contract DefaultAccountFactoryV3Mock is DefaultAccountFactoryV3 {
    constructor(address addressProvider) DefaultAccountFactoryV3(addressProvider) {}

    function returnCreditAccount(address) external pure override {}
}
