// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SafeERC20} from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IWETH} from "@gearbox-protocol/core-v2/contracts/interfaces/external/IWETH.sol";
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";

import "../interfaces/IAddressProviderV3.sol";
import {ACLNonReentrantTrait} from "../traits/ACLNonReentrantTrait.sol";
import {IBotListV3, BotFunding, BotSpecialStatus} from "../interfaces/IBotListV3.sol";
import {ICreditManagerV3} from "../interfaces/ICreditManagerV3.sol";
import {ICreditFacadeV3} from "../interfaces/ICreditFacadeV3.sol";

import "../interfaces/IExceptions.sol";

/// @title Bot list V3
/// @notice Stores a mapping from credit accounts to bot permissions. Exists to simplify credit facades migration.
contract BotListV3 is ACLNonReentrantTrait, IBotListV3 {
    using SafeCast for uint256;
    using Address for address;
    using Address for address payable;
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for IERC20;

    /// @notice Contract version
    uint256 public constant override version = 3_00;

    /// @notice Address of the DAO treasury
    address public immutable override treasury;

    /// @notice Address of the WETH token
    address public immutable override weth;

    /// @notice Symbol, added for ERC-20 compatibility so that bot funding could be monitored in wallets
    string public constant override symbol = "gETH";

    /// @notice Name, added for ERC-20 compatibility so that bot funding could be monitored in wallets
    string public constant override name = "Gearbox bot funding";

    /// @notice Mapping from account address to its status as an approved credit manager
    mapping(address => bool) public override approvedCreditManager;

    /// @dev Set of all approved credit managers
    EnumerableSet.AddressSet internal approvedCreditManagers;

    /// @notice Mapping from (creditManager, creditAccount, bot) to bot permissions
    mapping(address => mapping(address => mapping(address => uint192))) public override botPermissions;

    /// @notice Mapping from (creditManager, creditAccount, bot) to bot funding parameters
    mapping(address => mapping(address => mapping(address => BotFunding))) public override botFunding;

    /// @dev Mapping from credit account to the set of bots with non-zero permissions
    mapping(address => mapping(address => EnumerableSet.AddressSet)) internal activeBots;

    /// @notice Mapping from (creditManager, bot) to bot's special status parameters:
    ///         * Whether the bot is forbidden
    ///         * Mask of special permissions
    mapping(address => mapping(address => BotSpecialStatus)) public override botSpecialStatus;

    /// @notice Mapping from borrower to their bot funding balance
    mapping(address => uint256) public override balanceOf;

    /// @notice A fee in bps charged by the DAO on bot payments
    uint16 public override daoFee = 0;

    constructor(address addressProvider) ACLNonReentrantTrait(addressProvider) {
        treasury = IAddressProviderV3(addressProvider).getAddressOrRevert(AP_TREASURY, NO_VERSION_CONTROL);
        weth = IAddressProviderV3(addressProvider).getAddressOrRevert(AP_WETH_TOKEN, NO_VERSION_CONTROL);
    }

    /// @dev Limits access to a function only to credit facades connected to approved credit managers
    modifier onlyValidCreditFacade(address creditManager) {
        _revertIfCallerNotValidCreditFacade(creditManager);
        _;
    }

    /// @notice Sets permissions and funding for (creditAccount, bot)
    /// @param creditManager Credit manager to set permissions in
    /// @param creditAccount Credit account to set permissions for
    /// @param bot Bot to set permissions for
    /// @param permissions A bit mask of permissions
    /// @param fundingAmount Total amount of ETH available to the bot for payments
    /// @param weeklyFundingAllowance Amount of ETH available to the bot weekly
    /// @return activeBotsRemaining Remaining number of non-special bots with non-zero permissions
    function setBotPermissions(
        address creditManager,
        address creditAccount,
        address bot,
        uint192 permissions,
        uint72 fundingAmount,
        uint72 weeklyFundingAllowance
    )
        external
        override
        nonZeroAddress(bot)
        onlyValidCreditFacade(creditManager) // F: [BL-3]
        returns (uint256 activeBotsRemaining)
    {
        if (!bot.isContract()) {
            revert AddressIsNotContractException(bot); // F: [BL-3]
        }

        EnumerableSet.AddressSet storage accountBots = activeBots[creditManager][creditAccount];

        if (permissions != 0) {
            if (
                (
                    botSpecialStatus[creditManager][bot].forbidden
                        || botSpecialStatus[creditManager][bot].specialPermissions != 0
                )
            ) {
                revert InvalidBotException(); // F: [BL-3]
            }

            accountBots.add(bot); // F: [BL-3]

            botPermissions[creditManager][creditAccount][bot] = permissions; // F: [BL-3]

            BotFunding storage bf = botFunding[creditManager][creditAccount][bot];

            bf.remainingFunds = fundingAmount; // F: [BL-3]
            bf.maxWeeklyAllowance = weeklyFundingAllowance; // F: [BL-3]
            bf.remainingWeeklyAllowance = weeklyFundingAllowance; // F: [BL-3]
            bf.allowanceLU = uint40(block.timestamp); // F: [BL-3]

            emit SetBotPermissions({
                creditManager: creditManager,
                creditAccount: creditAccount,
                bot: bot,
                permissions: permissions,
                fundingAmount: fundingAmount,
                weeklyFundingAllowance: weeklyFundingAllowance
            }); // F: [BL-3]
        } else {
            _eraseBot(creditManager, creditAccount, bot); // F: [BL-3]
        }

        activeBotsRemaining = accountBots.length(); // F: [BL-3]
    }

    /// @notice Removes permissions and funding for all bots with non-zero permissions for a credit account
    /// @param creditManager Credit manager to erase permissions in
    /// @param creditAccount Credit account to erase permissions for
    function eraseAllBotPermissions(address creditManager, address creditAccount)
        external
        override
        onlyValidCreditFacade(creditManager) // F: [BL-6]
    {
        EnumerableSet.AddressSet storage accountBots = activeBots[creditManager][creditAccount];

        uint256 len = accountBots.length();

        unchecked {
            for (uint256 i = 0; i < len; ++i) {
                address bot = accountBots.at(len - i - 1); // F: [BL-6]
                _eraseBot({creditManager: creditManager, creditAccount: creditAccount, bot: bot});
            }
        }
    }

    /// @dev Removes all permissions and funding for a (creditManager, credit account, bot) tuple
    function _eraseBot(address creditManager, address creditAccount, address bot) internal {
        delete botPermissions[creditManager][creditAccount][bot]; // F: [BL-6]
        delete botFunding[creditManager][creditAccount][bot]; // F: [BL-6]

        activeBots[creditManager][creditAccount].remove(bot); // F: [BL-6]
        emit EraseBot({creditManager: creditManager, creditAccount: creditAccount, bot: bot}); // F: [BL-6]
    }

    /// @notice Takes payment for performed services from the user's balance and sends to the bot
    /// @param payer Address to charge
    /// @param creditManager Address of the credit manager where the (creditAccount, bot) pair is funded
    /// @param creditAccount Address of the credit account paid for
    /// @param bot Address of the bot to pay
    /// @param paymentAmount Amount of WETH to pay
    function payBot(address payer, address creditManager, address creditAccount, address bot, uint72 paymentAmount)
        external
        override
        onlyValidCreditFacade(creditManager) // F: [BL-5]
    {
        if (paymentAmount == 0) return;

        BotFunding storage bf = botFunding[creditManager][creditAccount][bot]; // F: [BL-5]

        if (block.timestamp >= bf.allowanceLU + uint40(7 days)) {
            bf.allowanceLU = uint40(block.timestamp); // F: [BL-5]
            bf.remainingWeeklyAllowance = bf.maxWeeklyAllowance; // F: [BL-5]
        }

        // feeAmount is always < paymentAmount, however `uint256` conversion adds more space for computations
        uint72 feeAmount = uint72(uint256(daoFee) * paymentAmount / PERCENTAGE_FACTOR); // F: [BL-5]

        uint72 totalAmount = paymentAmount + feeAmount;

        bf.remainingWeeklyAllowance -= totalAmount; // F: [BL-5]
        bf.remainingFunds -= totalAmount; // F: [BL-5]

        balanceOf[payer] -= totalAmount; // F: [BL-5]

        IERC20(weth).safeTransfer(bot, paymentAmount); // F: [BL-5]

        if (feeAmount != 0) {
            IERC20(weth).safeTransfer(treasury, feeAmount); // F: [BL-5]
        }

        emit PayBot(payer, creditAccount, bot, paymentAmount, feeAmount); // F: [BL-5]
    }

    /// @notice Adds funds to the borrower's bot payment wallet
    function deposit() public payable override nonReentrant {
        if (msg.value == 0) {
            revert AmountCantBeZeroException(); // F: [BL-4]
        }

        IWETH(weth).deposit{value: msg.value}();
        balanceOf[msg.sender] += msg.value;

        emit Deposit(msg.sender, msg.value); // F: [BL-4]
    }

    /// @notice Removes funds from the borrower's bot payment wallet
    function withdraw(uint256 amount) external override nonReentrant {
        balanceOf[msg.sender] -= amount; // F: [BL-4]

        IWETH(weth).withdraw(amount);
        payable(msg.sender).sendValue(amount); // F: [BL-4]

        emit Withdraw(msg.sender, amount); // F: [BL-4]
    }

    /// @notice Returns all currently active bots on the account
    function getActiveBots(address creditManager, address creditAccount)
        external
        view
        override
        returns (address[] memory)
    {
        return activeBots[creditManager][creditAccount].values();
    }

    /// @notice Returns information about bot permissions
    function getBotStatus(address creditManager, address creditAccount, address bot)
        external
        view
        override
        returns (uint192 permissions, bool forbidden, bool hasSpecialPermissions)
    {
        uint192 specialPermissions;
        (forbidden, specialPermissions) =
            (botSpecialStatus[creditManager][bot].forbidden, botSpecialStatus[creditManager][bot].specialPermissions); // F: [BL-7]

        hasSpecialPermissions = specialPermissions != 0;
        permissions = hasSpecialPermissions ? specialPermissions : botPermissions[creditManager][creditAccount][bot];
    }

    // ------------- //
    // CONFIGURATION //
    // ------------- //

    /// @notice Sets the bot's forbidden status in a given credit manager
    function setBotForbiddenStatus(address creditManager, address bot, bool status)
        external
        override
        configuratorOnly
    {
        _setBotForbiddenStatus(creditManager, bot, status);
    }

    /// @notice Sets the bot's forbidden status in all credit managers
    function setBotForbiddenStatusEverywhere(address bot, bool status) external override configuratorOnly {
        uint256 len = approvedCreditManagers.length();
        unchecked {
            for (uint256 i = 0; i < len; ++i) {
                _setBotForbiddenStatus(approvedCreditManagers.at(i), bot, status);
            }
        }
    }

    /// @dev Implementation of `setBotForbiddenStatus`
    function _setBotForbiddenStatus(address creditManager, address bot, bool status) internal {
        if (botSpecialStatus[creditManager][bot].forbidden != status) {
            botSpecialStatus[creditManager][bot].forbidden = status;
            emit SetBotForbiddenStatus(creditManager, bot, status);
        }
    }

    /// @notice Gives special permissions to a bot that extend to all credit accounts
    /// @dev Bots with special permissions are DAO-approved bots which are enabled with a defined set of permissions for
    ///      all users. Can be used to extend system functionality with additional features without changing the core,
    ///      such as adding partial liquidations.
    function setBotSpecialPermissions(address creditManager, address bot, uint192 permissions)
        external
        override
        configuratorOnly
    {
        if (botSpecialStatus[creditManager][bot].specialPermissions != permissions) {
            botSpecialStatus[creditManager][bot].specialPermissions = permissions; // F: [BL-7]
            emit SetBotSpecialPermissions(creditManager, bot, permissions); // F: [BL-7]
        }
    }

    /// @notice Sets the DAO fee on bot payments
    /// @param newFee The new fee value
    function setDAOFee(uint16 newFee) external override configuratorOnly {
        if (daoFee > PERCENTAGE_FACTOR) {
            revert IncorrectParameterException();
        }

        if (daoFee != newFee) {
            daoFee = newFee; // F: [BL-2]
            emit SetBotDAOFee(newFee); // F: [BL-2]
        }
    }

    /// @notice Sets an address' status as an approved credit manager
    /// @param creditManager Address of the credit manager to change status for
    /// @param newStatus The new status
    function setApprovedCreditManagerStatus(address creditManager, bool newStatus) external override configuratorOnly {
        if (approvedCreditManager[creditManager] != newStatus) {
            if (newStatus) {
                approvedCreditManagers.add(creditManager);
            } else {
                approvedCreditManagers.remove(creditManager);
            }

            approvedCreditManager[creditManager] = newStatus;
            emit SetCreditManagerStatus(creditManager, newStatus);
        }
    }

    /// @dev Reverts if caller is not credit facade
    function _revertIfCallerNotValidCreditFacade(address creditManager) internal view {
        if (!approvedCreditManager[creditManager] || ICreditManagerV3(creditManager).creditFacade() != msg.sender) {
            revert CallerNotCreditFacadeException();
        }
    }

    /// @notice Allows this contract to receive ETH, wraps it immediately if caller is not WETH
    receive() external payable {
        if (msg.sender != weth) deposit();
    }
}
