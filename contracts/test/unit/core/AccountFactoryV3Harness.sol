// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2023
pragma solidity ^0.8.17;

import {AccountFactoryV3, FactoryParams, QueuedAccount} from "../../../core/AccountFactoryV3.sol";

contract AccountFactoryV3Harness is AccountFactoryV3 {
    constructor(address addressProvider) AccountFactoryV3(addressProvider) {}

    function queuedAccounts(address creditManager, uint256 index) external view returns (QueuedAccount memory) {
        return _queuedAccounts[creditManager][index];
    }

    function initQueuedAccounts(address creditManager, uint256 tail) external {
        QueuedAccount memory qa;
        for (uint256 i; i < tail; ++i) {
            _queuedAccounts[creditManager].push(qa);
        }
    }

    function setQueuedAccount(address creditManager, uint256 index, address creditAccount, uint40 reusableAfter)
        external
    {
        _queuedAccounts[creditManager][index] = QueuedAccount(creditAccount, reusableAfter);
    }

    function factoryParams(address creditManager) external view returns (FactoryParams memory) {
        return _factoryParams[creditManager];
    }

    function setFactoryParams(address creditManager, address masterCreditAccount, uint40 head, uint40 tail) external {
        _factoryParams[creditManager] = FactoryParams(masterCreditAccount, head, tail);
    }
}
