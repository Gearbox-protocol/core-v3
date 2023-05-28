// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

contract BotRegisterMock {
    bool revertOnErase;

    uint256 return_botPermissions;
    bool return_forbidden;

    uint256 return_activeBotsRemaining;

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

    function eraseAllBotPermissions(address creditAccount) external view {
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

    function setBotPermissions(
        address creditAccount,
        address bot,
        uint192 permissions,
        uint72 fundingAmount,
        uint72 weeklyFundingAllowance
    ) external returns (uint256 activeBotsRemaining) {
        activeBotsRemaining = return_activeBotsRemaining;
    }
}
