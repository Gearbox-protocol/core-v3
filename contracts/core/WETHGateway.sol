// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.10;

import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {AddressProvider} from "@gearbox-protocol/core-v2/contracts/core/AddressProvider.sol";
import {ContractsRegisterTrait} from "../traits/ContractsRegisterTrait.sol";

import {IPoolService} from "@gearbox-protocol/core-v2/contracts/interfaces/IPoolService.sol";
import {IPool4626} from "../interfaces/IPool4626.sol";

import {IWETH} from "@gearbox-protocol/core-v2/contracts/interfaces/external/IWETH.sol";
import {IWETHGateway} from "../interfaces/IWETHGateway.sol";
import {Errors} from "@gearbox-protocol/core-v2/contracts/libraries/Errors.sol";

import {
    RegisteredPoolOnlyException,
    ZeroAddressException,
    WethPoolsOnlyException,
    ReceiveIsNotAllowedException
} from "../interfaces/IErrors.sol";

/// @title WETHGateway
/// @notice Used for converting ETH <> WETH
contract WETHGateway is IWETHGateway, ReentrancyGuard, ContractsRegisterTrait {
    using SafeERC20 for IERC20;
    using Address for address payable;

    address public immutable weth;

    mapping(address => uint256) public override(IWETHGateway) balanceOf;

    // Contract version
    uint256 public constant version = 3_00;

    /// @dev Checks that the pool is registered and the underlying token is WETH
    modifier wethPoolOnly(address pool) {
        if (!isRegisteredPool(pool)) revert RegisteredPoolOnlyException(); // T:[WG-1]
        if (IPoolService(pool).underlyingToken() != weth) revert WethPoolsOnlyException(); // T:[WG-2]
        _;
    }

    /// @dev Measures WETH balance before and after function call and transfers
    /// difference to providced address
    modifier unwrapAndTransferWethTo(address to) {
        uint256 balanceBefore = IERC20(weth).balanceOf(address(this));

        _;

        uint256 diff = IERC20(weth).balanceOf(address(this)) - balanceBefore;

        if (diff > 0) {
            _unwrapWETH(to, diff);
        }
    }

    //
    // CONSTRUCTOR
    //

    /// @dev Constructor
    /// @param addressProvider Address Repository for upgradable contract model
    constructor(address addressProvider) ContractsRegisterTrait(addressProvider) {
        if (addressProvider == address(0)) revert ZeroAddressException();
        weth = AddressProvider(addressProvider).getWethToken();
    }

    /// FOR POOLS V3

    function deposit(address pool, address receiver)
        external
        payable
        override
        wethPoolOnly(pool)
        returns (uint256 shares)
    {
        IWETH(weth).deposit{value: msg.value}();

        _checkAllowance(pool, msg.value);
        return IPool4626(pool).deposit(msg.value, receiver);
    }

    function depositReferral(address pool, address receiver, uint16 referralCode)
        external
        payable
        override
        wethPoolOnly(pool)
        returns (uint256 shares)
    {
        IWETH(weth).deposit{value: msg.value}();

        _checkAllowance(pool, msg.value);
        return IPool4626(pool).depositReferral(msg.value, receiver, referralCode);
    }

    function mint(address pool, uint256 shares, address receiver)
        external
        payable
        override
        wethPoolOnly(pool)
        unwrapAndTransferWethTo(msg.sender)
        returns (uint256 assets)
    {
        IWETH(weth).deposit{value: msg.value}();

        _checkAllowance(pool, msg.value);
        assets = IPool4626(pool).mint(shares, receiver);
    }

    function withdraw(address pool, uint256 assets, address receiver, address owner)
        external
        override
        wethPoolOnly(pool)
        unwrapAndTransferWethTo(receiver)
        returns (uint256 shares)
    {
        return IPool4626(pool).withdraw(assets, address(this), owner);
    }

    function redeem(address pool, uint256 shares, address receiver, address owner)
        external
        override
        wethPoolOnly(pool)
        unwrapAndTransferWethTo(receiver)
        returns (uint256 assets)
    {
        return IPool4626(pool).redeem(shares, address(this), owner);
    }

    // CREDIT MANAGERS

    function depositFor(address to, uint256 amount) external override registeredCreditManagerOnly(msg.sender) {
        balanceOf[to] += amount;
    }

    function withdrawTo(address owner) external override nonReentrant {
        uint256 balance = balanceOf[owner];
        if (balance > 1) {
            balanceOf[owner] = 1;
            _unwrapWETH(owner, balance - 1);
        }
    }

    /// @dev Internal implementation for unwrapETH
    function _unwrapWETH(address to, uint256 amount) internal {
        IWETH(weth).withdraw(amount); // T: [WG-7]
        payable(to).sendValue(amount); // T: [WG-7]
    }

    /// @dev Checks that the allowance is sufficient before a transaction, and sets to max if not
    /// @param spender Account that would spend WETH
    /// @param amount Amount to compare allowance with
    function _checkAllowance(address spender, uint256 amount) internal {
        if (IERC20(weth).allowance(address(this), spender) < amount) {
            IERC20(weth).approve(spender, type(uint256).max);
        }
    }

    /// @dev Only WETH contract is allowed to transfer ETH here. Prevent other addresses to send Ether to this contract.
    receive() external payable {
        if (msg.sender != address(weth)) revert ReceiveIsNotAllowedException(); // T:[WG-6]
    }
}
