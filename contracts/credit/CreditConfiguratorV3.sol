// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

// THIRD-PARTY
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
    PERCENTAGE_FACTOR,
    WAD
} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";
import {BitMask, UNDERLYING_TOKEN_MASK} from "../libraries/BitMask.sol";

// CONTRACTS
import {ACLNonReentrantTrait} from "../traits/ACLNonReentrantTrait.sol";
import {CreditFacadeV3} from "./CreditFacadeV3.sol";
import {CreditManagerV3} from "./CreditManagerV3.sol";

// INTERFACES
import {IAdapter} from "@gearbox-protocol/core-v2/contracts/interfaces/IAdapter.sol";
import {ICreditConfiguratorV3, CreditManagerOpts, AllowanceAction} from "../interfaces/ICreditConfiguratorV3.sol";
import {IPriceOracleBase} from "@gearbox-protocol/core-v2/contracts/interfaces/IPriceOracleBase.sol";
import {IPoolQuotaKeeperV3} from "../interfaces/IPoolQuotaKeeperV3.sol";
import "../interfaces/IAddressProviderV3.sol";

// EXCEPTIONS
import "../interfaces/IExceptions.sol";

/// @title Credit configurator V3
/// @notice Provides funcionality to configure various aspects of credit manager and facade's behavior
/// @dev Most of the functions can only be accessed by configurator or timelock controller
contract CreditConfiguratorV3 is ICreditConfiguratorV3, ACLNonReentrantTrait {
    using EnumerableSet for EnumerableSet.AddressSet;
    using Address for address;
    using BitMask for uint256;

    /// @notice Contract version
    uint256 public constant override version = 3_01;

    /// @notice Address provider contract address
    address public immutable override addressProvider;

    /// @notice Credit manager address
    address public immutable override creditManager;

    /// @notice Underlying token address
    address public immutable override underlying;

    /// @dev Set of allowed contracts
    EnumerableSet.AddressSet internal allowedAdaptersSet;

    /// @dev Set of emergency liquidators
    EnumerableSet.AddressSet internal emergencyLiquidatorsSet;

    /// @dev Ensures that function is not called for underlying token
    modifier nonUnderlyingTokenOnly(address token) {
        _revertIfUnderlyingToken(token);
        _;
    }

    /// @notice Constructor
    ///         - For a newly deployed credit manager, performs initial configuration:
    ///           * sets its fee parameters to default values
    ///           * connects the credit facade and sets debt limits in it
    ///         - For an existing credit manager, simply copies lists of allowed adapters and emergency liquidators
    ///           from the currently connected credit configurator
    /// @param _creditManager Credit manager to connect to
    /// @param _creditFacade Facade to connect to the credit manager (ignored for existing credit managers)
    /// @param opts Credit manager configuration paramaters, see `CreditManagerOpts` for details
    /// @dev When deploying a new credit suite, this contract must be deployed via `create2`. By the moment of deployment,
    ///      new credit manager must already have pre-computed address of this contract set as credit configurator.
    constructor(CreditManagerV3 _creditManager, CreditFacadeV3 _creditFacade, CreditManagerOpts memory opts)
        ACLNonReentrantTrait(_creditManager.addressProvider())
    {
        creditManager = address(_creditManager); // I:[CC-1]

        underlying = _creditManager.underlying(); // I:[CC-1]

        addressProvider = _creditManager.addressProvider(); // I:[CC-1]

        address currentConfigurator = CreditManagerV3(creditManager).creditConfigurator(); // I:[CC-41]

        // existing credit manager
        if (currentConfigurator != address(this)) {
            address[] memory allowedAdaptersPrev = CreditConfiguratorV3(currentConfigurator).allowedAdapters(); // I:[CC-29]
            uint256 len = allowedAdaptersPrev.length;
            unchecked {
                for (uint256 i = 0; i < len; ++i) {
                    allowedAdaptersSet.add(allowedAdaptersPrev[i]); // I:[CC-29]
                }
            }

            address[] memory emergencyLiquidatorsPrev = CreditConfiguratorV3(currentConfigurator).emergencyLiquidators(); // I:[CC-29]
            len = emergencyLiquidatorsPrev.length;
            unchecked {
                for (uint256 i = 0; i < len; ++i) {
                    emergencyLiquidatorsSet.add(emergencyLiquidatorsPrev[i]); // I:[CC-29]
                }
            }
        }
        // new credit manager
        else {
            _setFees({
                feeInterest: DEFAULT_FEE_INTEREST,
                feeLiquidation: DEFAULT_FEE_LIQUIDATION,
                liquidationDiscount: PERCENTAGE_FACTOR - DEFAULT_LIQUIDATION_PREMIUM,
                feeLiquidationExpired: DEFAULT_FEE_LIQUIDATION_EXPIRED,
                liquidationDiscountExpired: PERCENTAGE_FACTOR - DEFAULT_LIQUIDATION_PREMIUM_EXPIRED
            }); // I:[CC-1]

            CreditManagerV3(creditManager).setCreditFacade(address(_creditFacade)); // I:[CC-1]

            emit SetCreditFacade(address(_creditFacade)); // I:[CC-1A]
            emit SetPriceOracle(CreditManagerV3(creditManager).priceOracle()); // I:[CC-1A]

            _setMaxDebtPerBlockMultiplier(address(_creditFacade), uint8(DEFAULT_LIMIT_PER_BLOCK_MULTIPLIER)); // I:[CC-1]
            _setLimits({_creditFacade: address(_creditFacade), minDebt: opts.minDebt, maxDebt: opts.maxDebt}); // I:[CC-1]
        }
    }

    /// @notice Returns the facade currently connected to the credit manager
    function creditFacade() public view override returns (address) {
        return CreditManagerV3(creditManager).creditFacade();
    }

    // ------ //
    // TOKENS //
    // ------ //

    /// @notice Makes token recognizable as collateral in the credit manager and sets its liquidation threshold
    /// @notice In case token is quoted in the quota keeper, also makes it quoted in the credit manager
    /// @param token Token to add
    /// @param liquidationThreshold LT to set in bps
    /// @dev Reverts if `token` is not a valid ERC-20 token
    /// @dev Reverts if `token` does not have a price feed in the price oracle
    /// @dev Reverts if `token` is underlying
    /// @dev Reverts if `liquidationThreshold` is greater than underlying's LT
    function addCollateralToken(address token, uint16 liquidationThreshold)
        external
        override
        nonZeroAddress(token)
        configuratorOnly // I:[CC-2]
    {
        _addCollateralToken({token: token}); // I:[CC-3,4]
        _setLiquidationThreshold({token: token, liquidationThreshold: liquidationThreshold}); // I:[CC-4]
    }

    /// @dev `addCollateralToken` implementation
    function _addCollateralToken(address token) internal {
        if (!token.isContract()) revert AddressIsNotContractException(token); // I:[CC-3]

        try IERC20(token).balanceOf(address(this)) returns (uint256) {}
        catch {
            revert IncorrectTokenContractException(); // I:[CC-3]
        }

        if (IPriceOracleBase(CreditManagerV3(creditManager).priceOracle()).priceFeeds(token) == address(0)) {
            revert PriceFeedDoesNotExistException(); // I:[CC-3]
        }

        CreditManagerV3(creditManager).addToken({token: token}); // I:[CC-4]

        if (_isQuotedToken(token)) {
            _makeTokenQuoted(token);
        }

        emit AddCollateralToken({token: token}); // I:[CC-4]
    }

    /// @notice Sets token's liquidation threshold
    /// @param token Token to set the LT for
    /// @param liquidationThreshold LT to set in bps
    /// @dev Reverts if `token` is underlying
    /// @dev Reverts if `token` is not recognized as collateral in the credit manager
    /// @dev Reverts if `liquidationThreshold` is greater than underlying's LT
    function setLiquidationThreshold(address token, uint16 liquidationThreshold)
        external
        override
        configuratorOnly // I:[CC-2]
    {
        _setLiquidationThreshold({token: token, liquidationThreshold: liquidationThreshold}); // I:[CC-5]
    }

    /// @dev `setLiquidationThreshold` implementation
    function _setLiquidationThreshold(address token, uint16 liquidationThreshold)
        internal
        nonUnderlyingTokenOnly(token)
    {
        (, uint16 ltUnderlying) =
            CreditManagerV3(creditManager).collateralTokenByMask({tokenMask: UNDERLYING_TOKEN_MASK});

        if (liquidationThreshold > ltUnderlying) {
            revert IncorrectLiquidationThresholdException(); // I:[CC-5]
        }

        CreditManagerV3(creditManager).setCollateralTokenData({
            token: token,
            ltInitial: liquidationThreshold,
            ltFinal: liquidationThreshold,
            timestampRampStart: type(uint40).max,
            rampDuration: 0
        }); // I:[CC-6]

        emit SetTokenLiquidationThreshold({token: token, liquidationThreshold: liquidationThreshold}); // I:[CC-6]
    }

    /// @notice Schedules token's liquidation threshold ramping
    /// @param token Token to ramp the LT for
    /// @param liquidationThresholdFinal Final LT after ramping in bps
    /// @param rampStart Timestamp to start the ramping at
    /// @param rampDuration Ramping duration
    /// @dev Reverts if `token` is underlying
    /// @dev Reverts if `token` is not recognized as collateral in the credit manager
    /// @dev Reverts if `liquidationThresholdFinal` is greater than underlying's LT
    function rampLiquidationThreshold(
        address token,
        uint16 liquidationThresholdFinal,
        uint40 rampStart,
        uint24 rampDuration
    )
        external
        override
        nonUnderlyingTokenOnly(token)
        controllerOnly // I:[CC-2B]
    {
        (, uint16 ltUnderlying) =
            CreditManagerV3(creditManager).collateralTokenByMask({tokenMask: UNDERLYING_TOKEN_MASK});

        if (liquidationThresholdFinal > ltUnderlying) {
            revert IncorrectLiquidationThresholdException(); // I:[CC-30]
        }

        // if function is executed later than `rampStart`, start from `block.timestamp` to avoid LT jumps
        rampStart = block.timestamp > rampStart ? uint40(block.timestamp) : rampStart; // I:[CC-30]

        uint16 currentLT = CreditManagerV3(creditManager).liquidationThresholds({token: token}); // I:[CC-30]
        CreditManagerV3(creditManager).setCollateralTokenData({
            token: token,
            ltInitial: currentLT,
            ltFinal: liquidationThresholdFinal,
            timestampRampStart: rampStart,
            rampDuration: rampDuration
        }); // I:[CC-30]

        emit ScheduleTokenLiquidationThresholdRamp({
            token: token,
            liquidationThresholdInitial: currentLT,
            liquidationThresholdFinal: liquidationThresholdFinal,
            timestampRampStart: rampStart,
            timestampRampEnd: rampStart + rampDuration
        }); // I:[CC-30]
    }

    /// @notice Forbids collateral token in the credit facade
    /// @param token Token to forbid
    /// @dev Reverts if `token` is underlying
    /// @dev Reverts if `token` is not recognized as collateral in the credit manager
    function forbidToken(address token)
        external
        override
        nonZeroAddress(token)
        nonUnderlyingTokenOnly(token)
        pausableAdminsOnly // I:[CC-2A]
    {
        _forbidToken({_creditFacade: creditFacade(), token: token});
    }

    /// @dev `forbidToken` implementation
    function _forbidToken(address _creditFacade, address token) internal {
        CreditFacadeV3 cf = CreditFacadeV3(_creditFacade);

        uint256 tokenMask = _getTokenMaskOrRevert({token: token}); // I:[CC-9]
        if (cf.forbiddenTokenMask() & tokenMask != 0) return; // I:[CC-9]

        cf.setTokenAllowance({token: token, allowance: AllowanceAction.FORBID}); // I:[CC-9]
        emit ForbidToken({token: token}); // I:[CC-9]
    }

    /// @notice Allows a previously forbidden collateral token in the credit facade
    /// @param token Token to allow
    /// @dev Reverts if `token` is underlying
    /// @dev Reverts if `token` is not recognized as collateral in the credit manager
    function allowToken(address token)
        external
        override
        nonZeroAddress(token)
        nonUnderlyingTokenOnly(token)
        configuratorOnly // I:[CC-2]
    {
        CreditFacadeV3 cf = CreditFacadeV3(creditFacade());

        uint256 tokenMask = _getTokenMaskOrRevert({token: token}); // I:[CC-7]
        if (cf.forbiddenTokenMask() & tokenMask == 0) return; // I:[CC-8]

        cf.setTokenAllowance({token: token, allowance: AllowanceAction.ALLOW}); // I:[CC-8]
        emit AllowToken({token: token}); // I:[CC-8]
    }

    /// @notice Makes token quoted
    /// @param token Token to make quoted
    /// @dev Reverts if `token` is not quoted in the quota keeper
    /// @dev Reverts if `token` is not recognized as collateral in the credit manager
    function makeTokenQuoted(address token)
        external
        override
        configuratorOnly // I:[CC-2]
    {
        if (!_isQuotedToken(token)) {
            revert TokenIsNotQuotedException();
        }
        _makeTokenQuoted(token);
    }

    /// @dev `makeTokenQuoted` implementation
    function _makeTokenQuoted(address token) internal nonUnderlyingTokenOnly(token) {
        uint256 tokenMask = _getTokenMaskOrRevert({token: token});
        uint256 quotedTokensMask = CreditManagerV3(creditManager).quotedTokensMask();
        if (quotedTokensMask & tokenMask != 0) return;

        CreditManagerV3(creditManager).setQuotedMask(quotedTokensMask.enable(tokenMask));
        emit QuoteToken(token);
    }

    // -------- //
    // ADAPTERS //
    // -------- //

    /// @notice Returns all allowed adapters
    function allowedAdapters() external view override returns (address[] memory) {
        return allowedAdaptersSet.values();
    }

    /// @notice Allows a new adapter in the credit manager
    /// @notice If adapter's target contract already has an adapter in the credit manager, it is removed
    /// @param adapter Adapter to allow
    /// @dev Reverts if `adapter` is incompatible with the credit manager
    /// @dev Reverts if `adapter`'s target contract is not a contract
    /// @dev Reverts if `adapter` or its target contract is credit manager or credit facade
    function allowAdapter(address adapter)
        external
        override
        nonZeroAddress(adapter)
        configuratorOnly // I:[CC-2]
    {
        address targetContract = _getTargetContractOrRevert({adapter: adapter});
        if (!targetContract.isContract()) {
            revert AddressIsNotContractException(targetContract); // I:[CC-10A]
        }

        if (
            targetContract == creditManager || targetContract == creditFacade() || adapter == creditManager
                || adapter == creditFacade()
        ) revert TargetContractNotAllowedException(); // I:[CC-10C]

        address currentAdapter = CreditManagerV3(creditManager).contractToAdapter(targetContract);
        if (currentAdapter != address(0)) {
            CreditManagerV3(creditManager).setContractAllowance({adapter: currentAdapter, targetContract: address(0)}); // I:[CC-12]
            allowedAdaptersSet.remove(currentAdapter); // I:[CC-12]
        }

        CreditManagerV3(creditManager).setContractAllowance({adapter: adapter, targetContract: targetContract}); // I:[CC-11]

        allowedAdaptersSet.add(adapter); // I:[CC-11]

        emit AllowAdapter({targetContract: targetContract, adapter: adapter}); // I:[CC-11]
    }

    /// @notice Forbids both adapter and its target contract in the credit manager
    /// @param adapter Adapter to forbid
    /// @dev Reverts if `adapter` is incompatible with the credit manager
    /// @dev Reverts if `adapter` is not registered in the credit manager
    function forbidAdapter(address adapter)
        external
        override
        nonZeroAddress(adapter)
        controllerOnly // I:[CC-2B]
    {
        address targetContract = _getTargetContractOrRevert({adapter: adapter});
        if (CreditManagerV3(creditManager).adapterToContract(adapter) == address(0)) {
            revert AdapterIsNotRegisteredException(); // I:[CC-13]
        }

        CreditManagerV3(creditManager).setContractAllowance({adapter: adapter, targetContract: address(0)}); // I:[CC-14]
        CreditManagerV3(creditManager).setContractAllowance({adapter: address(0), targetContract: targetContract}); // I:[CC-14]

        allowedAdaptersSet.remove(adapter); // I:[CC-14]

        emit ForbidAdapter({targetContract: targetContract, adapter: adapter}); // I:[CC-14]
    }

    /// @dev Checks that adapter is compatible with credit manager and returns its target contract
    function _getTargetContractOrRevert(address adapter) internal view returns (address targetContract) {
        _revertIfContractIncompatible(adapter); // I:[CC-10,10B]

        try IAdapter(adapter).targetContract() returns (address tc) {
            targetContract = tc;
        } catch {
            revert IncompatibleContractException();
        }

        if (targetContract == address(0)) revert TargetContractNotAllowedException();
    }

    // -------------- //
    // CREDIT MANAGER //
    // -------------- //

    /// @notice Sets the maximum number of tokens enabled as collateral on a credit account
    /// @param newMaxEnabledTokens New maximum number of enabled tokens
    /// @dev Reverts if `newMaxEnabledTokens` is zero
    function setMaxEnabledTokens(uint8 newMaxEnabledTokens)
        external
        override
        configuratorOnly // I:[CC-2]
    {
        CreditManagerV3 cm = CreditManagerV3(creditManager);

        if (newMaxEnabledTokens == 0) revert IncorrectParameterException(); // I:[CC-26]

        if (newMaxEnabledTokens == cm.maxEnabledTokens()) return;

        cm.setMaxEnabledTokens(newMaxEnabledTokens); // I:[CC-26]
        emit SetMaxEnabledTokens(newMaxEnabledTokens); // I:[CC-26]
    }

    /// @notice Sets new fees params in the credit manager (all fields in bps)
    /// @notice Sets underlying token's liquidation threshold to 1 - liquidation fee - liquidation premium and
    ///         upper-bounds all other tokens' LTs with this number, which interrupts ongoing LT rampings
    /// @param feeInterest Percentage of accrued interest taken by the protocol as profit
    /// @param feeLiquidation Percentage of liquidated account value taken by the protocol as profit
    /// @param liquidationPremium Percentage of liquidated account value that can be taken by liquidator
    /// @param feeLiquidationExpired Percentage of liquidated expired account value taken by the protocol as profit
    /// @param liquidationPremiumExpired Percentage of liquidated expired account value that can be taken by liquidator
    /// @dev Reverts if `feeInterest` is above 100%
    /// @dev Reverts if `liquidationPremium + feeLiquidation` is above 100%
    /// @dev Reverts if `liquidationPremiumExpired + feeLiquidationExpired` is above 100%
    function setFees(
        uint16 feeInterest,
        uint16 feeLiquidation,
        uint16 liquidationPremium,
        uint16 feeLiquidationExpired,
        uint16 liquidationPremiumExpired
    )
        external
        override
        configuratorOnly // I:[CC-2]
    {
        if (
            feeInterest >= PERCENTAGE_FACTOR || (liquidationPremium + feeLiquidation) >= PERCENTAGE_FACTOR
                || (liquidationPremiumExpired + feeLiquidationExpired) >= PERCENTAGE_FACTOR
        ) revert IncorrectParameterException(); // I:[CC-17]

        _setFees({
            feeInterest: feeInterest,
            feeLiquidation: feeLiquidation,
            liquidationDiscount: PERCENTAGE_FACTOR - liquidationPremium,
            feeLiquidationExpired: feeLiquidationExpired,
            liquidationDiscountExpired: PERCENTAGE_FACTOR - liquidationPremiumExpired
        });
    }

    /// @dev `setFees` implementation
    function _setFees(
        uint16 feeInterest,
        uint16 feeLiquidation,
        uint16 liquidationDiscount,
        uint16 feeLiquidationExpired,
        uint16 liquidationDiscountExpired
    ) internal {
        uint16 newLTUnderlying = uint16(liquidationDiscount - feeLiquidation); // I:[CC-18]
        (, uint16 ltUnderlying) =
            CreditManagerV3(creditManager).collateralTokenByMask({tokenMask: UNDERLYING_TOKEN_MASK});

        if (newLTUnderlying != ltUnderlying) {
            _updateUnderlyingLT(newLTUnderlying); // I:[CC-18]
            emit SetTokenLiquidationThreshold({token: underlying, liquidationThreshold: newLTUnderlying}); // I:[CC-1A,18]
        }

        (
            uint16 _feeInterestCurrent,
            uint16 _feeLiquidationCurrent,
            uint16 _liquidationDiscountCurrent,
            uint16 _feeLiquidationExpiredCurrent,
            uint16 _liquidationDiscountExpiredCurrent
        ) = CreditManagerV3(creditManager).fees();

        if (
            (feeInterest == _feeInterestCurrent) && (feeLiquidation == _feeLiquidationCurrent)
                && (liquidationDiscount == _liquidationDiscountCurrent)
                && (feeLiquidationExpired == _feeLiquidationExpiredCurrent)
                && (liquidationDiscountExpired == _liquidationDiscountExpiredCurrent)
        ) return;

        CreditManagerV3(creditManager).setFees({
            _feeInterest: feeInterest,
            _feeLiquidation: feeLiquidation,
            _liquidationDiscount: liquidationDiscount,
            _feeLiquidationExpired: feeLiquidationExpired,
            _liquidationDiscountExpired: liquidationDiscountExpired
        }); // I:[CC-19]

        emit UpdateFees({
            feeInterest: feeInterest,
            feeLiquidation: feeLiquidation,
            liquidationPremium: PERCENTAGE_FACTOR - liquidationDiscount,
            feeLiquidationExpired: feeLiquidationExpired,
            liquidationPremiumExpired: PERCENTAGE_FACTOR - liquidationDiscountExpired
        }); // I:[CC-1A,19]
    }

    /// @dev Updates underlying token's liquidation threshold
    function _updateUnderlyingLT(uint16 ltUnderlying) internal {
        CreditManagerV3(creditManager).setCollateralTokenData({
            token: underlying,
            ltInitial: ltUnderlying,
            ltFinal: ltUnderlying,
            timestampRampStart: type(uint40).max,
            rampDuration: 0
        }); // I:[CC-25]

        uint256 len = CreditManagerV3(creditManager).collateralTokensCount();
        unchecked {
            for (uint256 i = 1; i < len; ++i) {
                (address token, uint16 lt) = CreditManagerV3(creditManager).collateralTokenByMask({tokenMask: 1 << i});
                if (lt > ltUnderlying) {
                    _setLiquidationThreshold({token: token, liquidationThreshold: ltUnderlying}); // I:[CC-25]
                }
            }
        }
    }

    // -------- //
    // UPGRADES //
    // -------- //

    /// @notice Sets the new price oracle contract in the credit manager
    /// @param newVersion Version of the new price oracle to take from the address provider
    /// @dev Reverts if price oracle of given version is not found in the address provider
    function setPriceOracle(uint256 newVersion)
        external
        override
        configuratorOnly // I:[CC-2]
    {
        address priceOracle = IAddressProviderV3(addressProvider).getAddressOrRevert(AP_PRICE_ORACLE, newVersion); // I:[CC-21]

        if (priceOracle == CreditManagerV3(creditManager).priceOracle()) return;

        CreditManagerV3(creditManager).setPriceOracle(priceOracle); // I:[CC-21]
        emit SetPriceOracle(priceOracle); // I:[CC-21]
    }

    /// @notice Sets the new bot list contract in the credit facade
    /// @param newVersion Version of the new bot list to take from the address provider
    /// @dev Reverts if bot list of given version is not found in the address provider
    function setBotList(uint256 newVersion)
        external
        override
        configuratorOnly // I:[CC-2]
    {
        address botList = IAddressProviderV3(addressProvider).getAddressOrRevert(AP_BOT_LIST, newVersion); // I:[CC-33]
        _setBotList(creditFacade(), botList); // I:[CC-33]
    }

    /// @dev `setBotList` implementation
    function _setBotList(address _creditFacade, address botList) internal {
        CreditFacadeV3 cf = CreditFacadeV3(_creditFacade);
        if (botList == cf.botList()) return;
        cf.setBotList(botList); // I:[CC-33]
        emit SetBotList(botList); // I:[CC-33]
    }

    /// @notice Upgrades a facade connected to the credit manager
    /// @param newCreditFacade New credit facade
    /// @param migrateParams Whether to migrate old credit facade params
    /// @dev Reverts if `newCreditFacade` is incompatible with credit manager
    function setCreditFacade(address newCreditFacade, bool migrateParams)
        external
        override
        configuratorOnly // I:[CC-2]
    {
        CreditFacadeV3 prevCreditFacade = CreditFacadeV3(creditFacade());
        if (newCreditFacade == address(prevCreditFacade)) return;

        _revertIfContractIncompatible(newCreditFacade); // I:[CC-20]

        CreditManagerV3(creditManager).setCreditFacade(newCreditFacade); // I:[CC-22]

        if (migrateParams) {
            _setMaxDebtPerBlockMultiplier(newCreditFacade, prevCreditFacade.maxDebtPerBlockMultiplier()); // I:[CC-22]

            (uint128 minDebt, uint128 maxDebt) = prevCreditFacade.debtLimits();
            _setLimits({_creditFacade: newCreditFacade, minDebt: minDebt, maxDebt: maxDebt}); // I:[CC-22]

            (, uint128 maxCumulativeLoss) = prevCreditFacade.lossParams();
            _setMaxCumulativeLoss(newCreditFacade, maxCumulativeLoss); // [CC-22]

            _migrateEmergencyLiquidators(newCreditFacade); // I:[CC-22C]

            _migrateForbiddenTokens(newCreditFacade, prevCreditFacade.forbiddenTokenMask()); // I:[CC-22C]

            if (prevCreditFacade.expirable() && CreditFacadeV3(newCreditFacade).expirable()) {
                _setExpirationDate(newCreditFacade, prevCreditFacade.expirationDate()); // I:[CC-22]
            }

            address botList = prevCreditFacade.botList();
            if (botList != address(0)) _setBotList(newCreditFacade, botList); // I:[CC-22A]
        } else {
            // emergency liquidators set must be cleared to keep it consistent between facade and configurator
            _clearEmergencyLiquidatorsSet(); // I:[CC-22C]
        }

        emit SetCreditFacade(newCreditFacade); // I:[CC-22]
    }

    /// @dev Migrate emergency liquidators to the new credit facade
    function _migrateEmergencyLiquidators(address _creditFacade) internal {
        uint256 len = emergencyLiquidatorsSet.length();
        unchecked {
            for (uint256 i; i < len; ++i) {
                _addEmergencyLiquidator(_creditFacade, emergencyLiquidatorsSet.at(i));
            }
        }
    }

    /// @dev Migrates forbidden tokens to the new credit facade
    function _migrateForbiddenTokens(address _creditFacade, uint256 forbiddenTokensMask) internal {
        unchecked {
            while (forbiddenTokensMask != 0) {
                uint256 mask = forbiddenTokensMask & uint256(-int256(forbiddenTokensMask));
                address token = CreditManagerV3(creditManager).getTokenByMask(mask);
                _forbidToken(_creditFacade, token);
                forbiddenTokensMask ^= mask;
            }
        }
    }

    /// @dev Clears emergency liquidators set
    function _clearEmergencyLiquidatorsSet() internal {
        uint256 len = emergencyLiquidatorsSet.length();
        unchecked {
            for (uint256 i; i < len; ++i) {
                emergencyLiquidatorsSet.remove(emergencyLiquidatorsSet.at(len - i - 1));
            }
        }
    }

    /// @notice Upgrades credit manager's configurator contract
    /// @param newCreditConfigurator New credit configurator
    /// @dev Reverts if `newCreditConfigurator` is incompatible with credit manager
    function upgradeCreditConfigurator(address newCreditConfigurator)
        external
        override
        configuratorOnly // I:[CC-2]
    {
        if (newCreditConfigurator == address(this)) return;

        _revertIfContractIncompatible(newCreditConfigurator); // I:[CC-20]
        CreditManagerV3(creditManager).setCreditConfigurator(newCreditConfigurator); // I:[CC-23]
        emit CreditConfiguratorUpgraded(newCreditConfigurator); // I:[CC-23]
    }

    // ------------- //
    // CREDIT FACADE //
    // ------------- //

    /// @notice Sets the new min debt limit in the credit facade
    /// @param minDebt New minimum debt per credit account
    /// @dev Reverts if `minDebt` is greater than the current max debt
    function setMinDebtLimit(uint128 minDebt) external override controllerOnly {
        address cf = creditFacade();
        (, uint128 currentMaxDebt) = CreditFacadeV3(cf).debtLimits();
        _setLimits(cf, minDebt, currentMaxDebt);
    }

    /// @notice Sets the new max debt limit in the credit facade
    /// @param maxDebt New maximum debt per credit account
    /// @dev Reverts if `maxDebt` is less than the current min debt
    function setMaxDebtLimit(uint128 maxDebt) external override controllerOnly {
        address cf = creditFacade();
        (uint128 currentMinDebt,) = CreditFacadeV3(cf).debtLimits();
        _setLimits(cf, currentMinDebt, maxDebt);
    }

    /// @dev `set{Min|Max}DebtLimit` implementation
    function _setLimits(address _creditFacade, uint128 minDebt, uint128 maxDebt) internal {
        if (minDebt > maxDebt) {
            revert IncorrectLimitsException(); // I:[CC-15]
        }

        CreditFacadeV3 cf = CreditFacadeV3(_creditFacade);

        (uint128 currentMinDebt, uint128 currentMaxDebt) = cf.debtLimits();
        if (currentMinDebt == minDebt && currentMaxDebt == maxDebt) return;

        cf.setDebtLimits(minDebt, maxDebt, cf.maxDebtPerBlockMultiplier()); // I:[CC-16]
        emit SetBorrowingLimits(minDebt, maxDebt); // I:[CC-1A,19]
    }

    /// @notice Sets the new max debt per block multiplier in the credit facade
    /// @param newMaxDebtLimitPerBlockMultiplier The new max debt per block multiplier
    function setMaxDebtPerBlockMultiplier(uint8 newMaxDebtLimitPerBlockMultiplier)
        external
        override
        controllerOnly // I:[CC-2B]
    {
        _setMaxDebtPerBlockMultiplier(creditFacade(), newMaxDebtLimitPerBlockMultiplier); // I:[CC-24]
    }

    /// @notice Disables borrowing in the credit facade by setting max debt per block multiplier to zero
    function forbidBorrowing()
        external
        override
        pausableAdminsOnly // I:[CC-2A]
    {
        _setMaxDebtPerBlockMultiplier(creditFacade(), 0); // I:[CC-24]
    }

    /// @dev `setMaxDebtPerBlockMultiplier` implementation
    function _setMaxDebtPerBlockMultiplier(address _creditFacade, uint8 newMaxDebtLimitPerBlockMultiplier) internal {
        CreditFacadeV3 cf = CreditFacadeV3(_creditFacade);

        if (newMaxDebtLimitPerBlockMultiplier == cf.maxDebtPerBlockMultiplier()) return;

        (uint128 minDebt, uint128 maxDebt) = cf.debtLimits();
        cf.setDebtLimits(minDebt, maxDebt, newMaxDebtLimitPerBlockMultiplier); // I:[CC-24]
        emit SetMaxDebtPerBlockMultiplier(newMaxDebtLimitPerBlockMultiplier); // I:[CC-1A,24]
    }

    /// @notice Sets the new maximum cumulative loss from bad debt liquidations
    /// @param newMaxCumulativeLoss New max cumulative lossd
    function setMaxCumulativeLoss(uint128 newMaxCumulativeLoss)
        external
        override
        configuratorOnly // I:[CC-2]
    {
        _setMaxCumulativeLoss(creditFacade(), newMaxCumulativeLoss); // I:[CC-31]
    }

    /// @dev `setMaxCumulativeLoss` implementation
    function _setMaxCumulativeLoss(address _creditFacade, uint128 _maxCumulativeLoss) internal {
        CreditFacadeV3 cf = CreditFacadeV3(_creditFacade);

        (, uint128 maxCumulativeLossCurrent) = cf.lossParams(); // I:[CC-31]
        if (_maxCumulativeLoss == maxCumulativeLossCurrent) return;

        cf.setCumulativeLossParams(_maxCumulativeLoss, false); // I:[CC-31]
        emit SetMaxCumulativeLoss(_maxCumulativeLoss); // I:[CC-31]
    }

    /// @notice Resets the current cumulative loss from bad debt liquidations to zero
    function resetCumulativeLoss()
        external
        override
        configuratorOnly // I:[CC-2]
    {
        CreditFacadeV3 cf = CreditFacadeV3(creditFacade());
        (, uint128 maxCumulativeLossCurrent) = cf.lossParams(); // I:[CC-32]
        cf.setCumulativeLossParams(maxCumulativeLossCurrent, true); // I:[CC-32]
        emit ResetCumulativeLoss(); // I:[CC-32]
    }

    /// @notice Sets a new credit facade expiration timestamp
    /// @param newExpirationDate New expiration timestamp
    /// @dev Reverts if `newExpirationDate` is in the past
    /// @dev Reverts if `newExpirationDate` is older than the current expiration date
    /// @dev Reverts if credit facade is not expirable
    function setExpirationDate(uint40 newExpirationDate)
        external
        override
        controllerOnly // I:[CC-2B]
    {
        _setExpirationDate(creditFacade(), newExpirationDate); // I:[CC-25]
    }

    /// @dev `setExpirationDate` implementation
    function _setExpirationDate(address _creditFacade, uint40 newExpirationDate) internal {
        CreditFacadeV3 cf = CreditFacadeV3(_creditFacade);

        if (block.timestamp > newExpirationDate || cf.expirationDate() >= newExpirationDate) {
            revert IncorrectExpirationDateException(); // I:[CC-25]
        }

        cf.setExpirationDate(newExpirationDate); // I:[CC-25]
        emit SetExpirationDate(newExpirationDate); // I:[CC-25]
    }

    /// @notice Returns all emergency liquidators
    function emergencyLiquidators() external view override returns (address[] memory) {
        return emergencyLiquidatorsSet.values();
    }

    /// @notice Adds an address to the list of emergency liquidators
    /// @param liquidator Address to add to the list
    function addEmergencyLiquidator(address liquidator)
        external
        override
        configuratorOnly // I:[CC-2]
    {
        _addEmergencyLiquidator(creditFacade(), liquidator); // I:[CC-27]
    }

    /// @dev `addEmergencyLiquidator` implementation
    function _addEmergencyLiquidator(address _creditFacade, address liquidator) internal {
        CreditFacadeV3 cf = CreditFacadeV3(_creditFacade);

        emergencyLiquidatorsSet.add(liquidator); // I:[CC-27]

        if (cf.canLiquidateWhilePaused(liquidator)) return;

        cf.setEmergencyLiquidator(liquidator, AllowanceAction.ALLOW); // I:[CC-27]
        emit AddEmergencyLiquidator(liquidator); // I:[CC-27]
    }

    /// @notice Removes an address from the list of emergency liquidators
    /// @param liquidator Address to remove from the list
    function removeEmergencyLiquidator(address liquidator)
        external
        override
        configuratorOnly // I:[CC-2]
    {
        CreditFacadeV3 cf = CreditFacadeV3(creditFacade());

        emergencyLiquidatorsSet.remove(liquidator); // I:[CC-28]

        if (!cf.canLiquidateWhilePaused(liquidator)) return;

        cf.setEmergencyLiquidator(liquidator, AllowanceAction.FORBID); // I:[CC-28]
        emit RemoveEmergencyLiquidator(liquidator); // I:[CC-28]
    }

    // --------- //
    // INTERNALS //
    // --------- //

    /// @dev Checks whether the quota keeper (if it is set) has a token registered as quoted
    function _isQuotedToken(address token) internal view returns (bool) {
        address quotaKeeper = CreditManagerV3(creditManager).poolQuotaKeeper();
        if (quotaKeeper == address(0)) return false;
        return IPoolQuotaKeeperV3(quotaKeeper).isQuotedToken(token);
    }

    /// @dev Internal wrapper for `creditManager.getTokenMaskOrRevert` call to reduce contract size
    function _getTokenMaskOrRevert(address token) internal view returns (uint256 tokenMask) {
        return CreditManagerV3(creditManager).getTokenMaskOrRevert(token); // I:[CC-7]
    }

    /// @dev Ensures that contract is compatible with credit manager by checking that it implements
    ///      the `creditManager()` function that returns the correct address
    function _revertIfContractIncompatible(address _contract)
        internal
        view
        nonZeroAddress(_contract) // I:[CC-12,29]
    {
        if (!_contract.isContract()) {
            revert AddressIsNotContractException(_contract); // I:[CC-12A,29]
        }

        // any interface with `creditManager()` would work instead of `CreditFacadeV3` here
        try CreditFacadeV3(_contract).creditManager() returns (address cm) {
            if (cm != creditManager) revert IncompatibleContractException(); // I:[CC-12B,29]
        } catch {
            revert IncompatibleContractException(); // I:[CC-12B,29]
        }
    }

    /// @dev Reverts if `token` is underlying
    function _revertIfUnderlyingToken(address token) internal view {
        if (token == underlying) revert TokenNotAllowedException();
    }
}
