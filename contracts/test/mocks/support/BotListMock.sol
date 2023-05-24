// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

contract BotListMock {
    bool revertOnErase;

    function eraseAllBotPermissions(address creditAccount) external {
        if (revertOnErase) {
            revert("Unexpected call to eraseAllBotPermissions");
        }
    }

    function setRevertOnErase(bool _value) external {
        revertOnErase = _value;
    }
}
