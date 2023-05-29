// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

/// @dev Thrown on attempting to set an important address to zero address
error ZeroAddressException();

/// @dev Thrown on incorrect input parameter
error IncorrectParameterException();

error RegisteredCreditManagerOnlyException();

error RegisteredPoolOnlyException();

error WethPoolsOnlyException();

error ReceiveIsNotAllowedException();

error IncompatibleCreditManagerException();

/// @dev Reverts if address isn't found in address provider
error AddressNotFoundException();

/// @dev Thrown on attempting to set an EOA as an important contract in the system
error AddressIsNotContractException(address);

/// @dev Thrown on attempting to add a token that is already in a collateral list
error TokenAlreadyAddedException();

/// @dev Thrown on attempting to receive a token that is not a collateral token or was forbidden
error TokenNotAllowedException();

/// @dev Thrown on attempting to use a non-ERC20 contract or an EOA as a token
error IncorrectTokenContractException();

/// @dev Thrown on attempting to set a token price feed to an address that is not a
///      correct price feed
error IncorrectPriceFeedException();

/// @dev Thrown on attempting to get a result for a token that does not have a price feed
error PriceFeedNotExistsException();

error ForbiddenInWhitelistedModeException();

///
/// ACCESS
///

/// @dev Thrown on attempting to perform an action for an address that owns no Credit Account
error CallerNotCreditAccountOwnerException();

/// @dev Thrown on attempting to call an access restricted function as a non-Configurator
error CallerNotConfiguratorException();

/// @dev Thrown on attempting to call an access-restructed function not as account factory
error CallerNotAccountFactoryException();

/// @dev Thrown on attempting to call an access restricted function as a non-CreditManagerV3
error CallerNotCreditManagerException();

/// @dev Thrown if an access-restricted function is called by an address that is not
///      the connected Credit Facade
error CallerNotCreditFacadeException();

/// @dev Thrown on attempting to call an access restricted function as a non-Configurator
error CallerNotControllerException();

/// @dev Thrown on attempting to pause a contract as a non-Pausable admin
error CallerNotPausableAdminException();

/// @dev Thrown on attempting to pause a contract as a non-Unpausable admin
error CallerNotUnpausableAdminException();

/// @dev Thrown when a gauge-only function is called by non-gauge
error CallerNotGaugeException();

/// @dev Thrown when a poolQuotaKeeper function is called by non-pqk
error CallerNotPoolQuotaKeeperException();

/// @dev Thrown when `vote` or `unvote` are called from non-voter address
error CallerNotVoterException();

/// @dev Thrown if an access-restricted function is called by an address that is not
///      the connected Credit Facade, or an allowed adapter
error CallerNotAdapterException();

/// @dev Thrown if the newly set LT if zero or greater than the underlying's LT
error IncorrectLiquidationThresholdException();

/// @dev Thrown if borrowing limits are incorrect: minLimit > maxLimit or maxLimit > blockLimit
error IncorrectLimitsException();

/// @dev Thrown if the new expiration date is less than the current expiration date or block.timestamp
error IncorrectExpirationDateException();

/// @dev Thrown if an adapter that is already linked to a contract is being connected to another

/// @dev Thrown if a contract (adapter or Credit Facade) set in a Credit Configurator returns a wrong Credit Manager
///      or retrieving the Credit Manager from it fails
error IncompatibleContractException();

/// @dev Thrown if attempting to forbid an adapter that is not allowed for the Credit Manager
error AdapterIsNotRegisteredException();

/// @dev Thrown when attempting to limit a token that is not quotable in PoolQuotaKeeper
error TokenIsNotQuotedException();

// interface ICreditFacadeV3Exceptions is ICreditManagerV3Exceptions {
/// @dev Thrown if the CreditFacadeV3 is not expirable, and an aciton is attempted that
///      requires expirability
error NotAllowedWhenNotExpirableException();

/// @dev Thrown if a liquidator tries to liquidate an account with a health factor above 1
error CreditAccountNotLiquidatableException();

/// @dev Thrown if a selector that doesn't match any allowed function is passed to the Credit Facade
///      during a multicall
error UnknownMethodException();

/// @dev Thrown if too much new debt was taken within a single block
error BorrowedBlockLimitException();

/// @dev Thrown if the new debt principal for a CA falls outside of borrowing limits
error BorrowAmountOutOfLimitsException();

/// @dev Thrown if one of the balances on a Credit Account is less than expected
///      at the end of a multicall, if revertIfReceivedLessThan was called
error BalanceLessThanMinimumDesiredException(address);

/// @dev Thrown if a user attempts to open an account on a Credit Facade that has expired
error NotAllowedAfterExpirationException();

/// @dev Thrown if expected balances are attempted to be set through revertIfReceivedLessThan twice
error ExpectedBalancesAlreadySetException();

/// @dev Thrown if a Credit Account has enabled forbidden tokens and the owner attempts to perform an action
///      that is not allowed with any forbidden tokens enabled
error ForbiddenTokensException();

/// @dev Thrown when attempting to perform an action on behalf of a borrower that is blacklisted in the underlying token

/// @dev Thrown if botMulticall is called by an address that is not a bot for a specified borrower
error NotApprovedBotException();

/// CM

/// @dev Thrown on attempting to execute an order to an address that is not an allowed
///      target contract
error TargetContractNotAllowedException();

/// @dev Thrown on failing a full collateral check after an operation
error NotEnoughCollateralException();

/// @dev Thrown if an attempt to approve a collateral token to a target contract failed
error AllowanceFailedException();

/// @dev Thrown on attempting to perform an action for an address that owns no Credit Account
error CreditAccountNotExistsException();

/// @dev Thrown on configurator attempting to add more than 256 collateral tokens
error TooManyTokensException();

/// @dev Thrown if more than the maximal number of tokens were enabled on a Credit Account,
///      and there are not enough unused token to disable
error TooManyEnabledTokensException();

/// @dev Thrown when a custom HF parameter lower than 10000 is passed into a full collateral check
error CustomHealthFactorTooLowException();

/// @dev Thrown when attempting to vote in a non-approved contract
error VotingContractNotAllowedException();

error BorrowingMoreU2ForbiddenException();

error CreditManagerCantBorrowException();

error QuotasNotSupportedException();

error IncompatiblePoolQuotaKeeperException();

/// @dev Thrown when attempting to pass a zero amount to a funding-related operation
error AmountCantBeZeroException();

/// @dev Thrown when attempting to fund a bot that is forbidden or not directly allowed by the user
error InvalidBotException();

/// @dev Thrown when attempting to add a Credit Facade that has non-blacklistable underlying

/// @dev Thrown when attempting to claim funds without having anything claimable
error NothingToClaimException();

/// @dev Thrown when attempting to schedule withdrawal from a credit account that has no free withdrawal slots
error NoFreeWithdrawalSlotsException();

error NoPermissionException(uint256 permission);

error ActiveCreditAccountNotSetException();

/// @dev Thrown when attempting to set positive funding for a bot with 0 permissions
error PositiveFundingForInactiveBotException();

/// @dev Thrown when trying to deploy second master credit account for a credit manager
error MasterCreditAccountAlreadyDeployedException();

/// @dev Thrown when trying to rescue funds from a credit account that is currently in use
error CreditAccountIsInUseException();

/// @dev Thrown when trying to manually set total debt parameters in a CF that doesn't track them
error TotalDebtNotTrackedException();

error InsufficientBalanceException();

error OpenCloseAccountInOneBlockException();

error QuotaLessThanMinialException();
