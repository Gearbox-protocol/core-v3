// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {DefaultAccountFactoryV3} from "../../../core/DefaultAccountFactoryV3.sol";

contract DefaultAccountFactoryV3Harness is DefaultAccountFactoryV3 {
    constructor(address addressProvider) DefaultAccountFactoryV3(addressProvider) {}

    function masterCreditAccount(address creditManager) external view returns (address) {
        return _masterCreditAccounts[creditManager];
    }

    function setMasterCreditAccount(address creditManager, address masterCreditAccount_) external {
        _masterCreditAccounts[creditManager] = masterCreditAccount_;
    }
}
