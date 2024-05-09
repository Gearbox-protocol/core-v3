// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {IContractsRegister} from "./IContractsRegister.sol";

interface IMarketConfiguratorV3 is IContractsRegister {
    /// @notice Risc curator who manages these markets
    function owner() external view returns (address);

    /// @notice Treasure address
    function treasury() external view returns (address);

    function addressProvider() external view returns (address);

    function acl() external view returns (address);

    function interestModelFactory() external view returns (address);

    function poolFactory() external view returns (address);

    function creditFactory() external view returns (address);

    function priceOracleFactory() external view returns (address);

    function adapterFactory() external view returns (address);

    function controller() external view returns (address);
}
