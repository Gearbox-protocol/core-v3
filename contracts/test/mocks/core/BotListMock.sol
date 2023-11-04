// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

contract BotListMock {
    bool revertOnErase;

    uint256 return_botPermissions;
    bool return_forbidden;
    bool return_hasSpecialPermissions;

    uint256 return_activeBotsRemaining;

    function setBotStatusReturns(uint256 botPermissions, bool forbidden, bool hasSpecialPermissions) external {
        return_botPermissions = botPermissions;
        return_forbidden = forbidden;
        return_hasSpecialPermissions = hasSpecialPermissions;
    }

    function getBotStatus(address, address, address)
        external
        view
        returns (uint256 botPermissions, bool forbidden, bool hasSpecialPermissions)
    {
        botPermissions = return_botPermissions;
        forbidden = return_forbidden;
        hasSpecialPermissions = return_hasSpecialPermissions;
    }

    function eraseAllBotPermissions(address, address) external view {
        if (revertOnErase) {
            revert("Unexpected call to eraseAllBotPermissions");
        }
    }

    function setRevertOnErase(bool _value) external {
        revertOnErase = _value;
    }

    function setBotPermissionsReturn(uint256 activeBotsRemaining) external {
        return_activeBotsRemaining = activeBotsRemaining;
    }

    function setBotPermissions(address, address, address, uint192)
        external
        view
        returns (uint256 activeBotsRemaining)
    {
        activeBotsRemaining = return_activeBotsRemaining;
    }
}
