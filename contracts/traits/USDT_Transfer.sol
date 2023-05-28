// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import {USDTFees} from "../libraries/USDTFees.sol";

interface IUSDT {
    function basisPointsRate() external view returns (uint256);

    function maximumFee() external view returns (uint256);
}

contract USDT_Transfer {
    using USDTFees for uint256;

    address private immutable usdt;

    constructor(address _usdt) {
        usdt = _usdt;
    }

    /// @dev Computes how much usdt you should send to get exact amount on destination account
    function _amountUSDTWithFee(uint256 amount) internal view virtual returns (uint256) {
        uint256 basisPointsRate = IUSDT(usdt).basisPointsRate(); // U:[UTT_01]
        uint256 maximumFee = IUSDT(usdt).maximumFee(); // U:[UTT_01]
        return amount.amountUSDTWithFee({basisPointsRate: basisPointsRate, maximumFee: maximumFee}); // U:[UTT_01]
    }

    /// @dev Computes how much usdt you should send to get exact amount on destination account
    function _amountUSDTMinusFee(uint256 amount) internal view virtual returns (uint256) {
        uint256 basisPointsRate = IUSDT(usdt).basisPointsRate(); // U:[UTT_01]
        uint256 maximumFee = IUSDT(usdt).maximumFee(); // U:[UTT_01]
        return amount.amountUSDTMinusFee({basisPointsRate: basisPointsRate, maximumFee: maximumFee}); // U:[UTT_01]
    }
}
