// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {USDTFees} from "../libraries/USDTFees.sol";
import {IUSDT} from "../interfaces/external/IUSDT.sol";

/// @title USDT transfer
/// @notice Trait that allows to calculate amounts adjusted for transfer fees
contract USDT_Transfer {
    using USDTFees for uint256;

    /// @dev USDT token address
    address private immutable usdt;

    constructor(address _usdt) {
        usdt = _usdt;
    }

    /// @dev Computes amount of USDT that should be sent to receive `amount`
    function _amountUSDTWithFee(uint256 amount) internal view virtual returns (uint256) {
        uint256 basisPointsRate = _basisPointsRate(); // U:[UTT_01]
        if (basisPointsRate == 0) return amount;
        return amount.amountUSDTWithFee({basisPointsRate: basisPointsRate, maximumFee: _maximumFee()}); // U:[UTT_01]
    }

    /// @dev Computes amount of USDT that would be received if `amount` is sent
    function _amountUSDTMinusFee(uint256 amount) internal view virtual returns (uint256) {
        uint256 basisPointsRate = _basisPointsRate(); // U:[UTT_01]
        if (basisPointsRate == 0) return amount;
        return amount.amountUSDTMinusFee({basisPointsRate: basisPointsRate, maximumFee: _maximumFee()}); // U:[UTT_01]
    }

    /// @dev Returns fee rate in bps
    function _basisPointsRate() internal view returns (uint256) {
        return IUSDT(usdt).basisPointsRate();
    }

    /// @dev Returns maximum absolute fee
    function _maximumFee() internal view returns (uint256) {
        return IUSDT(usdt).maximumFee();
    }
}
