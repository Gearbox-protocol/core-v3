// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import "../interfaces/IAddressProviderV3.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

// LIBRARIES & CONSTANTS
import {
    DEFAULT_FEE_INTEREST,
    DEFAULT_FEE_LIQUIDATION,
    DEFAULT_LIQUIDATION_PREMIUM,
    DEFAULT_FEE_LIQUIDATION_EXPIRED,
    DEFAULT_LIQUIDATION_PREMIUM_EXPIRED,
    DEFAULT_LIMIT_PER_BLOCK_MULTIPLIER,
    WAD
} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";
import {UNDERLYING_TOKEN_MASK} from "../libraries/BitMask.sol";
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/PercentageMath.sol";

// CONTRACTS
import {ACLNonReentrantTrait} from "../traits/ACLNonReentrantTrait.sol";
import {CreditFacadeV3} from "./CreditFacadeV3.sol";
import {CreditManagerV3} from "./CreditManagerV3.sol";

// INTERFACES
import {
    ICreditConfigurator,
    CollateralToken,
    CreditManagerOpts,
    AllowanceAction
} from "../interfaces/ICreditConfiguratorV3.sol";
import {IPriceOracleV2} from "@gearbox-protocol/core-v2/contracts/interfaces/IPriceOracle.sol";
import {IPoolService} from "@gearbox-protocol/core-v2/contracts/interfaces/IPoolService.sol";
import {IPoolQuotaKeeper} from "../interfaces/IPoolQuotaKeeper.sol";

// EXCEPTIONS
import "../interfaces/IExceptions.sol";
import {ICreditManagerV3} from "../interfaces/ICreditManagerV3.sol";

/// @title CreditConfigurator
/// @notice This contract is used to configure CreditManagers and is the only one with the priviledge
/// to call access-restricted functions
/// @dev All functions can only by called by the Configurator as per ACL.
/// CreditManagerV3 blindly executes all requests (in nearly all cases) from CreditConfigurator, so most sanity checks
/// are performed here.
contract CreditConfigurator is ICreditConfigurator, ACLNonReentrantTrait {
    using EnumerableSet for EnumerableSet.AddressSet;
    using Address for address;

    /// @notice Address provider (needed for upgrading the Price Oracle)
    address public immutable override addressProvider;

    /// @notice Address of the Credit Manager
    CreditManagerV3 public override creditManager;

    /// @notice Address of the Credit Manager's underlying asset
    address public override underlying;

    /// @notice Set of allowed contracts
    EnumerableSet.AddressSet private allowedContractsSet;

    /// @notice Set of emergency liquidators
    EnumerableSet.AddressSet private emergencyLiquidatorsSet;

    /// @notice Set of forbidden tokens
    EnumerableSet.AddressSet private forbiddenTokensSet;

    /// @notice Contract version
    uint256 public constant version = 3_00;

    /// @notice Constructor has a special role in Credit Manager deployment
    /// For newly deployed CMs, this is where the initial configuration is performed.
    /// The correct deployment flow is as follows:
    ///
    /// 1. Configures CreditManagerV3 fee parameters and sets underlying LT
    /// 2. Adds collateral tokens and sets their LTs
    /// 3. Connects creditFacade and priceOracle to the Credit Manager
    /// 4. Sets itself as creditConfigurator in Credit Manager
    ///
    /// For existing Credit Manager the CC will only migrate some parameters from the previous Credit Configurator,
    /// and will otherwise keep the existing CM configuration intact.
    /// @param _creditManager CreditManagerV3 contract instance
    /// @param _creditFacade CreditFacadeV3 contract instance
    /// @param opts Configuration parameters for CreditManagerV3
    constructor(CreditManagerV3 _creditManager, CreditFacadeV3 _creditFacade, CreditManagerOpts memory opts)
        ACLNonReentrantTrait(address(IPoolService(_creditManager.poolService()).addressProvider()))
    {
        creditManager = _creditManager; // I:[CC-1]
        underlying = creditManager.underlying(); // I:[CC-1]

        addressProvider = _creditManager.addressProvider(); // I:[CC-1]

        address currentConfigurator = creditManager.creditConfigurator(); // I:[CC-41]

        if (currentConfigurator != address(this)) {
            /// DEPLOYED FOR EXISTING CREDIT MANAGER
            /// In the case where the CC is deployed for the existing Credit Manager,
            /// we only need to copy several array parameters from the last CC,
            /// but the existing configs must be kept intact otherwise
            /// 1. Allowed contracts set stores all the connected third-party contracts - currently only used
            ///    to retrieve externally
            /// 2. Emergency liquidator set stores all emergency liquidators - used for parameter migration when changing the Credit Facade
            /// 3. Forbidden token set stores all forbidden tokens - used for parameter migration when changing the Credit Facade
            {
                address[] memory allowedContractsPrev = CreditConfigurator(currentConfigurator).allowedContracts(); // I:[CC-41]

                uint256 allowedContractsLen = allowedContractsPrev.length;
                for (uint256 i = 0; i < allowedContractsLen;) {
                    allowedContractsSet.add(allowedContractsPrev[i]); // I:[CC-41]

                    unchecked {
                        ++i;
                    }
                }
            }
            {
                address[] memory emergencyLiquidatorsPrev =
                    CreditConfigurator(currentConfigurator).emergencyLiquidators();

                uint256 emergencyLiquidatorsLen = emergencyLiquidatorsPrev.length;
                for (uint256 i = 0; i < emergencyLiquidatorsLen;) {
                    emergencyLiquidatorsSet.add(emergencyLiquidatorsPrev[i]);

                    unchecked {
                        ++i;
                    }
                }
            }
            {
                address[] memory forbiddenTokensPrev = CreditConfigurator(currentConfigurator).forbiddenTokens();

                uint256 forbiddenTokensLen = forbiddenTokensPrev.length;
                for (uint256 i = 0; i < forbiddenTokensLen;) {
                    forbiddenTokensSet.add(forbiddenTokensPrev[i]);

                    unchecked {
                        ++i;
                    }
                }
            }
        } else {
            /// DEPLOYED FOR NEW CREDIT MANAGER

            /// Sets liquidation discounts and fees for the Credit Manager
            _setFees(
                DEFAULT_FEE_INTEREST,
                DEFAULT_FEE_LIQUIDATION,
                PERCENTAGE_FACTOR - DEFAULT_LIQUIDATION_PREMIUM,
                DEFAULT_FEE_LIQUIDATION_EXPIRED,
                PERCENTAGE_FACTOR - DEFAULT_LIQUIDATION_PREMIUM_EXPIRED
            ); // I:[CC-1]

            /// Adds collateral tokens and sets their liquidation thresholds
            /// The underlying must not be in this list, since its LT is set separately in _setFees
            uint256 len = opts.collateralTokens.length;
            for (uint256 i = 0; i < len;) {
                address token = opts.collateralTokens[i].token;

                _addCollateralToken(token); // I:[CC-1]

                _setLiquidationThreshold(token, opts.collateralTokens[i].liquidationThreshold); // I:[CC-1]

                unchecked {
                    ++i;
                }
            }

            /// Connects creditFacade and priceOracle
            creditManager.setCreditFacade(address(_creditFacade)); // I:[CC-1]

            emit SetCreditFacade(address(_creditFacade)); // I:[CC-1A]
            emit SetPriceOracle(address(creditManager.priceOracle())); // I:[CC-1A]

            /// Sets the max debt per block multiplier
            /// This parameter determines the maximal new debt per block as a factor of
            /// maximal Credit Account debt - essentially a cap on the number of new Credit Accounts per block
            _setMaxDebtPerBlockMultiplier(uint8(DEFAULT_LIMIT_PER_BLOCK_MULTIPLIER)); // I:[CC-1]

            /// Sets the borrowing limits per Credit Account
            _setLimits(opts.minBorrowedAmount, opts.maxBorrowedAmount); // I:[CC-1]
        }
    }

    //
    // CONFIGURATION: TOKEN MANAGEMENT
    //

    /// @notice Adds token to the list of allowed collateral tokens, and sets the LT
    /// @param token Address of token to be added
    /// @param liquidationThreshold Liquidation threshold for account health calculations
    function addCollateralToken(address token, uint16 liquidationThreshold)
        external
        override
        configuratorOnly // I:[CC-2]
    {
        _addCollateralToken(token); // I:[CC-3,4]
        _setLiquidationThreshold(token, liquidationThreshold); // I:[CC-4]
    }

    /// @notice Makes all sanity checks and adds the token to the collateral token list
    /// @param token Address of token to be added
    function _addCollateralToken(address token) internal nonZeroAddress(token) {
        /// Checks that the token is a contract
        if (!token.isContract()) revert AddressIsNotContractException(token); // I:[CC-3]

        // Checks that the contract has balanceOf method
        try IERC20(token).balanceOf(address(this)) returns (uint256) {}
        catch {
            revert IncorrectTokenContractException(); // I:[CC-3]
        }

        // Checks that the token has a correct priceFeed in priceOracle
        try IPriceOracleV2(creditManager.priceOracle()).convertToUSD(WAD, token) returns (uint256) {}
        catch {
            revert IncorrectPriceFeedException(); // I:[CC-3]
        }

        /// creditManager has an additional check that the token is not added yet
        creditManager.addToken(token); // I:[CC-4]

        emit AllowToken(token); // I:[CC-4]
    }

    /// @notice Sets a liquidation threshold for any token except the underlying
    /// @param token Token address
    /// @param liquidationThreshold in PERCENTAGE_FORMAT (100% = 10000)
    function setLiquidationThreshold(address token, uint16 liquidationThreshold)
        external
        controllerOnly // I:[CC-2B]
    {
        _setLiquidationThreshold(token, liquidationThreshold); // I:[CC-5]
    }

    /// @notice IMPLEMENTAION: setLiquidationThreshold
    function _setLiquidationThreshold(address token, uint16 liquidationThreshold) internal {
        // Checks that the token is not underlying, since its LT is determined by Credit Manager params
        if (token == underlying) revert SetLTForUnderlyingException(); // I:[CC-5]

        (, uint16 ltUnderlying) = creditManager.collateralTokenByMask(UNDERLYING_TOKEN_MASK);
        // Sanity check for the liquidation threshold. The LT should be less than underlying
        if (liquidationThreshold > ltUnderlying) {
            revert IncorrectLiquidationThresholdException();
        } // I:[CC-5]

        uint16 currentLT = creditManager.liquidationThresholds(token);

        if (currentLT != liquidationThreshold) {
            /// When the LT of a token is set directly, we set the parameters
            /// as if it was a ramp from `liquidationThreshold` to `liquidationThreshold`
            /// starting in far future. This ensures that the LT function in Credit Manager
            /// will always return `liquidationThreshold` until the parameters are changed
            creditManager.setCollateralTokenData(token, liquidationThreshold, liquidationThreshold, type(uint40).max, 0); // I:[CC-6]
            emit SetTokenLiquidationThreshold(token, liquidationThreshold); // I:[CC-6]
        }
    }

    /// @notice Schedules an LT ramping for any token except underlying
    /// @param token Token to ramp LT for
    /// @param liquidationThresholdFinal Liquidation threshold after ramping
    /// @param rampDuration Duration of ramping
    function rampLiquidationThreshold(
        address token,
        uint16 liquidationThresholdFinal,
        uint40 rampStart,
        uint24 rampDuration
    ) external controllerOnly {
        // Checks that the token is not underlying, since its LT is determined by Credit Manager params
        if (token == underlying) revert SetLTForUnderlyingException();

        (, uint16 ltUnderlying) = creditManager.collateralTokenByMask(UNDERLYING_TOKEN_MASK);
        // Sanity check for the liquidation threshold. The LT should be less than underlying
        if (liquidationThresholdFinal > ltUnderlying) {
            revert IncorrectLiquidationThresholdException();
        }

        // In case that (for some reason) the function is executed later than
        // the start of the ramp, we start the ramp from the current moment
        // to prevent discontinueous jumps in token's LT
        rampStart = block.timestamp > rampStart ? uint40(block.timestamp) : rampStart;

        uint16 currentLT = creditManager.liquidationThresholds(token);

        if (currentLT != liquidationThresholdFinal) {
            // CollateralTokenData in CreditManager stores 4 values:
            // 1. ltInitial
            // 2. ltFinal
            // 3. rampStart
            // 4. rampDuration
            // The actual LT changes linearly between ltInitial and ltFinal over rampDuration;
            // E.g., it is ltInitial in rampStart and ltFinal in rampStart + rampDuration
            creditManager.setCollateralTokenData(token, currentLT, liquidationThresholdFinal, rampStart, rampDuration);
            emit ScheduleTokenLiquidationThresholdRamp(
                token, currentLT, liquidationThresholdFinal, rampStart, uint40(block.timestamp) + rampDuration
            );
        }
    }

    /// @notice Allow a known collateral token if it was forbidden before.
    /// @param token Address of collateral token
    function allowToken(address token)
        external
        configuratorOnly // I:[CC-2]
    {
        // Gets token masks. Reverts if the token was not added as collateral or is the underlying
        uint256 tokenMask = _getAndCheckTokenMaskForSettingLT(token); // I:[CC-7]

        // Gets current forbidden mask
        uint256 forbiddenTokenMask = creditFacade().forbiddenTokenMask(); // I:[CC-8,9]

        // If the token was forbidden before, flips the corresponding bit in the mask,
        // otherwise no actions done.
        // Skipping case: I:[CC-8]
        if (forbiddenTokenMask & tokenMask != 0) {
            creditFacade().setTokenAllowance(token, AllowanceAction.ALLOW); // TODO: CHECK
            forbiddenTokensSet.remove(token);
            emit AllowToken(token); // I:[CC-9]
        }
    }

    /// @notice Forbids a collateral token.
    /// Forbidden tokens are counted as collateral during health checks, however, they cannot be enabled
    /// or received as a result of adapter operation anymore. This means that a token can never be
    /// acquired through adapter operations after being forbidden.
    /// @param token Address of collateral token to forbid
    function forbidToken(address token)
        external
        pausableAdminsOnly // I:[CC-2B]
    {
        _forbidToken(token);
    }

    /// @notice IMPLEMENTATION: forbidToken
    function _forbidToken(address token) internal {
        // Gets token masks. Reverts if the token was not added as collateral or is the underlying
        uint256 tokenMask = _getAndCheckTokenMaskForSettingLT(token); // I:[CC-7]

        // Gets current forbidden mask
        uint256 forbiddenTokenMask = creditFacade().forbiddenTokenMask();

        // If the token was not forbidden before, flips the corresponding bit in the mask,
        // otherwise no actions done.
        // Skipping case: I:[CC-10]
        if (forbiddenTokenMask & tokenMask == 0) {
            creditFacade().setTokenAllowance(token, AllowanceAction.FORBID); // TODO: CHECK
            forbiddenTokensSet.add(token);
            emit ForbidToken(token); // I:[CC-11]
        }
    }

    /// @notice Marks the token as limited, which enables quota logic and additional interest for it
    /// @param token Token to make limited
    /// @dev This action is irreversible!
    function makeTokenQuoted(address token) external configuratorOnly {
        // Verifies whether the quota keeper has a token registered as quotable
        address quotaKeeper = creditManager.poolQuotaKeeper();

        if (!IPoolQuotaKeeper(quotaKeeper).isQuotedToken(token)) {
            revert TokenIsNotQuotedException();
        }

        // Gets token masks. Reverts if the token was not added as collateral or is the underlying
        uint256 tokenMask = _getAndCheckTokenMaskForSettingLT(token);

        // Gets current limited mask
        uint256 quotedTokensMask = creditManager.quotedTokensMask();

        // If the token was not limited before, flips the corresponding bit in the mask,
        // otherwise no actions done.
        if (quotedTokensMask & tokenMask == 0) {
            quotedTokensMask |= tokenMask;
            creditManager.setQuotedMask(quotedTokensMask);
            emit QuoteToken(token);
        }
    }

    /// @notice Sanity check to verify that the token is a collateral token and
    /// is not the underlying
    function _getAndCheckTokenMaskForSettingLT(address token) internal view returns (uint256 tokenMask) {
        // Gets tokenMask for the token
        tokenMask = creditManager.getTokenMaskOrRevert(token); // I:[CC-7]

        // tokenMask can't be 0, since this means that the token is not a collateral token
        // tokenMask can't be 1, since this mask is reserved for underlying

        if (tokenMask == 1) {
            revert TokenNotAllowedException();
        } // I:[CC-7]
    }

    //
    // CONFIGURATION: CONTRACTS & ADAPTERS MANAGEMENT
    //

    /// @notice Adds pair [contract <-> adapter] to the list of allowed contracts
    /// or updates adapter address if a contract already has a connected adapter
    /// @param targetContract Address of allowed contract
    /// @param adapter Adapter address
    function allowContract(address targetContract, address adapter)
        external
        override
        configuratorOnly // I:[CC-2]
    {
        _allowContract(targetContract, adapter);
    }

    /// @notice IMPLEMENTATION: allowContract
    function _allowContract(address targetContract, address adapter) internal nonZeroAddress(targetContract) {
        // Checks that targetContract or adapter != address(0)

        if (!targetContract.isContract()) {
            revert AddressIsNotContractException(targetContract);
        } // I:[CC-12A]

        // Checks that the adapter is an actual contract and has the correct Credit Manager and is an actual contract
        _revertIfContractIncompatible(adapter); // I:[CC-12]

        // Additional check that adapter or targetContract is not
        // creditManager or creditFacade.
        // creditManager and creditFacade are security-critical, and calling them through adapters
        // can have undforseen consequences.
        if (
            targetContract == address(creditManager) || targetContract == address(creditFacade())
                || adapter == address(creditManager) || adapter == address(creditFacade())
        ) revert TargetContractNotAllowedException(); // I:[CC-13]

        // Checks that adapter is not used for another target
        if (creditManager.adapterToContract(adapter) != address(0)) {
            revert AdapterUsedTwiceException();
        } // I:[CC-14]

        // If there is an existing adapter for the target contract, it has to be removed
        address currentAdapter = creditManager.contractToAdapter(targetContract);
        if (currentAdapter != address(0)) {
            creditManager.setContractAllowance({adapter: currentAdapter, targetContract: address(0)}); // I:[CC-15A]
        }

        // Sets a link between adapter and targetContract in creditFacade and creditManager
        creditManager.setContractAllowance({adapter: adapter, targetContract: targetContract}); // I:[CC-15]

        // adds contract to the list of allowed contracts
        allowedContractsSet.add(targetContract); // I:[CC-15]

        emit AllowContract(targetContract, adapter); // I:[CC-15]
    }

    /// @notice Forbids contract as a target for calls from Credit Accounts
    /// Internally, mappings that determine the adapter <> targetContract link
    /// Are reset to zero addresses
    /// @param targetContract Address of a contract to be forbidden
    function forbidContract(address targetContract)
        external
        override
        controllerOnly // I:[CC-2B]
        nonZeroAddress(targetContract) // I:[CC-12]
    {
        // Checks that targetContract has a connected adapter
        address adapter = creditManager.contractToAdapter(targetContract);
        if (adapter == address(0)) {
            revert ContractIsNotAnAllowedAdapterException();
        } // I:[CC-16]

        // Sets both contractToAdapter[targetContract] and adapterToContract[adapter]
        // To address(0), which would make Credit Manager revert on attempts to
        // call the respective targetContract using the adapter
        creditManager.setContractAllowance({adapter: adapter, targetContract: address(0)}); // I:[CC-17]
        creditManager.setContractAllowance({adapter: address(0), targetContract: targetContract}); // I:[CC-17]

        // removes contract from the list of allowed contracts
        allowedContractsSet.remove(targetContract); // I:[CC-17]

        emit ForbidContract(targetContract); // I:[CC-17]
    }

    //
    // CREDIT MANAGER MGMT
    //

    /// @notice Sets borrowed amount limits in Credit Facade
    /// @param _minBorrowedAmount Minimum borrowed amount
    /// @param _maxBorrowedAmount Maximum borrowed amount
    function setLimits(uint128 _minBorrowedAmount, uint128 _maxBorrowedAmount)
        external
        controllerOnly // I:[CC-2B]
    {
        _setLimits(_minBorrowedAmount, _maxBorrowedAmount);
    }

    /// @notice IMPLEMENTATION: setLimits
    function _setLimits(uint128 _minBorrowedAmount, uint128 _maxBorrowedAmount) internal {
        // Performs sanity checks on limits:
        // maxBorrowedAmount must not be less than minBorrowedAmount
        uint8 maxDebtPerBlockMultiplier = creditFacade().maxDebtPerBlockMultiplier();
        if (_minBorrowedAmount > _maxBorrowedAmount) {
            revert IncorrectLimitsException();
        } // I:[CC-18]

        // Sets limits in Credit Facade
        creditFacade().setDebtLimits(_minBorrowedAmount, _maxBorrowedAmount, maxDebtPerBlockMultiplier); // I:[CC-19]
        emit SetBorrowingLimits(_minBorrowedAmount, _maxBorrowedAmount); // I:[CC-1A,19]
    }

    /// @notice Sets fees for creditManager
    /// @param _feeInterest Percent which protocol charges additionally for interest rate
    /// @param _feeLiquidation The fee that is paid to the pool from liquidation
    /// @param _liquidationPremium Discount for totalValue which is given to liquidator
    /// @param _feeLiquidationExpired The fee that is paid to the pool from liquidation when liquidating an expired account
    /// @param _liquidationPremiumExpired Discount for totalValue which is given to liquidator when liquidating an expired account
    function setFees(
        uint16 _feeInterest,
        uint16 _feeLiquidation,
        uint16 _liquidationPremium,
        uint16 _feeLiquidationExpired,
        uint16 _liquidationPremiumExpired
    )
        external
        configuratorOnly // I:[CC-2]
    {
        // Checks that feeInterest and (liquidationPremium + feeLiquidation) are in range [0..10000]
        if (
            _feeInterest >= PERCENTAGE_FACTOR || (_liquidationPremium + _feeLiquidation) >= PERCENTAGE_FACTOR
                || (_liquidationPremiumExpired + _feeLiquidationExpired) >= PERCENTAGE_FACTOR
        ) revert IncorrectParameterException(); // FT:[CC-23]

        _setFees(
            _feeInterest,
            _feeLiquidation,
            PERCENTAGE_FACTOR - _liquidationPremium,
            _feeLiquidationExpired,
            PERCENTAGE_FACTOR - _liquidationPremiumExpired
        ); // FT:[CC-24,25,26]
    }

    /// @notice IMPLEMENTATION: setFees
    ///      Does sanity checks on fee params and sets them in CreditManagerV3
    function _setFees(
        uint16 _feeInterest,
        uint16 _feeLiquidation,
        uint16 _liquidationDiscount,
        uint16 _feeLiquidationExpired,
        uint16 _liquidationDiscountExpired
    ) internal {
        // Computes the underlying LT and updates it if required
        uint16 newLTUnderlying = uint16(_liquidationDiscount - _feeLiquidation); // FT:[CC-25]
        (, uint16 ltUnderlying) = creditManager.collateralTokenByMask(UNDERLYING_TOKEN_MASK);

        if (newLTUnderlying != ltUnderlying) {
            _updateLiquidationThreshold(newLTUnderlying); // I:[CC-25]
            emit SetTokenLiquidationThreshold(underlying, newLTUnderlying); // I:[CC-1A,25]
        }

        (
            uint16 _feeInterestCurrent,
            uint16 _feeLiquidationCurrent,
            uint16 _liquidationDiscountCurrent,
            uint16 _feeLiquidationExpiredCurrent,
            uint16 _liquidationDiscountExpiredCurrent
        ) = creditManager.fees();

        // Checks that at least one parameter was changed
        if (
            (_feeInterest != _feeInterestCurrent) || (_feeLiquidation != _feeLiquidationCurrent)
                || (_liquidationDiscount != _liquidationDiscountCurrent)
                || (_feeLiquidationExpired != _feeLiquidationExpiredCurrent)
                || (_liquidationDiscountExpired != _liquidationDiscountExpiredCurrent)
        ) {
            // updates params in creditManager
            creditManager.setFees({
                _feeInterest: _feeInterest,
                _feeLiquidation: _feeLiquidation,
                _liquidationDiscount: _liquidationDiscount,
                _feeLiquidationExpired: _feeLiquidationExpired,
                _liquidationDiscountExpired: _liquidationDiscountExpired
            });

            emit FeesUpdated(
                _feeInterest,
                _feeLiquidation,
                PERCENTAGE_FACTOR - _liquidationDiscount,
                _feeLiquidationExpired,
                PERCENTAGE_FACTOR - _liquidationDiscountExpired
            ); // FT:[CC-1A,26]
        }
    }

    /// @notice Updates Liquidation threshold for the underlying asset
    /// @param ltUnderlying New LT for the underlying
    function _updateLiquidationThreshold(uint16 ltUnderlying) internal {
        creditManager.setCollateralTokenData(underlying, ltUnderlying, ltUnderlying, type(uint40).max, 0); // I:[CC-25]

        // An LT of an ordinary collateral token cannot be larger than the LT of underlying
        // As such, all LTs need to be checked and reduced if needed
        // NB: This action will interrupt all ongoing LT ramps
        uint256 len = creditManager.collateralTokensCount();
        unchecked {
            for (uint256 i = 1; i < len; ++i) {
                (address token, uint16 lt) = creditManager.collateralTokenByMask(1 << i);
                if (lt > ltUnderlying) {
                    _setLiquidationThreshold(token, ltUnderlying); // I:[CC-25]
                }
            }
        }
    }

    //
    // CONTRACT UPGRADES
    //

    /// @notice Upgrades the price oracle in the Credit Manager, taking the address
    /// from the address provider
    function setPriceOracle(uint256 _version)
        external
        configuratorOnly // I:[CC-2]
    {
        address priceOracle = IAddressProviderV3(addressProvider).getAddressOrRevert(AP_PRICE_ORACLE, _version);
        address currentPriceOracle = address(creditManager.priceOracle());

        // Checks that the price oracle is actually new to avoid emitting redundant events
        if (priceOracle != currentPriceOracle) {
            creditManager.setPriceOracle(priceOracle); // I:[CC-28]
            emit SetPriceOracle(priceOracle); // I:[CC-28]
        }
    }

    /// @notice Upgrades the Credit Facade corresponding to the Credit Manager
    /// @param _creditFacade address of the new CreditFacadeV3
    /// @param migrateParams Whether the previous CreditFacadeV3's parameter need to be copied
    function setCreditFacade(address _creditFacade, bool migrateParams)
        external
        configuratorOnly // I:[CC-2]
    {
        // Checks that the Credit Facade is actually changed, to avoid
        // any redundant actions and events
        if (_creditFacade == address(creditFacade())) {
            return;
        }

        // Sanity checks that the address is a contract and has correct Credit Manager
        _revertIfContractIncompatible(_creditFacade); // I:[CC-29]

        // Retrieves all parameters in case they need
        // to be migrated

        uint40 expirationDate = creditFacade().expirationDate();

        uint8 _maxDebtPerBlockMultiplier = creditFacade().maxDebtPerBlockMultiplier();

        (uint128 minBorrowedAmount, uint128 maxBorrowedAmount) = creditFacade().debtLimits();

        bool expirable = creditFacade().expirable();

        uint256 botListVersion;
        {
            address botList = creditFacade().botList();
            botListVersion = botList == address(0) ? 0 : IVersion(botList).version();
        }

        (, uint128 maxCumulativeLoss) = creditFacade().lossParams();

        // Sets Credit Facade to the new address
        creditManager.setCreditFacade(_creditFacade); // I:[CC-30]

        if (migrateParams) {
            // Copies all limits and restrictions on borrowing
            _setMaxDebtPerBlockMultiplier(_maxDebtPerBlockMultiplier); // I:[CC-30]
            _setLimits(minBorrowedAmount, maxBorrowedAmount); // I:[CC-30]
            _setMaxCumulativeLoss(maxCumulativeLoss);

            // Migrates array-based parameters
            _migrateEmergencyLiquidators();
            _migrateForbiddenTokens();

            // Copies the expiration date if the contract is expirable
            if (expirable) _setExpirationDate(expirationDate); // I:[CC-30]

            if (botListVersion != 0) _setBotList(botListVersion);
        }

        emit SetCreditFacade(_creditFacade); // I:[CC-30]
    }

    /// @notice Internal function to migrate emergency liquidators when
    ///      updating the Credit Facade
    function _migrateEmergencyLiquidators() internal {
        uint256 len = emergencyLiquidatorsSet.length();
        for (uint256 i; i < len;) {
            _addEmergencyLiquidator(emergencyLiquidatorsSet.at(i));
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Internal function to migrate forbidden tokens when
    ///      updating the Credit Facade
    function _migrateForbiddenTokens() internal {
        uint256 len = forbiddenTokensSet.length();
        for (uint256 i; i < len;) {
            _forbidToken(forbiddenTokensSet.at(i));
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Upgrades the Credit Configurator for a connected Credit Manager
    /// @param _creditConfigurator New Credit Configurator's address
    /// @dev After this function executes, this Credit Configurator no longer
    ///         has admin access to the Credit Manager
    function upgradeCreditConfigurator(address _creditConfigurator)
        external
        configuratorOnly // I:[CC-2]
    {
        if (_creditConfigurator == address(this)) {
            return;
        }

        _revertIfContractIncompatible(_creditConfigurator); // I:[CC-29]

        creditManager.setCreditConfigurator(_creditConfigurator); // I:[CC-31]
        emit CreditConfiguratorUpgraded(_creditConfigurator); // I:[CC-31]
    }

    /// @notice Performs sanity checks that the address is a contract compatible
    /// with the current Credit Manager
    function _revertIfContractIncompatible(address _contract)
        internal
        view
        nonZeroAddress(_contract) // I:[CC-12,29]
    {
        // Checks that the address is a contract
        if (!_contract.isContract()) {
            revert AddressIsNotContractException(_contract);
        } // I:[CC-12A,29]

        // Checks that the contract has a creditManager() function, which returns a correct value
        try CreditFacadeV3(_contract).creditManager() returns (address cm) {
            if (cm != address(creditManager)) revert IncompatibleContractException(); // I:[CC-12B,29]
        } catch {
            revert IncompatibleContractException(); // I:[CC-12B,29]
        }
    }

    /// @notice Disables borrowing in Credit Facade (and, consequently, the Credit Manager)
    function forbidBorrowing() external pausableAdminsOnly {
        /// This is done by setting the max debt per block multiplier to 0,
        /// which prevents all new borrowing
        _setMaxDebtPerBlockMultiplier(0);
    }

    /// @notice Sets the max cumulative loss, which is a threshold of total loss that triggers a system pause
    function setMaxCumulativeLoss(uint128 _maxCumulativeLoss)
        external
        configuratorOnly // I:[CC-02]
    {
        _setMaxCumulativeLoss(_maxCumulativeLoss);
    }

    /// @notice IMPLEMENTATION: setMaxCumulativeLoss
    function _setMaxCumulativeLoss(uint128 _maxCumulativeLoss) internal {
        (, uint128 maxCumulativeLossCurrent) = creditFacade().lossParams();

        if (_maxCumulativeLoss != maxCumulativeLossCurrent) {
            creditFacade().setCumulativeLossParams(_maxCumulativeLoss, false);
            emit SetMaxCumulativeLoss(_maxCumulativeLoss);
        }
    }

    /// @notice Resets the current cumulative loss
    function resetCumulativeLoss()
        external
        configuratorOnly // I:[CC-02]
    {
        (, uint128 maxCumulativeLossCurrent) = creditFacade().lossParams();
        creditFacade().setCumulativeLossParams(maxCumulativeLossCurrent, true);
        emit ResetCumulativeLoss();
    }

    /// @notice Sets the maximal borrowed amount per block
    /// @param newMaxDebtLimitPerBlockMultiplier The new max borrowed amount per block
    function setMaxDebtPerBlockMultiplier(uint8 newMaxDebtLimitPerBlockMultiplier)
        external
        controllerOnly // I:[CC-2B]
    {
        _setMaxDebtPerBlockMultiplier(newMaxDebtLimitPerBlockMultiplier); // I:[CC-33]
    }

    /// @notice IMPLEMENTATION: _setMaxDebtPerBlockMultiplier
    function _setMaxDebtPerBlockMultiplier(uint8 newMaxDebtLimitPerBlockMultiplier) internal {
        uint8 _maxDebtPerBlockMultiplier = creditFacade().maxDebtPerBlockMultiplier();
        (uint128 minBorrowedAmount, uint128 maxBorrowedAmount) = creditFacade().debtLimits();

        // Checks that the limit was actually changed to avoid redundant events
        if (newMaxDebtLimitPerBlockMultiplier != _maxDebtPerBlockMultiplier) {
            creditFacade().setDebtLimits(minBorrowedAmount, maxBorrowedAmount, newMaxDebtLimitPerBlockMultiplier); // I:[CC-33]
            emit SetMaxDebtPerBlockMultiplier(newMaxDebtLimitPerBlockMultiplier); // I:[CC-1A,33]
        }
    }

    /// @notice Sets expiration date in a CreditFacadeV3 connected
    /// To a CreditManagerV3 with an expirable pool
    /// @param newExpirationDate The timestamp of the next expiration
    /// @dev See more at https://dev.gearbox.fi/docs/documentation/credit/liquidation#liquidating-accounts-by-expiration
    function setExpirationDate(uint40 newExpirationDate)
        external
        configuratorOnly // I:[CC-38]
    {
        _setExpirationDate(newExpirationDate); // I:[CC-34]
    }

    /// @notice IMPLEMENTATION: setExpirationDate
    function _setExpirationDate(uint40 newExpirationDate) internal {
        uint40 expirationDate = creditFacade().expirationDate();

        // Sanity checks on the new expiration date
        // The new expiration date must be later than the previous one
        // The new expiration date cannot be earlier than now
        if (expirationDate >= newExpirationDate || block.timestamp > newExpirationDate) {
            revert IncorrectExpirationDateException();
        } // I:[CC-34]

        creditFacade().setExpirationDate(newExpirationDate); // I:[CC-34]
        emit SetExpirationDate(newExpirationDate); // I:[CC-34]
    }

    /// @notice Sets the maximal amount of enabled tokens per Credit Account
    /// @param maxEnabledTokens The new maximal number of enabled tokens
    /// @dev A large number of enabled collateral tokens on a Credit Account
    /// can make liquidations and health checks prohibitively expensive in terms of gas,
    /// hence the number is limited
    function setMaxEnabledTokens(uint8 maxEnabledTokens)
        external
        controllerOnly // I:[CC-2B]
    {
        uint256 maxEnabledTokensCurrent = creditManager.maxEnabledTokens();

        // Checks that value is actually changed, to avoid redundant checks
        if (maxEnabledTokens != maxEnabledTokensCurrent) {
            creditManager.setMaxEnabledTokens(maxEnabledTokens); // I:[CC-37]
            emit SetMaxEnabledTokens(maxEnabledTokens); // I:[CC-37]
        }
    }

    /// @notice Sets the bot list contract
    /// @param version The version of the new bot list contract
    ///                The contract address is retrieved from addressProvider
    /// @notice The bot list determines the permissions for actions
    ///         that bots can perform on Credit Accounts
    function setBotList(uint256 version) external configuratorOnly {
        _setBotList(version);
    }

    function _setBotList(uint256 version) internal {
        address botList = IAddressProviderV3(addressProvider).getAddressOrRevert(AP_BOT_LIST, version);
        address currentBotList = creditFacade().botList();

        if (botList != currentBotList) {
            creditFacade().setBotList(botList);
            emit SetBotList(botList);
        }
    }

    /// @notice Adds an address to the list of emergency liquidators
    /// @param liquidator The address to add to the list
    /// @dev Emergency liquidators are trusted addresses
    /// that are able to liquidate positions while the contracts are paused,
    /// e.g. when there is a risk of bad debt while an exploit is being patched.
    /// In the interest of fairness, emergency liquidators do not receive a premium
    /// And are compensated by the Gearbox DAO separately.
    function addEmergencyLiquidator(address liquidator)
        external
        configuratorOnly // I:[CC-38]
    {
        _addEmergencyLiquidator(liquidator);
    }

    /// @notice IMPLEMENTATION: addEmergencyLiquidator
    function _addEmergencyLiquidator(address liquidator) internal {
        bool statusCurrent = creditFacade().canLiquidateWhilePaused(liquidator);

        // Checks that the address is not already in the list,
        // to avoid redundant events
        if (!statusCurrent) {
            creditFacade().setEmergencyLiquidator(liquidator, AllowanceAction.ALLOW); // I:[CC-38]
            emergencyLiquidatorsSet.add(liquidator);
            emit AddEmergencyLiquidator(liquidator); // I:[CC-38]
        }
    }

    /// @notice Removex an address frp, the list of emergency liquidators
    /// @param liquidator The address to remove from the list
    function removeEmergencyLiquidator(address liquidator)
        external
        configuratorOnly // I:[CC-38]
    {
        _removeEmergencyLiquidator(liquidator);
    }

    /// @notice IMPLEMENTATION: removeEmergencyLiquidator
    function _removeEmergencyLiquidator(address liquidator) internal {
        bool statusCurrent = creditFacade().canLiquidateWhilePaused(liquidator);

        // Checks that the address is in the list
        // to avoid redundant events
        if (statusCurrent) {
            creditFacade().setEmergencyLiquidator(liquidator, AllowanceAction.FORBID); // I:[CC-38]
            emergencyLiquidatorsSet.remove(liquidator);
            emit RemoveEmergencyLiquidator(liquidator); // I:[CC-38]
        }
    }

    //
    // GETTERS
    //

    /// @notice Returns all allowed contracts
    function allowedContracts() external view override returns (address[] memory result) {
        uint256 len = allowedContractsSet.length();
        result = new address[](len);
        for (uint256 i; i < len;) {
            result[i] = allowedContractsSet.at(i);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Returns all emergency liquidators
    function emergencyLiquidators() external view override returns (address[] memory result) {
        uint256 len = emergencyLiquidatorsSet.length();
        result = new address[](len);
        for (uint256 i; i < len;) {
            result[i] = emergencyLiquidatorsSet.at(i);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Returns all forbidden tokens
    function forbiddenTokens() external view override returns (address[] memory result) {
        uint256 len = forbiddenTokensSet.length();
        result = new address[](len);
        for (uint256 i; i < len;) {
            result[i] = forbiddenTokensSet.at(i);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Returns the Credit Facade currently connected to the Credit Manager
    function creditFacade() public view override returns (CreditFacadeV3) {
        return CreditFacadeV3(creditManager.creditFacade());
    }
}
