// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

contract BotListMock {
    bool revertOnErase;

    uint256 return_botPermissions;
    bool return_forbidden;

    uint256 return_activeBotsRemaining;

    function setBotStatusReturns(uint256 botPermissions, bool forbidden) external {
        return_botPermissions = botPermissions;
        return_forbidden = forbidden;
    }

    function getBotStatus(address, address) external view returns (uint256 botPermissions, bool forbidden) {
        botPermissions = return_botPermissions;
        forbidden = return_forbidden;
    }

    function eraseAllBotPermissions(address) external view {
        if (revertOnErase) {
            revert("Unexpected call to eraseAllBotPermissions");
        }
    }

    function setRevertOnErase(bool _value) external {
        revertOnErase = _value;
    }

    function payBot(address payer, address creditAccount, address bot, uint72 paymentAmount) external {}

    function setBotPermissionsReturn(uint256 activeBotsRemaining) external {
        return_activeBotsRemaining = activeBotsRemaining;
    }

    function setBotPermissions(address, address, uint192, uint72, uint72)
        external
        view
        returns (uint256 activeBotsRemaining)
    {
        activeBotsRemaining = return_activeBotsRemaining;
    }
}
