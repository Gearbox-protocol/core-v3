// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.23;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ICreditManagerV3} from "../../../interfaces/ICreditManagerV3.sol";
import {NotImplementedException} from "../../../interfaces/IExceptions.sol";
import {IAdapter} from "../../../interfaces/base/IAdapter.sol";
import {IPhantomToken, IPhantomTokenWithdrawer} from "../../../interfaces/base/IPhantomToken.sol";
import {ERC20Mock} from "../token/ERC20Mock.sol";

contract PhantomTokenMock is IPhantomToken, ERC20 {
    uint256 public constant override version = 3_10;
    bytes32 public constant override contractType = "PT_MOCK";

    address public immutable target;
    address public immutable depositedToken;

    constructor(address target_, address depositedToken_, string memory name_, string memory symbol_)
        ERC20(name_, symbol_)
    {
        target = target_;
        depositedToken = depositedToken_;
    }

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function burn(address account, uint256 amount) external {
        _burn(account, amount);
    }

    function _transfer(address, address, uint256) internal pure override {
        revert NotImplementedException();
    }

    function getPhantomTokenInfo() external view returns (address, address) {
        return (target, depositedToken);
    }
}

contract PhantomTokenWithdrawerMock is IAdapter, IPhantomTokenWithdrawer {
    uint256 public constant override version = 3_10;
    bytes32 public constant override contractType = "AD_PHANTOM_TOKEN_WITHDRAWER_MOCK";

    address public immutable override creditManager;
    address public immutable override targetContract;

    address public immutable phantomToken;
    address public immutable depositedToken;

    constructor(address creditManager_, address phantomToken_) {
        creditManager = creditManager_;
        phantomToken = phantomToken_;
        (targetContract, depositedToken) = IPhantomToken(phantomToken_).getPhantomTokenInfo();
    }

    function withdrawPhantomToken(address, uint256 amount) external override returns (bool) {
        address creditAccount = ICreditManagerV3(creditManager).getActiveCreditAccountOrRevert();
        PhantomTokenMock(phantomToken).burn(creditAccount, amount);
        ERC20Mock(depositedToken).mint(creditAccount, amount);
        return false;
    }
}
