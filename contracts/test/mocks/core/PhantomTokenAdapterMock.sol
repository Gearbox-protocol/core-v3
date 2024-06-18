// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {AdapterType} from "@gearbox-protocol/sdk-gov/contracts/AdapterType.sol";
import {ICreditManagerV3} from "../../../interfaces/ICreditManagerV3.sol";
import {IAdapter} from "../../../interfaces/base/IAdapter.sol";
import {ERC20Mock} from "../token/ERC20Mock.sol";

/// @title Adapter Mock
contract PhantomTokenAdapterMock is IAdapter {
    AdapterType public constant override _gearboxAdapterType = AdapterType.ABSTRACT;
    uint16 public constant override _gearboxAdapterVersion = 1;

    address public immutable override creditManager;
    address public immutable override targetContract;

    address public immutable phantomTokenUnderlying;

    constructor(address _creditManager, address _targetContract, address _phantomTokenUnderlying) {
        creditManager = _creditManager;
        targetContract = _targetContract;
        phantomTokenUnderlying = _phantomTokenUnderlying;
    }

    function withdrawalCall(address creditAccount, uint256 amount)
        external
        returns (uint256 tokensToEnable, uint256 tokensToDisable)
    {
        _execute(msg.data);
        ERC20Mock(targetContract).burn(creditAccount, amount);
        ERC20Mock(phantomTokenUnderlying).mint(creditAccount, amount);
    }

    fallback() external {
        _execute(msg.data);
    }

    function _execute(bytes memory data) internal returns (bytes memory result) {
        result = ICreditManagerV3(creditManager).execute(data);
    }

    function serialize() external view returns (AdapterType, uint16, bytes[] memory) {
        return (AdapterType.ABSTRACT, 0, new bytes[](0));
    }
}
