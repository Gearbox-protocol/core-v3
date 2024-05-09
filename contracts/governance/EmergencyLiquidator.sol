// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";
import {SafeERC20} from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";

import {ACLNonReentrantTrait} from "../traits/ACLNonReentrantTrait.sol";
import {ICreditManagerV3} from "../interfaces/ICreditManagerV3.sol";
import {ICreditFacadeV3, MultiCall} from "../interfaces/ICreditFacadeV3.sol";
import {ICreditFacadeV3Multicall} from "../interfaces/ICreditFacadeV3Multicall.sol";

interface IEmergencyLiquidatorExceptions {
    /// @dev Thrown when a non-whitelisted account attempts to liquidate an account during pause
    error NonWhitelistedLiquidationDuringPauseException();

    /// @dev Thrown when a non-whitelisted account attempts to liquidate an account with loss
    error NonWhitelistedLiquidationWithLossException();

    /// @dev Thrown when liquidation calls contain withdrawals to an address other than emergency liquidator contract
    error WithdrawalToExternalAddressException();

    /// @dev Thrown when a non-whitelisted address attempts to call an access-restricted function
    error CallerNotWhitelistedException();
}

interface IEmergencyLiquidatorEvents {
    /// @dev Emitted when a new account is added to / removed from the whitelist
    event SetWhitelistedStatus(address indexed account, bool newStatus);

    /// @dev Emitted when liquidating during pause is allowed / disallowed
    event SetWhitelistedOnlyDuringPause(bool newStatus);

    /// @dev Emitted when liquidating with loss is allowed / disallowed
    event SetWhitelistedOnlyWithLoss(bool newStatus);
}

contract EmergencyLiquidator is ACLNonReentrantTrait, IEmergencyLiquidatorExceptions, IEmergencyLiquidatorEvents {
    using SafeERC20 for IERC20;

    /// @dev Thrown when the access-restricted function's caller is not treasury
    error CallerNotTreasuryException();

    /// @notice Whether the address is a trusted account capable of doing whitelist-only actions
    mapping(address => bool) public isWhitelisted;

    /// @notice Whether the emergency liquidator currently allows anyone to liquidate during pause
    ///         or only whitelisted addresses
    bool public whitelistedOnlyDuringPause;

    /// @notice Whether the emergency liquidator currently allows anyone to liquidate with loss or only
    ///         whitelisted addresses
    bool public whitelistedOnlyWithLoss;

    constructor(address _addressProvider) ACLNonReentrantTrait(_addressProvider) {}

    modifier whitelistedOnly() {
        if (!isWhitelisted[msg.sender]) revert CallerNotWhitelistedException();
        _;
    }

    /// @dev Checks that the liquidation satisfies certain criteria if the account is not whitelisted, reverts if not:
    ///      - If the contract is paused, checks whether liquidations during pause are available to non-whitelisted accounts
    ///      - If the liquidation is lossy (detected by Credit Facade internal loss counter increasing), checks whether lossy liquidations are available
    ///        to non-whitelisted account
    modifier checkWhitelistedActions(address creditFacade) {
        if (isWhitelisted[msg.sender]) {
            _;
        } else {
            if (Pausable(creditFacade).paused() && whitelistedOnlyDuringPause) {
                revert NonWhitelistedLiquidationDuringPauseException();
            }

            uint128 cumulativeLossBefore;

            if (whitelistedOnlyWithLoss) {
                cumulativeLossBefore = _cumulativeLoss(creditFacade);
            }

            _;

            if (whitelistedOnlyWithLoss) {
                uint128 cumulativeLossAfter = _cumulativeLoss(creditFacade);

                if (cumulativeLossAfter > cumulativeLossBefore) {
                    revert NonWhitelistedLiquidationWithLossException();
                }
            }
        }
    }

    /// @dev Checks that all withdrawals are sent to this contract, reverts if not
    modifier checkWithdrawalDestinations(address creditFacade, MultiCall[] calldata calls) {
        _checkWithdrawalsDestination(creditFacade, calls);
        _;
    }

    /// @notice Liquidates a credit account, while checking restrictions on liquidations during pause (if any)
    function liquidateCreditAccount(address creditFacade, address creditAccount, MultiCall[] calldata calls)
        external
        checkWithdrawalDestinations(creditFacade, calls)
        checkWhitelistedActions(creditFacade)
    {
        ICreditFacadeV3(creditFacade).liquidateCreditAccount(creditAccount, address(this), calls);
    }

    /// @notice Liquidates a credit account with max underlying approval, allowing to buy collateral with DAO funds
    /// @dev Can be exploited by account owners when open to everyone, and thus is only allowed for whitelisted addresses
    function liquidateCreditAccountWithApproval(address creditFacade, address creditAccount, MultiCall[] calldata calls)
        external
        checkWithdrawalDestinations(creditFacade, calls)
        whitelistedOnly
    {
        address creditManager = ICreditFacadeV3(creditFacade).creditManager();
        address underlying = ICreditManagerV3(creditManager).underlying();

        IERC20(underlying).forceApprove(creditManager, type(uint256).max);
        ICreditFacadeV3(creditFacade).liquidateCreditAccount(creditAccount, address(this), calls);
        IERC20(underlying).forceApprove(creditManager, 1);
    }

    /// @dev Checks that the provided calldata has all withdrawals sent to this contract
    function _checkWithdrawalsDestination(address creditFacade, MultiCall[] calldata calls) internal view {
        uint256 len = calls.length;

        for (uint256 i = 0; i < len;) {
            if (
                calls[i].target == creditFacade
                    && bytes4(calls[i].callData) == ICreditFacadeV3Multicall.withdrawCollateral.selector
            ) {
                (,, address to) = abi.decode(calls[i].callData[4:], (address, uint256, address));

                if (to != address(this)) revert WithdrawalToExternalAddressException();
            }

            unchecked {
                ++i;
            }
        }
    }

    /// @dev Retrieves cumulative loss for a credit facade
    function _cumulativeLoss(address creditFacade) internal view returns (uint128 cumulativeLoss) {
        (cumulativeLoss,) = ICreditFacadeV3(creditFacade).lossParams();
    }

    /// @notice Sends funds accumulated from liquidations to a specified address
    function withdrawFunds(address token, address to) external configuratorOnly {
        uint256 bal = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(to, bal);
    }

    /// @notice Sets the status of an account as whitelisted
    function setWhitelistedAccount(address account, bool newStatus) external configuratorOnly {
        bool whitelistedStatus = isWhitelisted[account];

        if (newStatus != whitelistedStatus) {
            isWhitelisted[account] = newStatus;
            emit SetWhitelistedStatus(account, newStatus);
        }
    }

    /// @notice Sets whether liquidations during pause are only allowed to whitelisted addresses
    function setWhitelistedOnlyDuringPause(bool newStatus) external configuratorOnly {
        bool currentStatus = whitelistedOnlyDuringPause;

        if (newStatus != currentStatus) {
            whitelistedOnlyDuringPause = newStatus;
            emit SetWhitelistedOnlyDuringPause(newStatus);
        }
    }

    /// @notice Sets whether liquidations with loss are only allowed to whitelisted addresses
    function setWhitelistedOnlyWithLoss(bool newStatus) external configuratorOnly {
        bool currentStatus = whitelistedOnlyWithLoss;

        if (newStatus != currentStatus) {
            whitelistedOnlyWithLoss = newStatus;
            emit SetWhitelistedOnlyWithLoss(newStatus);
        }
    }
}
