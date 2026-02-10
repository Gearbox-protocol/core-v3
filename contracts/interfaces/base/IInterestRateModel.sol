// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {IVersion} from "./IVersion.sol";
import {IStateSerializer} from "./IStateSerializer.sol";

interface IInterestRateModel is IVersion, IStateSerializer {
    function calcBorrowRate(bytes calldata params) external returns (uint256);

    function isGreaterRate(bytes calldata paramsA, bytes calldata paramsB) external view returns (bool);

    function getCurrentGlobalIndex() external view returns (uint256);

    function getCurrentIndex(bytes calldata params, uint256 lastUpdateTimestamp) external view returns (uint256);
}
