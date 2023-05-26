// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

contract BotListMock {
    bool revertOnErase;

    uint256 return_botPermissions;
    bool return_forbidden;

    function setBotStatusReturns(uint256 botPermissions, bool forbidden) external {
        return_botPermissions = botPermissions;
        return_forbidden = forbidden;
    }

    function getBotStatus(address creditAccount, address bot)
        external
        view
        returns (uint256 botPermissions, bool forbidden)
    {
        botPermissions = return_botPermissions;
        forbidden = return_forbidden;
    }

    function eraseAllBotPermissions(address creditAccount) external {
        if (revertOnErase) {
            revert("Unexpected call to eraseAllBotPermissions");
        }
    }

    function setRevertOnErase(bool _value) external {
        revertOnErase = _value;
    }

    function payBot(address payer, address creditAccount, address bot, uint72 paymentAmount) external {}
}
