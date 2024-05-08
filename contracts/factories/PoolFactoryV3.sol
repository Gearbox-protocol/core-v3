// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IVersion} from "@gearbox-protocol/core-v2/contracts/interfaces/IVersion.sol";

contract PoolFactoryV3 is IVersion {
    using EnumerableSet for EnumerableSet.AddressSet;
    /// @notice Contract version

    uint256 public constant override version = 3_10;

    modifier registeredCuratorsOnly() {
        _;
    }

    function deploy(address underlying, uint256 totalLimit, uint8 rateKeeperType) external returns (address pool) {}
}
