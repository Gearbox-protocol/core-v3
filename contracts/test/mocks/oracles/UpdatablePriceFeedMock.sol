// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

contract UpdatablePriceFeedMock {
    enum FlagState {
        FALSE,
        TRUE,
        REVERT
    }

    FlagState _updatable;

    function updatable() external view returns (bool) {
        if (_updatable == FlagState.REVERT) revert();
        return _updatable == FlagState.TRUE;
    }

    function updatePrice(bytes calldata data) external pure {}

    function setUpdatable(FlagState updatable_) external {
        _updatable = updatable_;
    }
}
