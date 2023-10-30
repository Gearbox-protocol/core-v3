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

import {
    IAddressProviderV3, AP_TREASURY, AP_WETH_TOKEN, NO_VERSION_CONTROL
} from "../interfaces/IAddressProviderV3.sol";
import {IBotListV3, BotFunding, BotInfo} from "../interfaces/IBotListV3.sol";
import {ICreditManagerV3} from "../interfaces/ICreditManagerV3.sol";
import {ICreditFacadeV3} from "../interfaces/ICreditFacadeV3.sol";
import "../interfaces/IExceptions.sol";

import {ACLNonReentrantTrait} from "../traits/ACLNonReentrantTrait.sol";
import {ContractsRegisterTrait} from "../traits/ContractsRegisterTrait.sol";

/// @title Bot list V3
/// @notice Stores bot permissions (bit masks dictating which actions can be performed with credit accounts in multicall),
///         funding parameters (total or weekly allowance) and WETH funding balances used for bot payments.
///         Besides normal per-account permissions, there are special per-manager permissions that apply to all accounts
///         in a given credit manager and can be used to extend the core system or enforce additional safety measures
///         with special DAO-approved bots.
contract BotListV3 is ACLNonReentrantTrait, ContractsRegisterTrait, IBotListV3 {
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

    /// @notice Payment fee in bps
    uint16 public override paymentFee = 0;

    /// @notice Collected payment fees in WETH
    uint64 public override collectedPaymentFees = 0;

    /// @notice Credit manager's approved status
    mapping(address => bool) public override approvedCreditManager;

    /// @dev Mapping bot => info
    mapping(address => BotInfo) internal _botInfo;

    /// @dev Mapping credit manager => credit account => set of bots with non-zero permissions
    mapping(address => mapping(address => EnumerableSet.AddressSet)) internal _activeBots;

    /// @notice Account's funding balance
    mapping(address => uint256) public override balanceOf;

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
    {
        treasury = IAddressProviderV3(addressProvider).getAddressOrRevert(AP_TREASURY, NO_VERSION_CONTROL);
        weth = IAddressProviderV3(addressProvider).getAddressOrRevert(AP_WETH_TOKEN, NO_VERSION_CONTROL);
    }

    /// @notice Allows this contract to receive ETH, deposits it to caller's funding balance unless caller is WETH
    receive() external payable {
        if (msg.sender != weth) deposit();
    }

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

    /// @notice Returns `bot`'s funding params for `creditAccount` in `creditManager`
    function botFunding(address bot, address creditManager, address creditAccount)
        external
        view
        override
        returns (BotFunding memory)
    {
        return _botInfo[bot].funding[creditManager][creditAccount];
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

    /// @notice Sets `bot`'s permissions and funding params for `creditAccount` in `creditManager`
    /// @param bot Bot to set permissions for
    /// @param creditManager Credit manager to set permissions in
    /// @param creditAccount Credit account to set permissions for
    /// @param permissions A bit mask of permissions
    /// @param totalFundingAllowance Amount of WETH available to the bot for payments in total
    /// @param weeklyFundingAllowance Amount of WETH available to the bot for payments weekly
    /// @return activeBotsRemaining Number of bots with non-zero permissions remaining after the update
    /// @dev Reverts if caller is not a facade connected to approved `creditManager`
    /// @dev Reverts if `bot` is zero address or not a contract
    /// @dev Reverts if trying to set non-zero permissions for a forbidden bot or for a bot with special permissions
    function setBotPermissions(
        address bot,
        address creditManager,
        address creditAccount,
        uint192 permissions,
        uint72 totalFundingAllowance,
        uint72 weeklyFundingAllowance
    )
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
            info.funding[creditManager][creditAccount] = BotFunding({
                totalFundingAllowance: totalFundingAllowance,
                maxWeeklyAllowance: weeklyFundingAllowance,
                remainingWeeklyAllowance: weeklyFundingAllowance,
                lastAllowanceUpdate: uint40(block.timestamp)
            });

            emit SetBotPermissions(
                bot, creditManager, creditAccount, permissions, totalFundingAllowance, weeklyFundingAllowance
            );
        } else {
            _eraseBot(bot, creditManager, creditAccount);
            accountBots.remove(bot);
        }

        activeBotsRemaining = accountBots.length();
    }

    /// @notice Removes all bots' permissions and funding params for `creditAccount` in `creditManager`
    function eraseAllBotPermissions(address creditManager, address creditAccount)
        external
        override
        onlyValidCreditFacade(creditManager)
    {
        EnumerableSet.AddressSet storage accountBots = _activeBots[creditManager][creditAccount];
        unchecked {
            for (uint256 len = accountBots.length(); len != 0; --len) {
                address bot = accountBots.at(len - 1);
                _eraseBot(bot, creditManager, creditAccount);
                accountBots.remove(bot);
            }
        }
    }

    // -------- //
    // PAYMENTS //
    // -------- //

    /// @notice Pays `bot` for operation on `creditAccount` in `creditManager` from `payer`' balance,
    ///         additionally charges payment fee which is accumulated in `collectedPaymentFees` and
    ///         can be transferred to the treasury via `transferCollectedPaymentFees`
    /// @param bot Bot to pay
    /// @param creditManager Credit manager operation was performed in
    /// @param creditAccount Credit account operation was performed on
    /// @param payer Account to charge
    /// @param paymentAmount Amount of WETH to pay
    /// @dev Reverts if caller is not a facade connected to approved `creditManager`
    /// @dev Reverts if `bot` has insufficient total or weekly funding allowance
    function payBot(address bot, address creditManager, address creditAccount, address payer, uint72 paymentAmount)
        external
        override
        onlyValidCreditFacade(creditManager)
    {
        if (paymentAmount == 0) return;

        BotFunding storage bf = _botInfo[bot].funding[creditManager][creditAccount];

        uint72 remainingWeeklyAllowance;
        if (block.timestamp >= bf.lastAllowanceUpdate + uint40(7 days)) {
            remainingWeeklyAllowance = bf.maxWeeklyAllowance;
            bf.lastAllowanceUpdate = uint40(block.timestamp);
        } else {
            remainingWeeklyAllowance = bf.remainingWeeklyAllowance;
        }

        uint72 feeAmount = uint72(uint256(paymentFee) * paymentAmount / PERCENTAGE_FACTOR);
        uint72 totalAmount = paymentAmount + feeAmount;

        if (remainingWeeklyAllowance < totalAmount) revert InsufficientWeeklyFundingAllowance();
        unchecked {
            bf.remainingWeeklyAllowance = remainingWeeklyAllowance - totalAmount;
        }

        uint72 totalFundingAllowance = bf.totalFundingAllowance;
        if (totalFundingAllowance < totalAmount) revert InsufficientTotalFundingAllowance();
        unchecked {
            bf.totalFundingAllowance = totalFundingAllowance - totalAmount;
        }

        _safeDecreaseBalance(payer, totalAmount);
        IERC20(weth).safeTransfer(bot, paymentAmount);

        if (feeAmount != 0) {
            uint256 newCollectedPaymentFees = uint256(collectedPaymentFees) + feeAmount;
            if (newCollectedPaymentFees >= type(uint64).max) {
                _transferCollectedPaymentFees(newCollectedPaymentFees);
            } else {
                collectedPaymentFees = uint64(newCollectedPaymentFees);
            }
        }

        emit PayBot(bot, creditManager, creditAccount, payer, paymentAmount, feeAmount);
    }

    /// @notice Deposits ETH to caller's funding balance
    function deposit() public payable override nonReentrant {
        if (msg.value == 0) revert AmountCantBeZeroException();

        IWETH(weth).deposit{value: msg.value}();
        balanceOf[msg.sender] += msg.value;

        emit Deposit(msg.sender, msg.value);
    }

    /// @notice Withdraws `amount` of ETH from caller's funding balance
    function withdraw(uint256 amount) external override nonReentrant {
        if (amount == 0) revert AmountCantBeZeroException();

        _safeDecreaseBalance(msg.sender, amount);
        IWETH(weth).withdraw(amount);
        payable(msg.sender).sendValue(amount);

        emit Withdraw(msg.sender, amount);
    }

    /// @notice Transfers collected payment fees to the treasury
    function transferCollectedPaymentFees() external override {
        _transferCollectedPaymentFees(collectedPaymentFees);
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

    /// @notice Sets the payment fee to `newPaymentFee` (expects value below 100% in bps)
    function setPaymentFee(uint16 newPaymentFee) external override configuratorOnly {
        if (newPaymentFee > PERCENTAGE_FACTOR) revert IncorrectParameterException();
        if (paymentFee != newPaymentFee) {
            paymentFee = newPaymentFee;
            emit SetPaymentFee(newPaymentFee);
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

    /// @dev Removes `bot`'s permissions and funding params for `creditAccount` in `creditManager`
    function _eraseBot(address bot, address creditManager, address creditAccount) internal {
        BotInfo storage info = _botInfo[bot];
        delete info.permissions[creditManager][creditAccount];
        delete info.funding[creditManager][creditAccount];

        emit EraseBot(bot, creditManager, creditAccount);
    }

    /// @dev Transfers `amount` of WETH to the treasury and resets collected payment fees to zero
    function _transferCollectedPaymentFees(uint256 amount) internal {
        if (amount > 0) {
            IERC20(weth).safeTransfer(treasury, amount);
            collectedPaymentFees = 0;
            emit TransferCollectedPaymentFees(amount);
        }
    }

    /// @dev Decreases `account`'s funding balance by `amount`
    function _safeDecreaseBalance(address account, uint256 amount) internal {
        uint256 balance = balanceOf[account];
        if (balance < amount) revert InsufficientBalanceException();
        unchecked {
            balanceOf[account] = balance - amount;
        }
    }
}
