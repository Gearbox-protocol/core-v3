// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IBotListV3, BotInfo} from "../interfaces/IBotListV3.sol";
import {ICreditManagerV3} from "../interfaces/ICreditManagerV3.sol";
import {
    AddressIsNotContractException,
    CallerNotCreditFacadeException,
    InvalidBotException
} from "../interfaces/IExceptions.sol";

import {ACLNonReentrantTrait} from "../traits/ACLNonReentrantTrait.sol";
import {ContractsRegisterTrait} from "../traits/ContractsRegisterTrait.sol";

/// @title Bot list V3
/// @notice Stores bot permissions (bit masks dictating which actions can be performed with credit accounts in multicall).
///         Besides normal per-account permissions, there are special per-manager permissions that apply to all accounts
///         in a given credit manager and can be used to extend the core system or enforce additional safety measures
///         with special DAO-approved bots.
contract BotListV3 is ACLNonReentrantTrait, ContractsRegisterTrait, IBotListV3 {
    using Address for address;
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @notice Contract version
    uint256 public constant override version = 3_00;

    /// @notice Credit manager's approved status
    mapping(address => bool) public override approvedCreditManager;

    /// @dev Mapping bot => info
    mapping(address => BotInfo) internal _botInfo;

    /// @dev Mapping credit manager => credit account => set of bots with non-zero permissions
    mapping(address => mapping(address => EnumerableSet.AddressSet)) internal _activeBots;

    /// @dev Ensures that function can only be called by a facade connected to approved `creditManager`
    modifier onlyValidCreditFacade(address creditManager) {
        _revertIfCallerNotValidCreditFacade(creditManager);
        _;
    }

    /// @notice Constructor
    /// @param addressProvider Address provider contract address
    constructor(address addressProvider)
        ACLNonReentrantTrait(addressProvider)
        ContractsRegisterTrait(addressProvider)
    {}

    // ----------- //
    // PERMISSIONS //
    // ----------- //

    /// @notice Returns `bot`'s permissions for `creditAccount` in `creditManager`
    function botPermissions(address bot, address creditManager, address creditAccount)
        external
        view
        override
        returns (uint192)
    {
        return _botInfo[bot].permissions[creditManager][creditAccount];
    }

    /// @notice Returns all bots with non-zero permissions for `creditAccount` in `creditManager`
    function activeBots(address creditManager, address creditAccount)
        external
        view
        override
        returns (address[] memory)
    {
        return _activeBots[creditManager][creditAccount].values();
    }

    /// @notice Returns `bot`'s permissions for `creditAccount` in `creditManager`, including information
    ///         on whether bot is forbidden or has special permissions in the credit manager
    function getBotStatus(address bot, address creditManager, address creditAccount)
        external
        view
        override
        returns (uint192 permissions, bool forbidden, bool hasSpecialPermissions)
    {
        BotInfo storage info = _botInfo[bot];
        if (info.forbidden) return (0, true, false);

        uint192 specialPermissions = info.specialPermissions[creditManager];
        if (specialPermissions != 0) return (specialPermissions, false, true);

        return (info.permissions[creditManager][creditAccount], false, false);
    }

    /// @notice Sets `bot`'s permissions for `creditAccount` in `creditManager` to `permissions`
    /// @return activeBotsRemaining Number of bots with non-zero permissions remaining after the update
    /// @dev Reverts if caller is not a facade connected to approved `creditManager`
    /// @dev Reverts if `bot` is zero address or not a contract
    /// @dev Reverts if trying to set non-zero permissions for a forbidden bot or for a bot with special permissions
    function setBotPermissions(address bot, address creditManager, address creditAccount, uint192 permissions)
        external
        override
        nonZeroAddress(bot)
        onlyValidCreditFacade(creditManager)
        returns (uint256 activeBotsRemaining)
    {
        if (!bot.isContract()) revert AddressIsNotContractException(bot);

        EnumerableSet.AddressSet storage accountBots = _activeBots[creditManager][creditAccount];

        if (permissions != 0) {
            BotInfo storage info = _botInfo[bot];
            if (info.forbidden || info.specialPermissions[creditManager] != 0) {
                revert InvalidBotException();
            }

            accountBots.add(bot);
            info.permissions[creditManager][creditAccount] = permissions;
            emit SetBotPermissions(bot, creditManager, creditAccount, permissions);
        } else {
            _eraseBot(bot, creditManager, creditAccount);
            accountBots.remove(bot);
        }

        activeBotsRemaining = accountBots.length();
    }

    /// @notice Removes all bots' permissions for `creditAccount` in `creditManager`
    function eraseAllBotPermissions(address creditManager, address creditAccount)
        external
        override
        onlyValidCreditFacade(creditManager)
    {
        EnumerableSet.AddressSet storage accountBots = _activeBots[creditManager][creditAccount];
        unchecked {
            for (uint256 i = accountBots.length(); i != 0; --i) {
                address bot = accountBots.at(i - 1);
                _eraseBot(bot, creditManager, creditAccount);
                accountBots.remove(bot);
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

    /// @notice Returns `bot`'s special permissions in `creditManager`
    function botSpecialPermissions(address bot, address creditManager) external view override returns (uint192) {
        return _botInfo[bot].specialPermissions[creditManager];
    }

    /// @notice Sets `bot`'s status to `forbidden`
    function setBotForbiddenStatus(address bot, bool forbidden) external override configuratorOnly {
        BotInfo storage info = _botInfo[bot];
        if (info.forbidden != forbidden) {
            info.forbidden = forbidden;
            emit SetBotForbiddenStatus(bot, forbidden);
        }
    }

    /// @notice Sets `bot`'s special permissions in `creditManager` to `permissions`
    function setBotSpecialPermissions(address bot, address creditManager, uint192 permissions)
        external
        override
        configuratorOnly
    {
        BotInfo storage info = _botInfo[bot];
        if (info.specialPermissions[creditManager] != permissions) {
            info.specialPermissions[creditManager] = permissions;
            emit SetBotSpecialPermissions(bot, creditManager, permissions);
        }
    }

    /// @notice Sets `creditManager`'s status to `approved`
    function setCreditManagerApprovedStatus(address creditManager, bool approved)
        external
        override
        configuratorOnly
        registeredCreditManagerOnly(creditManager)
    {
        if (approvedCreditManager[creditManager] != approved) {
            approvedCreditManager[creditManager] = approved;
            emit SetCreditManagerApprovedStatus(creditManager, approved);
        }
    }

    // --------- //
    // INTERNALS //
    // --------- //

    /// @dev Reverts if `creditManager` is not approved or caller is not a facade connected to `creditManager`
    function _revertIfCallerNotValidCreditFacade(address creditManager) internal view {
        if (!approvedCreditManager[creditManager] || ICreditManagerV3(creditManager).creditFacade() != msg.sender) {
            revert CallerNotCreditFacadeException();
        }
    }

    /// @dev Removes `bot`'s permissions for `creditAccount` in `creditManager`
    function _eraseBot(address bot, address creditManager, address creditAccount) internal {
        delete _botInfo[bot].permissions[creditManager][creditAccount];
        emit EraseBot(bot, creditManager, creditAccount);
    }
}
