// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity 0.8.23;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IBotListV3} from "../interfaces/IBotListV3.sol";
import {ICreditAccountV3} from "../interfaces/ICreditAccountV3.sol";
import {ICreditManagerV3} from "../interfaces/ICreditManagerV3.sol";
import {
    CallerNotCreditFacadeException,
    CreditManagerNotAddedException,
    ForbiddenBotException,
    IncorrectBotPermissionsException
} from "../interfaces/IExceptions.sol";
import {IBot} from "../interfaces/base/IBot.sol";

/// @title  Bot list V3
/// @notice Stores bot permissions (bit masks dictating which actions can be performed with credit accounts in multicall).
contract BotListV3 is IBotListV3, Ownable {
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @notice Contract version
    uint256 public constant override version = 3_10;

    /// @dev Mapping (credit manager, credit account) => set of bots with non-zero permissions
    mapping(address => mapping(address => EnumerableSet.AddressSet)) internal _activeBots;

    /// @dev Mapping (credit manager, credit account, bot) => permissions
    mapping(address => mapping(address => mapping(address => uint192))) internal _botPermissions;

    /// @dev Set of added credit managers
    EnumerableSet.AddressSet internal _creditManagersSet;

    /// @dev Set of all forbidden bots
    EnumerableSet.AddressSet internal _forbiddenBotsSet;

    /// @notice Constructor
    /// @param  owner_ Contract owner
    constructor(address owner_) {
        _transferOwnership(owner_);
    }

    // ----------- //
    // PERMISSIONS //
    // ----------- //

    /// @notice Returns all bots with non-zero permissions for `creditAccount` in its credit manager
    /// @dev    Forbidden bots are excluded
    function getActiveBots(address creditAccount) external view override returns (address[] memory bots) {
        EnumerableSet.AddressSet storage accountBots = _activeBots[_creditManager(creditAccount)][creditAccount];
        uint256 len = accountBots.length();
        bots = new address[](len);
        uint256 num;
        for (uint256 i; i < len; ++i) {
            address bot = accountBots.at(i);
            if (!_forbiddenBotsSet.contains(bot)) bots[num++] = bot;
        }
        assembly {
            mstore(bots, num)
        }
    }

    /// @notice Returns `bot`'s permissions for `creditAccount` in its credit manager
    /// @dev    Forbidden bots have no permissions
    function getBotPermissions(address bot, address creditAccount) external view override returns (uint192) {
        if (_forbiddenBotsSet.contains(bot)) return 0;
        return _botPermissions[_creditManager(creditAccount)][creditAccount][bot];
    }

    /// @notice Sets `bot`'s permissions for `creditAccount` in its credit manager to `permissions`
    /// @dev    Reverts if `creditAccount` is not opened in one of added credit managers or if caller
    ///         is not a facade connected to it
    /// @dev    Reverts if trying to set non-zero permissions that don't meet bot's requirements
    /// @dev    Reverts if trying to set non-zero permissions for a forbidden bot
    /// @custom:tests U:[BL-1]
    function setBotPermissions(address bot, address creditAccount, uint192 permissions) external override {
        address creditManager = _validateCreditAccount(creditAccount);

        EnumerableSet.AddressSet storage accountBots = _activeBots[creditManager][creditAccount];
        if (permissions != 0) {
            if (_forbiddenBotsSet.contains(bot)) revert ForbiddenBotException();
            if (IBot(bot).requiredPermissions() != permissions) revert IncorrectBotPermissionsException();
            accountBots.add(bot);
        } else {
            accountBots.remove(bot);
        }

        if (_botPermissions[creditManager][creditAccount][bot] != permissions) {
            _botPermissions[creditManager][creditAccount][bot] = permissions;
            emit SetBotPermissions({
                bot: bot,
                creditManager: creditManager,
                creditAccount: creditAccount,
                permissions: permissions
            });
        }
    }

    /// @notice Removes all bots' permissions for `creditAccount` in its credit manager
    /// @dev    Reverts if `creditAccount` is not opened in one of added credit managers or if caller
    ///         is not a facade connected to it
    /// @custom:tests U:[BL-2]
    function eraseAllBotPermissions(address creditAccount) external override {
        address creditManager = _validateCreditAccount(creditAccount);

        EnumerableSet.AddressSet storage accountBots = _activeBots[creditManager][creditAccount];
        uint256 len = accountBots.length();
        for (uint256 i; i < len; ++i) {
            address bot = accountBots.at(len - 1 - i);
            accountBots.remove(bot);
            _botPermissions[creditManager][creditAccount][bot] = 0;
            emit SetBotPermissions({
                bot: bot,
                creditManager: creditManager,
                creditAccount: creditAccount,
                permissions: 0
            });
        }
    }

    // ------------- //
    // CONFIGURATION //
    // ------------- //

    /// @notice Whether `creditManager` is added
    function isCreditManagerAdded(address creditManager) external view override returns (bool) {
        return _creditManagersSet.contains(creditManager);
    }

    /// @notice Returns the list of added credit managers
    function creditManagers() external view override returns (address[] memory) {
        return _creditManagersSet.values();
    }

    /// @notice Adds `creditManager`, an irreversible action
    /// @dev    Reverts if caller is not owner
    function addCreditManager(address creditManager) external override onlyOwner {
        if (_creditManagersSet.add(creditManager)) emit AddCreditManager(creditManager);
    }

    /// @notice Whether `bot` is forbidden
    function isBotForbidden(address bot) external view override returns (bool) {
        return _forbiddenBotsSet.contains(bot);
    }

    /// @notice Returns the list of forbidden bots
    function forbiddenBots() external view override returns (address[] memory) {
        return _forbiddenBotsSet.values();
    }

    /// @notice Forbids `bot`, an irreversible action
    /// @dev    Reverts if caller is not owner
    function forbidBot(address bot) external override onlyOwner {
        if (_forbiddenBotsSet.add(bot)) emit ForbidBot(bot);
    }

    // --------- //
    // INTERNALS //
    // --------- //

    /// @dev Ensures that `creditAccount` is opened in one of added credit managers and caller is a facade connected to it
    function _validateCreditAccount(address creditAccount) internal view returns (address creditManager) {
        creditManager = _creditManager(creditAccount);
        if (!_creditManagersSet.contains(creditManager)) revert CreditManagerNotAddedException();
        ICreditManagerV3(creditManager).getBorrowerOrRevert(creditAccount);
        if (ICreditManagerV3(creditManager).creditFacade() != msg.sender) revert CallerNotCreditFacadeException();
    }

    /// @dev Internal wrapper for `creditAccount.creditManager()` call to reduce contract size
    function _creditManager(address creditAccount) internal view returns (address) {
        return ICreditAccountV3(creditAccount).creditManager();
    }
}
