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

    /// @dev Mapping from (creditAccount, bot) to bit permissions
    mapping(address => mapping(address => uint192)) public botPermissions;

    /// @dev Mapping from credit account to the set of bots with non-zero permissions
    mapping(address => EnumerableSet.AddressSet) internal activeBots;

    /// @dev Whether the bot is forbidden system-wide
    mapping(address => bool) public forbiddenBot;

    /// @dev Mapping from borrower to their bot funding balance
    mapping(address => uint256) public fundingBalances;

    /// @dev Mapping of (creditAccount, bot) to bot funding parameters
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
            revert CallerNotCreditAccountFacadeException();
        }
        _;
    }

    /// @dev Sets permissions and funding for (creditAccount, bot). Callable only through CreditFacade
    /// @param creditAccount CA to set permissions for
    /// @param bot Bot to set permissions for
    /// @param permissions A bit mask of permissions
    /// @param fundingAmount Total amount of ETH available to the bot for payments
    /// @param weeklyFundingAllowance Amount of ETH available to the bot weekly
    function setBotPermissions(
        address creditAccount,
        address bot,
        uint192 permissions,
        uint72 fundingAmount,
        uint72 weeklyFundingAllowance
    ) external nonZeroAddress(bot) onlyCreditAccountFacade(creditAccount) returns (uint256 activeBotsRemaining) {
        if (!bot.isContract()) {
            revert AddressIsNotContractException(bot);
        }

        if (forbiddenBot[bot] && permissions != 0) {
            revert InvalidBotException();
        }

        if (permissions != 0) {
            activeBots[creditAccount].add(bot);
        } else if (permissions == 0) {
            if (fundingAmount != 0 || weeklyFundingAllowance != 0) {
                revert PositiveFundingForInactiveBotException();
            }

            activeBots[creditAccount].remove(bot);
        }

        botPermissions[creditAccount][bot] = permissions;
        botFunding[creditAccount][bot].remainingFunds = fundingAmount;
        botFunding[creditAccount][bot].maxWeeklyAllowance = weeklyFundingAllowance;
        botFunding[creditAccount][bot].remainingWeeklyAllowance = weeklyFundingAllowance;
        botFunding[creditAccount][bot].allowanceLU = uint40(block.timestamp);

        activeBotsRemaining = activeBots[creditAccount].length();

        emit SetBotPermissions(creditAccount, bot, permissions, fundingAmount, weeklyFundingAllowance);
    }

    /// @dev Removes permissions and funding for all bots with non-zero permissions for a credit account
    /// @param creditAccount Credit Account to erase permissions for
    function eraseAllBotPermissions(address creditAccount) external onlyCreditAccountFacade(creditAccount) {
        uint256 len = activeBots[creditAccount].length();

        for (uint256 i = 0; i < len;) {
            address bot = activeBots[creditAccount].at(0);
            botPermissions[creditAccount][bot] = 0;
            botFunding[creditAccount][bot].remainingFunds = 0;
            botFunding[creditAccount][bot].maxWeeklyAllowance = 0;
            botFunding[creditAccount][bot].remainingWeeklyAllowance = 0;
            botFunding[creditAccount][bot].allowanceLU = uint40(block.timestamp);
            activeBots[creditAccount].remove(bot);
            unchecked {
                ++i;
            }
        }

        if (len > 0) {
            emit EraseBots(creditAccount);
        }
    }

    /// @dev Takes payment from the user to the bot for performed services
    /// @param creditAccount Address of the credit account paid for
    /// @param paymentAmount Amount to pull
    function pullPayment(address creditAccount, uint72 paymentAmount) external nonReentrant {
        if (paymentAmount == 0) {
            revert AmountCantBeZeroException();
        }

        address payer = _getCreditAccountOwner(creditAccount);

        BotFunding storage bf = botFunding[creditAccount][msg.sender];

        if (block.timestamp >= bf.allowanceLU + uint40(7 days)) {
            bf.allowanceLU = uint40(block.timestamp);
            bf.remainingWeeklyAllowance = bf.maxWeeklyAllowance;
        }

        uint72 feeAmount = daoFee * paymentAmount / PERCENTAGE_FACTOR;

        bf.remainingWeeklyAllowance -= paymentAmount + feeAmount;
        bf.remainingFunds -= paymentAmount + feeAmount;

        fundingBalances[payer] -= uint256(paymentAmount + feeAmount);

        payable(msg.sender).sendValue(paymentAmount);
        if (feeAmount > 0) payable(treasury).sendValue(feeAmount);

        emit PullBotPayment(payer, creditAccount, msg.sender, paymentAmount, feeAmount);
    }

    /// @dev Adds funds to the borrower's bot payment wallet
    function addFunding() external payable nonReentrant {
        if (msg.value == 0) {
            revert AmountCantBeZeroException();
        }

        uint256 newFunds = fundingBalances[msg.sender] + msg.value;

        fundingBalances[msg.sender] = newFunds;

        emit ChangeFunding(msg.sender, newFunds);
    }

    /// @dev Removes funds from the borrower's bot payment wallet
    function removeFunding(uint256 amount) external nonReentrant {
        uint256 newFunds = fundingBalances[msg.sender] - amount;

        fundingBalances[msg.sender] = newFunds;
        payable(msg.sender).sendValue(amount);

        emit ChangeFunding(msg.sender, newFunds);
    }

    /// @dev Returns all active bots currently on the account
    function getActiveBots(address creditAccount) external view returns (address[] memory) {
        return activeBots[creditAccount].values();
    }

    /// @dev Internal function to retrieve the bot's owner
    function _getCreditAccountOwner(address creditAccount) internal view returns (address owner) {
        address creditManager = ICreditAccount(creditAccount).creditManager();
        return ICreditManagerV3(creditManager).getBorrowerOrRevert(creditAccount);
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
