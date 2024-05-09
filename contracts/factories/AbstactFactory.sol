// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {APOwnerTrait} from "../traits/APOwnerTrait.sol";
import {IAddressProviderV3, AP_BYTECODE_REPOSITORY, NO_VERSION} from "../interfaces/IAddressProviderV3.sol";

abstract contract AbstractFactory is APOwnerTrait {
    address immutable bytecodeRepository;

    error CallerIsNotMarketConfiguratorException();

    modifier marketConfiguratorOnly() {
        if (IAddressProviderV3(_addressProvider).isMarketConfigurator(msg.sender)) {
            revert CallerIsNotMarketConfiguratorException();
        }
        _;
    }

    constructor(address _addressProvider) APOwnerTrait(_addressProvider) {
        bytecodeRepository = IAddressProviderV3(_addressProvider).getAddressOrRevert(AP_BYTECODE_REPOSITORY, NO_VERSION);
    }
}
