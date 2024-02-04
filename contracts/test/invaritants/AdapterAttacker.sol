// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AdapterType} from "@gearbox-protocol/sdk-gov/contracts/AdapterType.sol";
import {IAdapter} from "@gearbox-protocol/core-v2/contracts/interfaces/IAdapter.sol";

import {ICreditManagerV3} from "../../interfaces/ICreditManagerV3.sol";
import {TargetAttacker} from "./TargetAttacker.sol";

/// @title Adapter Mock
contract AdapterAttacker is IAdapter {
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

    function executeAllApprove(bytes memory callData)
        external
        returns (uint256 tokensToEnable, uint256 tokensToDisable, bytes memory result)
    {
        uint256 len = ICreditManagerV3(creditManager).collateralTokensCount();

        for (uint256 i; i < len; ++i) {
            (address token,) = ICreditManagerV3(creditManager).collateralTokenByMask(1 << i);
            _approveToken(token, type(uint256).max);
        }

        result = _execute(abi.encodeCall(TargetAttacker.act, (_seed)));

        for (uint256 i; i < len; ++i) {
            (address token,) = ICreditManagerV3(creditManager).collateralTokenByMask(1 << i);
            _approveToken(token, 1);
        }

        address tokenIn = TargetAttacker(targetContract).tokenIn();
        if (tokenIn != address(0)) {
            uint256 balance = IERC20(tokenIn).balanceOf(TargetAttacker(targetContract).creditAccount());
            if (balance > 1) {
                tokensToEnable = ICreditManagerV3(creditManager).getTokenMaskOrRevert(tokenIn);
            }
        }

        address tokenOut = TargetAttacker(targetContract).tokenOut();
        if (tokenOut != address(0)) {
            uint256 balance = IERC20(tokenOut).balanceOf(TargetAttacker(targetContract).creditAccount());
            if (balance <= 1) {
                tokensToDisable = ICreditManagerV3(creditManager).getTokenMaskOrRevert(tokenOut);
            }
        }
    }

    function _execute(bytes memory data) internal returns (bytes memory result) {
        result = ICreditManagerV3(creditManager).execute(data);
    }

    function _approveToken(address token, uint256 amount) internal {
        ICreditManagerV3(creditManager).approveCreditAccount(token, amount);
    }
}
