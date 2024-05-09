// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IDegenNFT} from "../../../interfaces/IDegenNFT.sol";
import {InsufficientBalanceException} from "../../../interfaces/IExceptions.sol";

contract DegenNFTMock is ERC721, IDegenNFT {
    uint256 public constant override version = 3_00;
    uint256 public override totalSupply;

    constructor(string memory name, string memory symbol) ERC721(name, symbol) {}

    function mint(address to, uint256 amount) external override {
        uint256 balanceBefore = balanceOf(to);
        for (uint256 i; i < amount; ++i) {
            uint256 tokenId = (uint256(uint160(to)) << 40) + balanceBefore + i;
            _mint(to, tokenId);
        }
        totalSupply += amount;
    }

    function burn(address from, uint256 amount) external override {
        uint256 balance = balanceOf(from);
        if (balance < amount) {
            revert InsufficientBalanceException();
        }
        for (uint256 i; i < amount; ++i) {
            uint256 tokenId = (uint256(uint160(from)) << 40) + balance - i - 1;
            _burn(tokenId);
        }
        totalSupply -= amount;
    }

    function minter() external view override returns (address) {}

    function setMinter(address) external override {}

    function addCreditFacade(address) external override {}
}
