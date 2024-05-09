// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {ContractsRegisterTrait} from "../traits/ContractsRegisterTrait.sol";

contract ContractRegisterMixinLegacy is ContractsRegisterTrait {
    constructor(address cr) ContractsRegisterTrait(cr) {}
}
