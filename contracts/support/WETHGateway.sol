// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2023
pragma solidity ^0.8.17;
pragma abicoder v1;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";

import {IWETH} from "@gearbox-protocol/core-v2/contracts/interfaces/external/IWETH.sol";

import {AP_WETH_TOKEN, IAddressProviderV3, NO_VERSION_CONTROL} from "../interfaces/IAddressProviderV3.sol";
import {ReceiveIsNotAllowedException} from "../interfaces/IExceptions.sol";
import {IVersion} from "../interfaces/IVersion.sol";
import {IWETHGateway} from "../interfaces/IWETHGateway.sol";

import {ContractsRegisterTrait} from "../traits/ContractsRegisterTrait.sol";
import {ReentrancyGuardTrait} from "../traits/ReentrancyGuardTrait.sol";

/// @title WETH gateway
/// @notice Allows to unwrap WETH upon credit account closure/liquidation
contract WETHGateway is IWETHGateway, ReentrancyGuardTrait, ContractsRegisterTrait {
    using Address for address payable;

    /// @inheritdoc IVersion
    uint256 public constant override version = 3_00;

    /// @inheritdoc IWETHGateway
    address public immutable weth;

    /// @inheritdoc IWETHGateway
    mapping(address => uint256) public override balanceOf;

    /// @notice Constructor
    /// @param addressProvider_ Address provider contract address
    constructor(address addressProvider_)
        ContractsRegisterTrait(addressProvider_) // U:[WG-1A]
    {
        weth = IAddressProviderV3(addressProvider_).getAddressOrRevert(AP_WETH_TOKEN, NO_VERSION_CONTROL); // U:[WG-1B]
    }

    /// @notice Allows this contract to unwrap WETH and forbids receiving ETH another way
    receive() external payable {
        if (msg.sender != address(weth)) revert ReceiveIsNotAllowedException(); // U:[WG-2]
    }

    /// @inheritdoc IWETHGateway
    function deposit(address to, uint256 amount)
        external
        override
        registeredCreditManagerOnly(msg.sender) // U:[WG-3A]
    {
        if (amount <= 1) return;
        balanceOf[to] += amount; // U:[WG-3B]
        emit Deposit(to, amount); // U:[WG-3B]
    }

    /// @inheritdoc IWETHGateway
    function claim(address owner)
        external
        override
        nonReentrant // U:[WG-4A]
    {
        uint256 balance = balanceOf[owner];
        if (balance <= 1) return;

        unchecked {
            --balance;
        }
        balanceOf[owner] = 1; // U:[WG-4B]
        IWETH(weth).withdraw(balance); // U:[WG-4B]
        payable(owner).sendValue(balance); // U:[WG-4B]
        emit Claim(owner, balance); // U:[WG-4B]
    }
}
