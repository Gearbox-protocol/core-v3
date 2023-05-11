// SPDX-License-Identifier: BUSL-1.1
// Gearbox. Generalized leverage protocol that allows to take leverage and then use it across other DeFi protocols and platforms in a composable way.
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.10;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {ACLNonReentrantTrait} from "../traits/ACLNonReentrantTrait.sol";
import {IBotList, BotFunding} from "../interfaces/IBotList.sol";
import {IAddressProvider} from "@gearbox-protocol/core-v2/contracts/interfaces/IAddressProvider.sol";
import {ICreditAccount} from "../interfaces/ICreditAccount.sol";
import {ICreditManagerV3} from "../interfaces/ICreditManagerV3.sol";

import "../interfaces/IExceptions.sol";
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/PercentageMath.sol";

/// @title BotList
/// @dev Used to store a mapping of borrowers => bots. A separate contract is used for transferability when
///      changing Credit Facades
contract BotList is ACLNonReentrantTrait, IBotList {
    using SafeCast for uint256;
    using Address for address;
    using Address for address payable;
    using EnumerableSet for EnumerableSet.AddressSet;

    error CallerNotCreditAccountOwner();
    error CallerNotCreditAccountFacade();

    event EraseBots(address creditAccount);

    /// @dev Mapping from (creditAccount, bot) to bit permissions
    mapping(address => mapping(address => uint192)) public botPermissions;

    /// @dev Mapping from credit account to the set of bots with non-zero permissions
    mapping(address => EnumerableSet.AddressSet) internal activeBots;

    /// @dev Whether the bot is forbidden system-wide
    mapping(address => bool) public forbiddenBot;

    /// @dev Mapping of (borrower, bot) to bot funding parameters
    mapping(address => mapping(address => BotFunding)) public botFunding;

    /// @dev A fee (in PERCENTAGE_FACTOR format) charged by the DAO on bot payments
    uint16 public daoFee = 0;

    /// @dev Address of the DAO treasury
    address public immutable treasury;

    /// @dev Contract version
    uint256 public constant override version = 3_00;

    constructor(address _addressProvider) ACLNonReentrantTrait(_addressProvider) {
        treasury = IAddressProvider(_addressProvider).getTreasuryContract();
    }

    modifier onlyCreditAccountFacade(address creditAccount) {
        address creditManager = ICreditAccount(creditAccount).creditManager();
        if (msg.sender != ICreditManagerV3(creditManager).creditFacade()) {
            revert CallerNotCreditAccountFacade();
        }
        _;
    }

    /// @dev Adds or removes allowance for a bot to execute multicalls on behalf of sender
    /// @param bot Bot address
    /// @param permissions Whether allowance is added or removed
    function setBotPermissions(address creditAccount, address bot, uint192 permissions)
        external
        nonZeroAddress(bot)
        onlyCreditAccountFacade(creditAccount)
        returns (uint256 activeBotsRemaining)
    {
        if (!bot.isContract()) {
            revert AddressIsNotContractException(bot);
        }

        if (forbiddenBot[bot] && permissions != 0) {
            revert InvalidBotException();
        }

        uint192 currentPermissions = botPermissions[creditAccount][bot];

        if (currentPermissions == 0 && permissions != 0) {
            activeBots[creditAccount].add(bot);
        } else if (currentPermissions != 0 && permissions == 0) {
            activeBots[creditAccount].remove(bot);
        }

        botPermissions[creditAccount][bot] = permissions;
        activeBotsRemaining = activeBots[creditAccount].length();

        emit ApproveBot(creditAccount, bot, permissions);
    }

    /// @dev Removes permissions for all bots with non-zero permissions for a credit account
    /// @param creditAccount Credit Account to erase permissions for
    function eraseAllBotPermissions(address creditAccount) external onlyCreditAccountFacade(creditAccount) {
        uint256 len = activeBots[creditAccount].length();

        for (uint256 i = 0; i < len;) {
            address bot = activeBots[creditAccount].at(0);
            botPermissions[creditAccount][bot] = 0;
            activeBots[creditAccount].remove(bot);
            unchecked {
                ++i;
            }
        }

        if (len > 0) {
            emit EraseBots(creditAccount);
        }
    }

    /// @dev Adds funds to user's balance for a particular bot. The entire sent value in ETH is added
    /// @param bot Address of the bot to fund
    function increaseBotFunding(address bot) external payable nonReentrant {
        if (msg.value == 0) {
            revert AmountCantBeZeroException();
        }

        if (forbiddenBot[bot] || botPermissions[msg.sender][bot] == 0) {
            revert InvalidBotException();
        }

        uint72 newRemainingFunds = botFunding[msg.sender][bot].remainingFunds + msg.value.toUint72();

        botFunding[msg.sender][bot].remainingFunds = newRemainingFunds;

        emit ChangeBotFunding(msg.sender, bot, newRemainingFunds);
    }

    /// @dev Removes funds from the user's balance for a particular bot. The funds are sent to the user.
    /// @param bot Address of the bot to remove funds from
    /// @param decreaseAmount Amount to remove
    function decreaseBotFunding(address bot, uint72 decreaseAmount) external nonReentrant {
        if (decreaseAmount == 0) {
            revert AmountCantBeZeroException();
        }

        uint72 newRemainingFunds = botFunding[msg.sender][bot].remainingFunds - decreaseAmount;

        botFunding[msg.sender][bot].remainingFunds = newRemainingFunds;
        payable(msg.sender).sendValue(decreaseAmount);

        emit ChangeBotFunding(msg.sender, bot, newRemainingFunds);
    }

    /// @dev Sets the amount that can be pull by the bot per week
    /// @param bot Address of the bot to set allowance for
    /// @param allowanceAmount Amount of weekly allowance
    function setWeeklyBotAllowance(address bot, uint72 allowanceAmount) external nonReentrant {
        BotFunding memory bf = botFunding[msg.sender][bot];

        bf.maxWeeklyAllowance = allowanceAmount;
        bf.remainingWeeklyAllowance =
            bf.remainingWeeklyAllowance > allowanceAmount ? allowanceAmount : bf.remainingWeeklyAllowance;

        botFunding[msg.sender][bot] = bf;

        emit ChangeBotWeeklyAllowance(msg.sender, bot, allowanceAmount);
    }

    /// @dev Takes payment from the user to the bot for performed services
    /// @param payer Address of the paying user
    /// @param paymentAmount Amount to pull
    function pullPayment(address payer, uint72 paymentAmount) external nonReentrant {
        if (paymentAmount == 0) {
            revert AmountCantBeZeroException();
        }

        BotFunding memory bf = botFunding[payer][msg.sender];

        if (block.timestamp >= bf.allowanceLU + uint40(7 days)) {
            bf.allowanceLU = uint40(block.timestamp);
            bf.remainingWeeklyAllowance = bf.maxWeeklyAllowance;
        }

        uint72 feeAmount = daoFee * paymentAmount / PERCENTAGE_FACTOR;

        bf.remainingWeeklyAllowance -= paymentAmount + feeAmount;
        bf.remainingFunds -= paymentAmount + feeAmount;

        botFunding[payer][msg.sender] = bf;

        payable(msg.sender).sendValue(paymentAmount);
        if (feeAmount > 0) payable(treasury).sendValue(feeAmount);

        emit PullBotPayment(payer, msg.sender, paymentAmount, feeAmount);
    }

    //
    // CONFIGURATION
    //

    /// @dev Forbids the bot system-wide if it is known to be compromised
    function setBotForbiddenStatus(address bot, bool status) external configuratorOnly {
        forbiddenBot[bot] = status;
        emit BotForbiddenStatusChanged(bot, status);
    }

    /// @dev Sets the DAO fee on bot payments
    /// @param newFee The new fee value
    function setDAOFee(uint16 newFee) external configuratorOnly {
        daoFee = newFee;

        emit SetBotDAOFee(newFee);
    }
}
