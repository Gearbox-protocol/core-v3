// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2023
pragma solidity ^0.8.17;

import {IVersion} from "./IVersion.sol";

interface IWETHGatewayEvents {
    /// @notice Emitted when WETH is deposited to the gateway
    event Deposit(address indexed to, uint256 amount);
    /// @notice Emitted when ETH is claimed from the gateway
    event Claim(address indexed to, uint256 amount);
}

/// @title WETH gateway interface
interface IWETHGateway is IVersion, IWETHGatewayEvents {
    /// @notice WETH contract address
    function weth() external view returns (address);

    /// @notice Returns `owner`'s balance of withdrawable WETH
    function balanceOf(address owner) external view returns (uint256);

    /// @notice Increases `to`'s withdrawable WETH balance by `amount`, can only be called by credit managers
    /// @custom:expects Credit manager transferred `amount` of WETH to this contract prior to calling this function
    function deposit(address to, uint256 amount) external;

    /// @notice Unwraps and claims all `owner`'s balance of withdrawable WETH
    function claim(address owner) external;
}
