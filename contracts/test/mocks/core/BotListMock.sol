// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

contract BotListMock {
    uint256 return_botPermissions;
    bool return_isCreditManagerAdded;

    function setBotPermissionsReturns(uint256 botPermissions) external {
        return_botPermissions = botPermissions;
    }

    function setCreditManagerAddedReturns(bool added) external {
        return_isCreditManagerAdded = added;
    }

    function getBotPermissions(address, address) external view returns (uint256 botPermissions) {
        botPermissions = return_botPermissions;
    }

    function isCreditManagerAdded(address) external view returns (bool) {
        return return_isCreditManagerAdded;
    }

    function eraseAllBotPermissions(address) external view {}

    function setBotPermissions(address, address, uint192) external view {}
}
