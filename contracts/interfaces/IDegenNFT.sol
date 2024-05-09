// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import {IVersion} from "./IVersion.sol";

interface IDegenNFT is IVersion, IERC721Metadata {
    function totalSupply() external view returns (uint256);
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;

    function minter() external view returns (address);
    function setMinter(address) external;

    function addCreditFacade(address) external;
}
