// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {AdapterType} from "@gearbox-protocol/sdk-gov/contracts/AdapterType.sol";
import {IAdapter} from "@gearbox-protocol/core-v2/contracts/interfaces/IAdapter.sol";

import {ICreditManagerV3} from "../../../interfaces/ICreditManagerV3.sol";

/// @title Adapter Mock
contract AdapterMock is IAdapter {
    AdapterType public constant override _gearboxAdapterType = AdapterType.ABSTRACT;
    uint16 public constant override _gearboxAdapterVersion = 1;

    address public immutable override creditManager;
    address public immutable override addressProvider;
    address public immutable override targetContract;

    constructor(address _creditManager, address _targetContract) {
        creditManager = _creditManager;
        addressProvider = ICreditManagerV3(_creditManager).addressProvider();
        targetContract = _targetContract;
    }

    function executeSwapSafeApprove(address tokenIn, address tokenOut, bytes memory callData, bool disableTokenIn)
        external
        returns (uint256 tokensToEnable, uint256 tokensToDisable, bytes memory result)
    {
        tokensToEnable = _getMaskOrRevert(tokenOut);
        if (disableTokenIn) tokensToDisable = _getMaskOrRevert(tokenIn);
        _approveToken(tokenIn, type(uint256).max);
        result = _execute(callData);
        _approveToken(tokenIn, 1);
    }

    function dumbCall(uint256 _tokensToEnable, uint256 _tokensToDisable)
        external
        returns (uint256 tokensToEnable, uint256 tokensToDisable)
    {
        _execute(dumbCallData());
        tokensToEnable = _tokensToEnable;
        tokensToDisable = _tokensToDisable;
    }

    function dumbCallData() public pure returns (bytes memory) {
        return abi.encodeWithSignature("hello(string)", "world");
    }

    fallback() external {
        _execute(msg.data);
    }

    function _getMaskOrRevert(address token) internal view returns (uint256 tokenMask) {
        tokenMask = ICreditManagerV3(creditManager).getTokenMaskOrRevert(token);
    }

    function _execute(bytes memory data) internal returns (bytes memory result) {
        result = ICreditManagerV3(creditManager).execute(data);
    }

    function _approveToken(address token, uint256 amount) internal {
        ICreditManagerV3(creditManager).approveCreditAccount(token, amount);
    }
}
