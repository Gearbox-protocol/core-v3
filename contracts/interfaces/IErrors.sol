// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

/// @dev Common contract exceptions

/// @dev Thrown on attempting to set an important address to zero address
error ZeroAddressException();

/// @dev Thrown on attempting to call a non-implemented function
error NotImplementedException();

error RegisteredCreditManagerOnlyException();
error RegisteredPoolOnlyException();

error WethPoolsOnlyException();
error ReceiveIsNotAllowedException();

error IncompatibleCreditManagerException();

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

/// @dev Thrown on attempting to call an access restricted function as a non-Configurator
error CallerNotConfiguratorException();

/// @dev Thrown on attempting to call an access restricted function as a non-CreditManager
error CallerNotCreditManagerException();

/// @dev Thrown on attempting to call an access restricted function as a non-Configurator
error CallerNotControllerException();

/// @dev Thrown on attempting to pause a contract as a non-Pausable admin
error CallerNotPausableAdminException();

/// @dev Thrown on attempting to pause a contract as a non-Unpausable admin
error CallerNotUnPausableAdminException();

error TokenIsNotAddedToCreditManagerException(address token);
