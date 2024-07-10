// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.10;

import {IPhantomToken} from "../../../interfaces/base/IPhantomToken.sol";

contract PhantomTokenMock is IPhantomToken {
    uint256 public constant override version = 3_10;
    bytes32 public constant override contractType = "PT_MOCK";
    uint8 private immutable _decimals;

    address public underlying;

    mapping(address => uint256) public balances;
    uint256 totalSupply;

    constructor(address _underlying) {
        underlying = _underlying;
        _decimals = 18;
    }

    function mint(address account, uint256 amount) external returns (bool) {
        balances[account] += amount;
        totalSupply += amount;
        return true;
    }

    function burn(address account, uint256 amount) external returns (bool) {
        balances[account] -= amount;
        totalSupply -= amount;
        return true;
    }

    function balanceOf(address account) external view returns (uint256) {
        return balances[account];
    }

    /// @notice Returns the calls required to unwrap a Zircuit position into underlying before withdrawing from Gearbox
    function getWithdrawalMultiCall(address creditAccount, uint256 amount)
        external
        view
        returns (address tokenOut, uint256 amountOut, address targetContract, bytes memory callData)
    {
        tokenOut = underlying;
        amountOut = amount;
        targetContract = address(this);
        callData = abi.encodeWithSignature("withdrawalCall(address,uint256)", creditAccount, amount);
    }

    function withdrawalCall(address creditAccount, uint256 amount) external {}
}
