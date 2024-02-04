// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {BitMask, UNDERLYING_TOKEN_MASK} from "../../libraries/BitMask.sol";

import "../../interfaces/ICreditFacadeV3Multicall.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GearboxInstance} from "./Deployer.sol";

import {IPriceOracleV3} from "../../interfaces/IPriceOracleV3.sol";
import {ICreditManagerV3, CollateralCalcTask} from "../../interfaces/ICreditManagerV3.sol";
import {ICreditFacadeV3, ICreditFacadeV3Multicall} from "../../interfaces/ICreditFacadeV3.sol";
import {IPoolQuotaKeeperV3} from "../../interfaces/IPoolQuotaKeeperV3.sol";
import {MultiCall} from "../../interfaces/ICreditFacadeV3.sol";
import {MultiCallBuilder} from "../lib/MultiCallBuilder.sol";
import "forge-std/Test.sol";
import "../lib/constants.sol";
import "forge-std/console.sol";
import "forge-std/Vm.sol";

contract Random {
    error IncorrecrMinMaxException();

    uint8 pThreshold = 95;

    uint256 internal seed;

    function setSeed(uint256 _seed) internal {
        seed = _seed;
    }

    function getRandomP() internal returns (uint8) {
        return uint8(getRandomInRange(100));
    }

    function getRandomInRange95(uint256 max) internal returns (uint256) {
        return getRandomP() > pThreshold ? getNextRandomNumber() : getRandomInRange(max);
    }

    function getRandomInRange(uint256 max) internal returns (uint256) {
        return getRandomInRange(0, max);
    }

    function getRandomInRange95(uint256 min, uint256 max) internal returns (uint256) {
        return getRandomP() > pThreshold ? getNextRandomNumber() : getRandomInRange(min, max);
    }

    function getRandomInRange(uint256 min, uint256 max) internal returns (uint256) {
        if (min > max) revert IncorrecrMinMaxException();
        return max == 0 ? 0 : min + (getNextRandomNumber() % (max - min));
    }

    function getNextRandomNumber() internal returns (uint256) {
        seed = uint256(keccak256(abi.encodePacked(seed)));
        return seed;
    }
}
