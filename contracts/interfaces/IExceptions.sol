// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

//
// GENERAL
//

/// @dev Thrown on attempting to set an important address to zero address
error ZeroAddressException();

/// @dev Thrown when attempting to pass a zero amount to a funding-related operation
error AmountCantBeZeroException();

/// @dev Thrown on incorrect input parameter
error IncorrectParameterException();

/// @dev Thrown if parameter is out of range
error ValueOutOfRangeException();

/// @dev Thrown when an address sends ETH to a contract that is not allowed to send ETH directly
///      This is only relevant for contracts that have custom `receive()` access;
///      most contracts do not have a `receive()` and thus will do a generic revert
error ReceiveIsNotAllowedException();

/// @dev Thrown on attempting to set an EOA as an important contract in the system
error AddressIsNotContractException(address);

/// @dev Thrown on attempting to receive a token that is not a collateral token or was forbidden
error TokenNotAllowedException();

/// @dev Thrown on attempting to add a token that is already in a collateral list
error TokenAlreadyAddedException();

/// @dev Thrown when attempting to use quota-related logic for a token that is not quoted in PoolQuotaKeeper
error TokenIsNotQuotedException();

/// @dev Thrown on attempting to interact with an address that is not a valid target contract
error TargetContractNotAllowedException();

/// @dev Thrown if function is not implemented
error NotImplementedException();

//
// CONTRACTS REGISTER
//

/// @dev Thrown when an address that expected to be a registered CM, is not
error RegisteredCreditManagerOnlyException();

/// @dev Thrown when an address that expected to be a registered pool, is not
error RegisteredPoolOnlyException();

//
// ADDRESS PROVIDER
//

/// @dev Reverts if address isn't found in address provider
error AddressNotFoundException();

//
// POOL, PQK, GAUGES
//

/// @dev Thrown by pool-adjacent contracts when a Credit Manager being connected
///      has a wrong pool address
error IncompatibleCreditManagerException();

/// @dev Thrown when attempting to vote in a non-approved contract
error VotingContractNotAllowedException();

/// @dev Thrown when attempting to borrow more than the second point,
///      on a two point curve, if the corresponding option is enabled
error BorrowingMoreThanU2ForbiddenException();

/// @dev Thrown when a Credit Manager is attempting to borrow more
///      than its limit in the current block, or in general
error CreditManagerCantBorrowException();

/// @dev Thrown when attempting to perform a quota-specific action in a pool
///      that does not support quotas
error QuotasNotSupportedException();

/// @dev Thrown when attempting to connect a PQK to a pool thas does not
///      mathh the one in the PQK
error IncompatiblePoolQuotaKeeperException();

/// @dev Thrown when the received quota is outside of min/max bounds
error QuotaIsOutOfBoundsException();

//
// CREDIT MANAGER
//

/// @dev Thrown on failing a full collateral check after an operation
error NotEnoughCollateralException();

/// @dev Thrown if an attempt to approve a collateral token to a target contract failed
error AllowanceFailedException();

/// @dev Thrown on attempting to perform an action for an address that owns no Credit Account
error CreditAccountDoesNotExistException();

/// @dev Thrown on configurator attempting to add more than 255 collateral tokens
error TooManyTokensException();

/// @dev Thrown if more than the maximal number of tokens were enabled on a Credit Account,
///      and there are not enough unused token to disable
error TooManyEnabledTokensException();

/// @dev Thrown when a custom HF parameter lower than 10000 is passed into a full collateral check
error CustomHealthFactorTooLowException();

/// @dev Thrown when attempting to execute a protocol interaction without a
///      set active Credit Account
error ActiveCreditAccountNotSetException();

/// @dev Thrown when an account is opened and closed in the same block
error OpenCloseAccountInOneBlockException();

//
// CREDIT CONFIGURATOR
//

/// @dev Thrown on attempting to use a non-ERC20 contract or an EOA as a token
error IncorrectTokenContractException();

/// @dev Thrown on attempting to set a token price feed to an address that is not a
///      correct price feed
error IncorrectPriceFeedException();

/// @dev Thrown if the newly set LT if zero or greater than the underlying's LT
error IncorrectLiquidationThresholdException();

/// @dev Thrown if borrowing limits are incorrect: minLimit > maxLimit or maxLimit > blockLimit
error IncorrectLimitsException();

/// @dev Thrown if the new expiration date is less than the current expiration date or block.timestamp
error IncorrectExpirationDateException();

/// @dev Thrown if a contract (adapter or Credit Facade) set in a Credit Configurator returns a wrong Credit Manager
///      or retrieving the Credit Manager from it fails
error IncompatibleContractException();

/// @dev Thrown if attempting to forbid an adapter that is not allowed for the Credit Manager
error AdapterIsNotRegisteredException();

/// @dev Thrown when trying to manually set total debt parameters in a CF that doesn't track them
error TotalDebtNotTrackedException();

//
// CREDIT FACADE
//

/// @dev Thrown on attempting to interact with a price feed for a token not added
///      to PriceOracle
error PriceFeedDoesNotExistException();

/// @dev Thrown when attempting to perform an action
///      that cannot be done when whitelisted mode is on
///      for the CM
error ForbiddenInWhitelistedModeException();

/// @dev Thrown if the CreditFacadeV3 is not expirable, and an aciton is attempted that
///      requires expirability
error NotAllowedWhenNotExpirableException();

/// @dev Thrown if a selector that doesn't match any allowed function is passed to the Credit Facade
///      during a multicall
error UnknownMethodException();

/// @dev Thrown if a liquidator tries to liquidate an account with a health factor above 1
error CreditAccountNotLiquidatableException();

/// @dev Thrown if too much new debt was taken within a single block
error BorrowedBlockLimitException();

/// @dev Thrown if the new debt principal for a CA falls outside of borrowing limits
error BorrowAmountOutOfLimitsException();

/// @dev Thrown if one of the balances on a Credit Account is less than expected
///      at the end of a multicall, if revertIfReceivedLessThan was called
error BalanceLessThanMinimumDesiredException();

/// @dev Thrown if a user attempts to open an account on a Credit Facade that has expired
error NotAllowedAfterExpirationException();

/// @dev Thrown if expected balances are attempted to be set through revertIfReceivedLessThan twice
error ExpectedBalancesAlreadySetException();

/// @dev Thrown if a Credit Account has enabled forbidden tokens and the owner attempts to perform an action
///      that is not allowed with any forbidden tokens enabled
error ForbiddenTokensException();

/// @dev Thrown if botMulticall is called by an address that is not approved by the borrower, or is forbidden
error NotApprovedBotException();

/// @dev Thrown when attempting to perform a multicall action outside permissions
error NoPermissionException(uint256 permission);

/// @dev Thrown when user tries to approve more bots than allowed
error TooManyApprovedBotsException();

///
/// ACCESS
///

/// @dev Thrown on attempting to perform an action for an address that owns no Credit Account
error CallerNotCreditAccountOwnerException();

/// @dev Thrown on attempting to call an access restricted function as a non-Configurator
error CallerNotConfiguratorException();

/// @dev Thrown on attempting to call an access-restructed function not as account factory
error CallerNotAccountFactoryException();

/// @dev Thrown on attempting to call an access restricted function as a non-CreditManager
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

/// @dev Thrown if a migration function is called by non-migrator in GearStaking
error CallerNotMigratorException();

///
/// BOT LIST
///

/// @dev Thrown when attempting to set non-zero permissions for a forbidden bot
error InvalidBotException();

///
/// WITHDRAWAL MANAGER
///

/// @dev Thrown when attempting to claim funds without having anything claimable
error NothingToClaimException();

/// @dev Thrown when attempting to schedule withdrawal from a credit account that has no free withdrawal slots
error NoFreeWithdrawalSlotsException();

///
/// ACCOUNT FACTORY
///

/// @dev Thrown when trying to deploy second master credit account for a credit manager
error MasterCreditAccountAlreadyDeployedException();

/// @dev Thrown when trying to rescue funds from a credit account that is currently in use
error CreditAccountIsInUseException();

///
/// DEGEN NFT
///

/// @dev Thrown by DegenNFT when attempting to burn on opening an account with 0 balance
error InsufficientBalanceException();
