// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {BorrowerOrder, LenderOrder} from "../IMatchingEngineV3.sol";

interface IValidationStrategy {
    function validate(LenderOrder calldata lender, BorrowerOrder calldata borrower) external view returns (bool);
}
