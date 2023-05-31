// SPDX-License-Identifier: BUSL-1.1
// Gearbox. Generalized leverage protocol that allows to take leverage and then use it across other DeFi protocols and platforms in a composable way.
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IWETH} from "@gearbox-protocol/core-v2/contracts/interfaces/external/IWETH.sol";
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";

import "../interfaces/IAddressProviderV3.sol";
import {ACLNonReentrantTrait} from "../traits/ACLNonReentrantTrait.sol";
import {IBotListV3, BotFunding} from "../interfaces/IBotListV3.sol";
import {ICreditManagerV3} from "../interfaces/ICreditManagerV3.sol";
import {ICreditFacadeV3} from "../interfaces/ICreditFacadeV3.sol";
import {ICreditAccountBase} from "../interfaces/ICreditAccountV3.sol";

import "../interfaces/IExceptions.sol";

/// @title BotList
/// @notice Used to store a mapping of borrowers => bots. A separate contract is used for transferability when
///      changing Credit Facades
contract BotListV3 is ACLNonReentrantTrait, IBotListV3 {
    using SafeCast for uint256;
    using Address for address;
    using Address for address payable;
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for IERC20;

    /// @notice Contract version
    uint256 public constant override version = 3_00;

    /// @notice Address of the DAO treasury
    address public immutable treasury;

    /// @notice Address of the DAO treasury
    address public immutable weth;

    /// @notice ERC20 compatibility to be able to add to wallet to manager user's bot funding
    string public constant symbol = "gETH";

    /// @notice ERC20 compatibility to be able to add to wallet to manager user's bot funding
    string public constant name = "Gearbox bot funding";

    /// @notice Mapping from Credit Manager address to their status as an approved Credit Manager
    ///      Only Credit Facades connected to approved Credit Managers can alter bot permissions
    mapping(address => bool) public approvedCreditManager;

    /// @notice Mapping from (creditAccount, bot) to bit permissions
    mapping(address => mapping(address => uint192)) public botPermissions;

    /// @notice Mapping from credit account to the set of bots with non-zero permissions
    mapping(address => EnumerableSet.AddressSet) internal activeBots;

    /// @notice Whether the bot is forbidden system-wide
    mapping(address => bool) public forbiddenBot;

    /// @notice Mapping from borrower to their bot funding balance
    mapping(address => uint256) public override balanceOf;

    /// @notice Mapping of (creditAccount, bot) to bot funding parameters
    mapping(address => mapping(address => BotFunding)) public botFunding;

    /// @notice A fee (in PERCENTAGE_FACTOR format) charged by the DAO on bot payments
    uint16 public daoFee = 0;

    constructor(address addressProvider) ACLNonReentrantTrait(addressProvider) {
        treasury = IAddressProviderV3(addressProvider).getAddressOrRevert(AP_TREASURY, NO_VERSION_CONTROL);
        weth = IAddressProviderV3(addressProvider).getAddressOrRevert(AP_WETH_TOKEN, NO_VERSION_CONTROL);
    }

    /// @notice Limits access to a function only to Credit Facades connected to approved CMs
    modifier onlyValidCreditFacade() {
        address creditManager = ICreditFacadeV3(msg.sender).creditManager();
        if (!approvedCreditManager[creditManager] || ICreditManagerV3(creditManager).creditFacade() != msg.sender) {
            revert CallerNotCreditFacadeException();
        }
        _;
    }

    /// @notice Sets permissions and funding for (creditAccount, bot). Callable only through CreditFacade
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
    )
        external
        nonZeroAddress(bot)
        onlyValidCreditFacade // F: [BL-03]
        returns (uint256 activeBotsRemaining)
    {
        if (!bot.isContract()) {
            revert AddressIsNotContractException(bot); // F: [BL-03]
        }

        if (forbiddenBot[bot] && permissions != 0) {
            revert InvalidBotException(); // F: [BL-03]
        }

        if (permissions != 0) {
            activeBots[creditAccount].add(bot); // F: [BL-03]

            botPermissions[creditAccount][bot] = permissions; // F: [BL-03]

            BotFunding storage bf = botFunding[creditAccount][bot];

            bf.remainingFunds = fundingAmount; // F: [BL-03]
            bf.maxWeeklyAllowance = weeklyFundingAllowance; // F: [BL-03]
            bf.remainingWeeklyAllowance = weeklyFundingAllowance; // F: [BL-03]
            bf.allowanceLU = uint40(block.timestamp); // F: [BL-03]

            emit SetBotPermissions({
                creditAccount: creditAccount,
                bot: bot,
                permissions: permissions,
                fundingAmount: fundingAmount,
                weeklyFundingAllowance: weeklyFundingAllowance
            }); // F: [BL-03]
        } else {
            _ereaseBot(creditAccount, bot); // F: [BL-03]
        }

        activeBotsRemaining = activeBots[creditAccount].length(); // F: [BL-03]
    }

    /// @notice Removes permissions and funding for all bots with non-zero permissions for a credit account
    /// @param creditAccount Credit Account to erase permissions for
    function eraseAllBotPermissions(address creditAccount)
        external
        onlyValidCreditFacade // F: [BL-06]
    {
        uint256 len = activeBots[creditAccount].length();

        unchecked {
            for (uint256 i = 0; i < len; ++i) {
                address bot = activeBots[creditAccount].at(len - i - 1); // F: [BL-06]
                _ereaseBot(creditAccount, bot);
            }
        }
    }

    function _ereaseBot(address creditAccount, address bot) internal {
        delete botPermissions[creditAccount][bot]; // F: [BL-06]
        delete botFunding[creditAccount][bot]; // F: [BL-06]

        activeBots[creditAccount].remove(bot); // F: [BL-06]
        emit EraseBot(creditAccount, bot); // F: [BL-06]
    }

    /// @notice Takes payment for performed services from the user's balance and sends to the bot
    /// @param payer Address to charge
    /// @param creditAccount Address of the credit account paid for
    /// @param bot Address of the bot to pay
    /// @param paymentAmount Amount to pay
    function payBot(address payer, address creditAccount, address bot, uint72 paymentAmount)
        external
        onlyValidCreditFacade
    {
        if (paymentAmount == 0) return;

        BotFunding storage bf = botFunding[creditAccount][bot]; // F: [BL-05]

        if (block.timestamp >= bf.allowanceLU + uint40(7 days)) {
            bf.allowanceLU = uint40(block.timestamp); // F: [BL-05]
            bf.remainingWeeklyAllowance = bf.maxWeeklyAllowance; // F: [BL-05]
        }

        /// feeAmount is always < paymentAmount, however uint256 conversation adds more space for computations
        uint72 feeAmount = uint72(uint256(daoFee) * paymentAmount / PERCENTAGE_FACTOR); // F: [BL-05]

        uint72 totalAmount = paymentAmount + feeAmount;

        bf.remainingWeeklyAllowance -= totalAmount; // F: [BL-05]
        bf.remainingFunds -= totalAmount; // F: [BL-05]

        balanceOf[payer] -= totalAmount; // F: [BL-05]

        IERC20(weth).safeTransfer(bot, paymentAmount); // F: [BL-05]

        if (feeAmount != 0) {
            IERC20(weth).safeTransfer(treasury, feeAmount); // F: [BL-05]
        }

        emit PayBot(payer, creditAccount, bot, paymentAmount, feeAmount); // F: [BL-05]
    }

    /// @notice Adds funds to the borrower's bot payment wallet
    function deposit() public payable nonReentrant {
        if (msg.value == 0) {
            revert AmountCantBeZeroException(); // F: [BL-04]
        }

        IWETH(weth).deposit{value: msg.value}();
        balanceOf[msg.sender] += msg.value;

        emit Deposit(msg.sender, msg.value); // F: [BL-04]
    }

    /// @notice Removes funds from the borrower's bot payment wallet
    function withdraw(uint256 amount) external nonReentrant {
        balanceOf[msg.sender] -= amount; // F: [BL-04]

        IWETH(weth).withdraw(amount);
        payable(msg.sender).sendValue(amount); // F: [BL-04]

        emit Withdraw(msg.sender, amount); // F: [BL-04]
    }

    /// @notice Returns all active bots currently on the account
    function getActiveBots(address creditAccount) external view returns (address[] memory) {
        return activeBots[creditAccount].values();
    }

    /// @notice Returns information about bot permissions
    function getBotStatus(address bot, address creditAccount)
        external
        view
        returns (uint192 permissions, bool forbidden)
    {
        return (botPermissions[creditAccount][bot], forbiddenBot[bot]);
    }

    //
    // CONFIGURATION
    //

    /// @notice Forbids the bot system-wide if it is known to be compromised
    function setBotForbiddenStatus(address bot, bool status) external configuratorOnly {
        forbiddenBot[bot] = status;
        emit BotForbiddenStatusChanged(bot, status);
    }

    /// @notice Sets the DAO fee on bot payments
    /// @param newFee The new fee value
    function setDAOFee(uint16 newFee) external configuratorOnly {
        if (daoFee > PERCENTAGE_FACTOR) {
            revert IncorrectParameterException();
        }

        daoFee = newFee; // F: [BL-02]

        emit SetBotDAOFee(newFee); // F: [BL-02]
    }

    /// @notice Sets an address' status as an approved Credit Manager
    /// @param creditManager Address of the Credit Manager to change status for
    /// @param status The new status
    function setApprovedCreditManagerStatus(address creditManager, bool status) external configuratorOnly {
        approvedCreditManager[creditManager] = status;

        if (status) {
            emit CreditManagerAdded(creditManager);
        } else {
            emit CreditManagerRemoved(creditManager);
        }
    }

    /// @notice Allows this contract to unwrap WETH and deposit if address is not WETH
    receive() external payable {
        if (msg.sender != address(weth)) deposit();
    }
}
