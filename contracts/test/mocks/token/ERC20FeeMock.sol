// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {ERC20Mock} from "../../mocks/token/ERC20Mock.sol";
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";

contract ERC20FeeMock is ERC20Mock {
    uint256 public basisPointsRate;
    uint256 public maximumFee;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20Mock(name_, symbol_, decimals_) {}

    function transfer(address recipient, uint256 amount) public virtual override returns (bool) {
        uint256 fee = _computeFee(amount);
        _transfer(_msgSender(), recipient, amount - fee);
        if (fee > 0) _transfer(_msgSender(), owner(), fee);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) public virtual override returns (bool) {
        _spendAllowance(sender, _msgSender(), amount);
        uint256 fee = _computeFee(amount);
        if (fee > 0) _transfer(sender, owner(), fee);
        _transfer(sender, recipient, amount - fee);
        return true;
    }

    function _computeFee(uint256 amount) internal view returns (uint256) {
        uint256 fee = (amount * basisPointsRate) / PERCENTAGE_FACTOR;
        if (fee > maximumFee) {
            fee = maximumFee;
        }
        return fee;
    }

    function setMaximumFee(uint256 _fee) external {
        maximumFee = _fee;
    }

    function setBasisPointsRate(uint256 _rate) external {
        require(_rate < PERCENTAGE_FACTOR, "Incorrect fee");
        basisPointsRate = _rate;
    }
}
