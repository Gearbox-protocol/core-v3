// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.23;

import {USDTFees} from "../libraries/USDTFees.sol";
import {IUSDT} from "../interfaces/external/IUSDT.sol";
import {IncorrectTokenContractException, ZeroAddressException} from "../interfaces/IExceptions.sol";

/// @title USDT transfer
/// @notice Trait that allows to calculate amounts adjusted for transfer fees
contract USDT_Transfer {
    using USDTFees for uint256;

    /// @dev USDT token address
    address private immutable usdt;

    /// @notice Constructor
    /// @param  _usdt USDT token address
    /// @dev    Reverts if `_usdt` is zero address or does not implement the `IUSDT` interface
    /// @custom:tests U:[UTT-1]
    constructor(address _usdt) {
        if (_usdt == address(0)) revert ZeroAddressException();
        try IUSDT(_usdt).basisPointsRate() returns (uint256) {}
        catch {
            revert IncorrectTokenContractException();
        }
        try IUSDT(_usdt).maximumFee() returns (uint256) {}
        catch {
            revert IncorrectTokenContractException();
        }
        usdt = _usdt;
    }

    /// @dev Computes amount of USDT that should be sent to receive `amount`
    /// @custom:tests U:[UTT-2]
    function _amountUSDTWithFee(uint256 amount) internal view virtual returns (uint256) {
        uint256 basisPointsRate = _basisPointsRate();
        if (basisPointsRate == 0) return amount;
        return amount.amountUSDTWithFee({basisPointsRate: basisPointsRate, maximumFee: _maximumFee()});
    }

    /// @dev Computes amount of USDT that would be received if `amount` is sent
    /// @custom:tests U:[UTT-2]
    function _amountUSDTMinusFee(uint256 amount) internal view virtual returns (uint256) {
        uint256 basisPointsRate = _basisPointsRate();
        if (basisPointsRate == 0) return amount;
        return amount.amountUSDTMinusFee({basisPointsRate: basisPointsRate, maximumFee: _maximumFee()});
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
