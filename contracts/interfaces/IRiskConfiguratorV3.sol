// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

interface IRiskConfiguratorV3 {
    function acl() external view returns (address);

    function treasury() external view returns (address);

    function interestModelFactory() external view returns (address);

    function poolFactory() external view returns (address);

    function creditFactory() external view returns (address);

    function priceOracleFactory() external view returns (address);

    function adapterFactory() external view returns (address);

    function controller() external view returns (address);

    function pools() external view returns (address[] memory);

    /// @dev Returns true if the passed address is a pool
    function isPool(address pool) external view returns (bool);

    /// @dev Returns the array of registered Credit Managers
    function creditManagers() external view returns (address[] memory);

    /// @dev Returns true if the passed address is a Credit Manager
    function isCreditManager(address creditManager) external view returns (bool);
}
