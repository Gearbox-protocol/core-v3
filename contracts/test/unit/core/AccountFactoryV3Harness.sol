// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {AccountFactoryV3, FactoryParams, QueuedAccount} from "../../../core/AccountFactoryV3.sol";

contract AccountFactoryV3Harness is AccountFactoryV3 {
    constructor(address addressProvider) AccountFactoryV3(addressProvider) {}

    function queuedAccounts(address creditManager, uint256 index) external view returns (QueuedAccount memory) {
        return _queuedAccounts[creditManager][index];
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
