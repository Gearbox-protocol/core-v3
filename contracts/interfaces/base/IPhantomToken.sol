// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.23;

import {IVersion} from "./IVersion.sol";

interface IPhantomToken is IVersion {
    function getWithdrawalMultiCall(address creditAccount, uint256 amount)
        external
        view
        returns (address tokenOut, uint256 amountOut, address targetContract, bytes memory callData);
}
