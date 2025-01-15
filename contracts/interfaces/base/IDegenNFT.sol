// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {IVersion} from "./IVersion.sol";

/// @title Degen NFT interface
/// @notice Generic interface for a Degen NFT contract that can be used to restrict
///         non-whitelisted users from opening accounts through the credit facade
/// @dev Degen NFTs must have type `DEGEN_NFT::{POSTFIX}`
interface IDegenNFT is IVersion {
    function burn(address from, uint256 amount) external;
}
