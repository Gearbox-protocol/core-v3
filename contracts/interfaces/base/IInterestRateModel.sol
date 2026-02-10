// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {IVersion} from "./IVersion.sol";
import {IStateSerializer} from "./IStateSerializer.sol";

interface IInterestRateModel is IVersion, IStateSerializer {
    function calcBorrowRate() external returns (uint256);

    function isGreaterOrEqualRate(address otherIrm) external view returns (bool);

    function getCurrentIndex() external view returns (uint256);
}
