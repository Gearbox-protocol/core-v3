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
    uint256 public constant override version = 3_10;
    bytes32 public constant override contractType = "AD_MOCK_PHANTOM";

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
}
