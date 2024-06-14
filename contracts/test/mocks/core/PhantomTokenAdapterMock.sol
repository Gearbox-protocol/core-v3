// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {AdapterType} from "@gearbox-protocol/sdk-gov/contracts/AdapterType.sol";
import {ICreditManagerV3} from "../../../interfaces/ICreditManagerV3.sol";
import {IAdapter} from "../../../interfaces/base/IAdapter.sol";

/// @title Adapter Mock
contract PhantomTokenAdapterMock is IAdapter {
    AdapterType public constant override _gearboxAdapterType = AdapterType.ABSTRACT;
    uint16 public constant override _gearboxAdapterVersion = 1;

    address public immutable override creditManager;
    address public immutable override targetContract;

    constructor(address _creditManager, address _targetContract) {
        creditManager = _creditManager;
        targetContract = _targetContract;
    }

    function withdrawalCall(address creditAccount, address amount)
        external
        returns (uint256 tokensToEnable, uint256 tokensToDisable)
    {
        _execute(msg.data);
    }

    fallback() external {
        _execute(msg.data);
    }

    function _execute(bytes memory data) internal returns (bytes memory result) {
        result = ICreditManagerV3(creditManager).execute(data);
    }
}
