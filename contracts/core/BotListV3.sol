// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IBotListV3, BotInfo} from "../interfaces/IBotListV3.sol";
import {ICreditAccountV3} from "../interfaces/ICreditAccountV3.sol";
import {ICreditManagerV3} from "../interfaces/ICreditManagerV3.sol";
import {
    AddressIsNotContractException,
    CallerNotCreditFacadeException,
    IncorrectBotPermissionsException,
    InvalidBotException
} from "../interfaces/IExceptions.sol";
import {IBot} from "../interfaces/base/IBot.sol";

import {SanityCheckTrait} from "../traits/SanityCheckTrait.sol";

/// @title Bot list V3
/// @notice Stores bot permissions (bit masks dictating which actions can be performed with credit accounts in multicall).
contract BotListV3 is IBotListV3, SanityCheckTrait, Ownable {
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @notice Contract version
    uint256 public constant override version = 3_10;

    /// @notice Credit manager's approved status
    mapping(address => bool) public override approvedCreditManager;

    /// @dev Mapping bot => info
    mapping(address => BotInfo) internal _botInfo;

    /// @dev Mapping credit manager => credit account => set of bots with non-zero permissions
    mapping(address => mapping(address => EnumerableSet.AddressSet)) internal _activeBots;

    /// @notice Constructor
    /// @param owner_ Contract owner
    constructor(address owner_) {
        _transferOwnership(owner_);
    }

    // ----------- //
    // PERMISSIONS //
    // ----------- //

    /// @notice Returns `bot`'s permissions for `creditAccount` in its credit manager
    function botPermissions(address bot, address creditAccount) external view override returns (uint192) {
        address creditManager = ICreditAccountV3(creditAccount).creditManager();
        return _botInfo[bot].permissions[creditManager][creditAccount];
    }

    /// @notice Returns all bots with non-zero permissions for `creditAccount` in its credit manager
    function activeBots(address creditAccount) external view override returns (address[] memory) {
        address creditManager = ICreditAccountV3(creditAccount).creditManager();
        return _activeBots[creditManager][creditAccount].values();
    }

    /// @notice Returns `bot`'s permissions for `creditAccount` in its credit manager and whether it is forbidden
    function getBotStatus(address bot, address creditAccount)
        external
        view
        override
        returns (uint192 permissions, bool forbidden)
    {
        BotInfo storage info = _botInfo[bot];
        if (info.forbidden) return (0, true);

        address creditManager = ICreditAccountV3(creditAccount).creditManager();
        return (info.permissions[creditManager][creditAccount], false);
    }

    /// @notice Sets `bot`'s permissions for `creditAccount` in its credit manager to `permissions`
    /// @return activeBotsRemaining Number of bots with non-zero permissions remaining after the update
    /// @dev Reverts if `creditAccount`'s credit manager is not approved or caller is not a facade connected to it
    /// @dev Reverts if trying to set non-zero permissions that don't meet bot's requirements
    /// @dev Reverts if trying to set non-zero permissions for a forbidden bot
    /// @custom:tests U:[BL-1]
    function setBotPermissions(address bot, address creditAccount, uint192 permissions)
        external
        override
        nonZeroAddress(bot)
        returns (uint256 activeBotsRemaining)
    {
        address creditManager = ICreditAccountV3(creditAccount).creditManager();
        _revertIfCallerNotValidCreditFacade(creditManager);

        BotInfo storage info = _botInfo[bot];
        EnumerableSet.AddressSet storage accountBots = _activeBots[creditManager][creditAccount];
        if (permissions != 0) {
            if (IBot(bot).requiredPermissions() != permissions) revert IncorrectBotPermissionsException();
            if (info.forbidden) revert InvalidBotException();
            accountBots.add(bot);
        } else {
            accountBots.remove(bot);
        }
        activeBotsRemaining = accountBots.length();

        if (info.permissions[creditManager][creditAccount] != permissions) {
            info.permissions[creditManager][creditAccount] = permissions;
            emit SetBotPermissions(bot, creditManager, creditAccount, permissions);
        }
    }

    /// @notice Removes all bots' permissions for `creditAccount` in its credit manager
    /// @dev Reverts if `creditAccount`'s credit manager is not approved or caller is not a facade connected to it
    /// @custom:tests U:[BL-2]
    function eraseAllBotPermissions(address creditAccount) external override {
        address creditManager = ICreditAccountV3(creditAccount).creditManager();
        _revertIfCallerNotValidCreditFacade(creditManager);

        EnumerableSet.AddressSet storage accountBots = _activeBots[creditManager][creditAccount];
        unchecked {
            for (uint256 i = accountBots.length(); i != 0; --i) {
                address bot = accountBots.at(i - 1);
                accountBots.remove(bot);
                _botInfo[bot].permissions[creditManager][creditAccount] = 0;
                emit SetBotPermissions(bot, creditManager, creditAccount, 0);
            }
        }
    }

    // ------------- //
    // CONFIGURATION //
    // ------------- //

    /// @notice Returns `bot`'s forbidden status
    function botForbiddenStatus(address bot) external view override returns (bool) {
        return _botInfo[bot].forbidden;
    }

    /// @notice Forbid's `bot`
    function forbidBot(address bot) external override onlyOwner {
        BotInfo storage info = _botInfo[bot];
        if (!info.forbidden) {
            info.forbidden = true;
            emit ForbidBot(bot);
        }
    }

    /// @notice Approves `creditManager`
    function approveCreditManager(address creditManager) external override onlyOwner {
        if (!approvedCreditManager[creditManager]) {
            approvedCreditManager[creditManager] = true;
            emit ApproveCreditManager(creditManager);
        }
    }

    // --------- //
    // INTERNALS //
    // --------- //

    /// @dev Reverts if `creditManager` is not approved or caller is not a facade connected to it
    function _revertIfCallerNotValidCreditFacade(address creditManager) internal view {
        if (!approvedCreditManager[creditManager] || ICreditManagerV3(creditManager).creditFacade() != msg.sender) {
            revert CallerNotCreditFacadeException();
        }
    }
}
