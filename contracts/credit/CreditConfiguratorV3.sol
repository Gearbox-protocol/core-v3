// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity 0.8.23;

// THIRD-PARTY
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

// LIBRARIES & CONSTANTS
import {BitMask} from "../libraries/BitMask.sol";
import {CreditLogic} from "../libraries/CreditLogic.sol";
import {PERCENTAGE_FACTOR, UNDERLYING_TOKEN_MASK, WAD} from "../libraries/Constants.sol";

// CONTRACTS
import {ACLTrait} from "../traits/ACLTrait.sol";
import {CreditFacadeV3} from "./CreditFacadeV3.sol";
import {CreditManagerV3} from "./CreditManagerV3.sol";

// INTERFACES
import {ICreditConfiguratorV3, AllowanceAction} from "../interfaces/ICreditConfiguratorV3.sol";
import {IPoolQuotaKeeperV3} from "../interfaces/IPoolQuotaKeeperV3.sol";
import {IPriceOracleV3} from "../interfaces/IPriceOracleV3.sol";
import {IAdapter} from "../interfaces/base/IAdapter.sol";

// EXCEPTIONS
import "../interfaces/IExceptions.sol";

/// @title Credit configurator V3
/// @notice Provides funcionality to configure various aspects of credit manager and facade's behavior
/// @dev Most of the functions can only be accessed by configurator or timelock controller
contract CreditConfiguratorV3 is ICreditConfiguratorV3, ACLTrait {
    using EnumerableSet for EnumerableSet.AddressSet;
    using Address for address;
    using BitMask for uint256;

    /// @notice Contract version
    uint256 public constant override version = 3_10;

    /// @notice Credit manager address
    address public immutable override creditManager;

    /// @notice Underlying token address
    address public immutable override underlying;

    /// @dev Set of allowed contracts
    EnumerableSet.AddressSet internal allowedAdaptersSet;

    /// @dev Ensures that function is not called for underlying token
    modifier nonUnderlyingTokenOnly(address token) {
        _revertIfUnderlyingToken(token);
        _;
    }

    /// @notice Constructor
    /// @param _acl ACL contract address
    /// @param _creditManager Credit manager to connect to
    /// @dev Copies allowed adaprters from the currently connected configurator
    constructor(address _acl, address _creditManager) ACLTrait(_acl) {
        creditManager = _creditManager; // I:[CC-1]
        underlying = CreditManagerV3(_creditManager).underlying(); // I:[CC-1]

        address currentConfigurator = CreditManagerV3(_creditManager).creditConfigurator();
        if (!currentConfigurator.isContract()) return;
        try CreditConfiguratorV3(currentConfigurator).allowedAdapters() returns (address[] memory adapters) {
            uint256 len = adapters.length;
            unchecked {
                for (uint256 i; i < len; ++i) {
                    allowedAdaptersSet.add(adapters[i]); // I:[CC-29]
                }
            }
        } catch {}
    }

    /// @notice Returns the facade currently connected to the credit manager
    function creditFacade() public view override returns (address) {
        return CreditManagerV3(creditManager).creditFacade();
    }

    // ------ //
    // TOKENS //
    // ------ //

    /// @notice Makes token recognizable as collateral in the credit manager and sets its liquidation threshold
    /// @param token Token to add
    /// @param liquidationThreshold LT to set in bps
    /// @dev Reverts if `token` is not a valid ERC-20 token
    /// @dev Reverts if `token` does not have a price feed in the price oracle
    /// @dev Reverts if `token` is underlying
    /// @dev Reverts if `token` is not quoted in the quota keeper
    /// @dev Reverts if `liquidationThreshold` is greater than underlying's LT
    /// @dev `liquidationThreshold` can be zero to allow users to deposit connector tokens to credit accounts and swap
    ///      them into actual collateral and to withdraw reward tokens sent to credit accounts by integrated protocols
    function addCollateralToken(address token, uint16 liquidationThreshold)
        external
        override
        nonZeroAddress(token)
        nonUnderlyingTokenOnly(token)
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

        if (IPriceOracleV3(CreditManagerV3(creditManager).priceOracle()).priceFeeds(token) == address(0)) {
            revert PriceFeedDoesNotExistException(); // I:[CC-3]
        }

        if (!IPoolQuotaKeeperV3(CreditManagerV3(creditManager).poolQuotaKeeper()).isQuotedToken(token)) {
            revert TokenIsNotQuotedException(); // I:[CC-3]
        }

        CreditManagerV3(creditManager).addToken({token: token}); // I:[CC-4]
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
        nonUnderlyingTokenOnly(token)
        controllerOrConfiguratorOnly // I:[CC-2B]
    {
        _setLiquidationThreshold({token: token, liquidationThreshold: liquidationThreshold}); // I:[CC-5]
    }

    /// @dev `setLiquidationThreshold` implementation
    function _setLiquidationThreshold(address token, uint16 liquidationThreshold) internal {
        (, uint16 ltUnderlying) = CreditManagerV3(creditManager).collateralTokenByMask(UNDERLYING_TOKEN_MASK);
        if (liquidationThreshold > ltUnderlying) revert IncorrectLiquidationThresholdException(); // I:[CC-5]

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
    /// @param rampStart If in future, specifies the timestamp to start ramping at, otherwise starts immediately
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
        controllerOrConfiguratorOnly // I:[CC-2B]
    {
        (, uint16 ltUnderlying) = CreditManagerV3(creditManager).collateralTokenByMask(UNDERLYING_TOKEN_MASK);
        if (liquidationThresholdFinal > ltUnderlying) revert IncorrectLiquidationThresholdException(); // I:[CC-30]

        rampStart = block.timestamp > rampStart ? uint40(block.timestamp) : rampStart; // I:[CC-30]

        uint16 currentLT = CreditManagerV3(creditManager).liquidationThresholds(token); // I:[CC-30]
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
        _forbidToken(token);
    }

    /// @dev `forbidToken` implementation
    function _forbidToken(address token) internal {
        CreditFacadeV3 cf = CreditFacadeV3(creditFacade());

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
        controllerOrConfiguratorOnly // I:[CC-2B]
    {
        CreditFacadeV3 cf = CreditFacadeV3(creditFacade());

        uint256 tokenMask = _getTokenMaskOrRevert({token: token}); // I:[CC-7]
        if (cf.forbiddenTokenMask() & tokenMask == 0) return; // I:[CC-8]

        cf.setTokenAllowance({token: token, allowance: AllowanceAction.ALLOW}); // I:[CC-8]
        emit AllowToken({token: token}); // I:[CC-8]
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
    /// @dev Reverts if `adapter` or its target contract is credit facade
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

        address cf = creditFacade();
        if (targetContract == cf || adapter == cf) {
            revert TargetContractNotAllowedException(); // I:[CC-10C]
        }

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
        controllerOrConfiguratorOnly // I:[CC-2B]
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

    /// @notice Sets new fees params in the credit manager (all fields in bps)
    /// @notice Sets underlying token's liquidation threshold to 1 - liquidation fee - liquidation premium
    /// @param feeLiquidation Percentage of liquidated account value taken by the protocol as profit
    /// @param liquidationPremium Percentage of liquidated account value that can be taken by liquidator
    /// @param feeLiquidationExpired Percentage of liquidated expired account value taken by the protocol as profit
    /// @param liquidationPremiumExpired Percentage of liquidated expired account value that can be taken by liquidator
    /// @dev Reverts if `liquidationPremium + feeLiquidation` is above 100%
    /// @dev Reverts if `liquidationPremiumExpired + feeLiquidationExpired` is above 100%
    /// @dev Reverts if new underlying's LT is below some collateral token's LT, accounting for ramps
    function setFees(
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
            (liquidationPremium + feeLiquidation) >= PERCENTAGE_FACTOR
                || (liquidationPremiumExpired + feeLiquidationExpired) >= PERCENTAGE_FACTOR
        ) revert IncorrectParameterException(); // I:[CC-17]

        uint16 liquidationDiscount = PERCENTAGE_FACTOR - liquidationPremium;
        uint16 liquidationDiscountExpired = PERCENTAGE_FACTOR - liquidationPremiumExpired;

        uint16 newLTUnderlying = liquidationDiscount - feeLiquidation; // I:[CC-18]
        (, uint16 ltUnderlying) = CreditManagerV3(creditManager).collateralTokenByMask(UNDERLYING_TOKEN_MASK);

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
            (feeLiquidation == _feeLiquidationCurrent) && (liquidationDiscount == _liquidationDiscountCurrent)
                && (feeLiquidationExpired == _feeLiquidationExpiredCurrent)
                && (liquidationDiscountExpired == _liquidationDiscountExpiredCurrent)
        ) return;

        CreditManagerV3(creditManager).setFees(
            _feeInterestCurrent, feeLiquidation, liquidationDiscount, feeLiquidationExpired, liquidationDiscountExpired
        ); // I:[CC-19]

        emit SetFees({
            feeLiquidation: feeLiquidation,
            liquidationPremium: liquidationPremium,
            feeLiquidationExpired: feeLiquidationExpired,
            liquidationPremiumExpired: liquidationPremiumExpired
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
        }); // I:[CC-18]

        uint256 len = CreditManagerV3(creditManager).collateralTokensCount();
        unchecked {
            for (uint256 i = 1; i < len; ++i) {
                address token = CreditManagerV3(creditManager).getTokenByMask(1 << i);
                (uint16 ltInitial, uint16 ltFinal, uint40 timestampRampStart, uint24 rampDuration) =
                    CreditManagerV3(creditManager).ltParams(token);
                uint16 lt = CreditLogic.getLiquidationThreshold({
                    ltInitial: ltInitial,
                    ltFinal: ltFinal,
                    timestampRampStart: timestampRampStart,
                    rampDuration: rampDuration
                });
                if (lt > ltUnderlying || ltFinal > ltUnderlying) revert IncorrectLiquidationThresholdException(); // I:[CC-18]
            }
        }
    }

    // -------- //
    // UPGRADES //
    // -------- //

    /// @notice Sets the new price oracle contract in the credit manager
    /// @param newPriceOracle New price oracle
    /// @dev Reverts if `newPriceOracle` does not have price feeds for all collateral tokens
    function setPriceOracle(address newPriceOracle)
        external
        override
        configuratorOnly // I:[CC-2]
    {
        if (newPriceOracle == CreditManagerV3(creditManager).priceOracle()) return;

        uint256 num = CreditManagerV3(creditManager).collateralTokensCount();
        unchecked {
            for (uint256 i; i < num; ++i) {
                address token = CreditManagerV3(creditManager).getTokenByMask(1 << i);
                if (IPriceOracleV3(newPriceOracle).priceFeeds(token) == address(0)) {
                    revert PriceFeedDoesNotExistException(); // I:[CC-21]
                }
            }
        }

        CreditManagerV3(creditManager).setPriceOracle(newPriceOracle); // I:[CC-21]
        emit SetPriceOracle(newPriceOracle); // I:[CC-21]
    }

    /// @notice Connects a facade to the credit manager, migrates state of the previous facade if it is set
    /// @param newCreditFacade New credit facade
    /// @dev Reverts if `newCreditFacade` is incompatible with credit manager
    /// @dev Reverts if `newCreditFacade` is one of allowed adapters or their target contracts
    /// @dev Reverts if `newCreditFacade`'s bot list is different from the one already in use
    function setCreditFacade(address newCreditFacade)
        external
        override
        configuratorOnly // I:[CC-2]
    {
        CreditFacadeV3 prevCreditFacade = CreditFacadeV3(creditFacade());
        if (newCreditFacade == address(prevCreditFacade)) return;

        _revertIfContractIncompatible(newCreditFacade); // I:[CC-20]
        if (
            CreditManagerV3(creditManager).adapterToContract(newCreditFacade) != address(0)
                || CreditManagerV3(creditManager).contractToAdapter(newCreditFacade) != address(0)
        ) revert TargetContractNotAllowedException(); // I:[CC-22B]

        CreditManagerV3(creditManager).setCreditFacade(newCreditFacade); // I:[CC-22]

        if (address(prevCreditFacade) != address(0)) {
            _setMaxDebtPerBlockMultiplier(prevCreditFacade.maxDebtPerBlockMultiplier()); // I:[CC-22]

            (uint128 minDebt, uint128 maxDebt) = prevCreditFacade.debtLimits();
            _setLimits({minDebt: minDebt, maxDebt: maxDebt}); // I:[CC-22]

            (, uint128 maxCumulativeLoss) = prevCreditFacade.lossParams();
            _setMaxCumulativeLoss(maxCumulativeLoss); // I:[CC-22]

            _migrateEmergencyLiquidators(prevCreditFacade); // I:[CC-22C]

            _migrateForbiddenTokens(prevCreditFacade.forbiddenTokenMask()); // I:[CC-22C]

            if (prevCreditFacade.expirable() && CreditFacadeV3(newCreditFacade).expirable()) {
                _setExpirationDate(prevCreditFacade.expirationDate()); // I:[CC-22]
            }

            if (CreditFacadeV3(newCreditFacade).botList() != prevCreditFacade.botList()) {
                revert IncorrectBotListException(); // U:[CC-22D]
            }
        }

        emit SetCreditFacade(newCreditFacade); // I:[CC-22]
    }

    /// @dev Migrate emergency liquidators to the new credit facade
    function _migrateEmergencyLiquidators(CreditFacadeV3 prevCreditFacade) internal {
        address[] memory emergencyLiquidators = prevCreditFacade.emergencyLiquidators();
        uint256 len = emergencyLiquidators.length;
        unchecked {
            for (uint256 i; i < len; ++i) {
                _addEmergencyLiquidator(emergencyLiquidators[i]);
            }
        }
    }

    /// @dev Migrates forbidden tokens to the new credit facade
    function _migrateForbiddenTokens(uint256 forbiddenTokensMask) internal {
        while (forbiddenTokensMask != 0) {
            uint256 mask = forbiddenTokensMask.lsbMask();
            address token = CreditManagerV3(creditManager).getTokenByMask(mask);
            _forbidToken(token);
            forbiddenTokensMask ^= mask;
        }
    }

    /// @notice Upgrades credit manager's configurator contract
    /// @param newCreditConfigurator New credit configurator
    /// @dev Reverts if `newCreditConfigurator` is incompatible with credit manager
    /// @dev Reverts if sets of allowed adapters of this contract and new configurator are inconsistent
    function setCreditConfigurator(address newCreditConfigurator)
        external
        override
        configuratorOnly // I:[CC-2]
    {
        if (newCreditConfigurator == address(this)) return;

        _revertIfContractIncompatible(newCreditConfigurator); // I:[CC-20]

        address[] memory newAllowedAdapters = CreditConfiguratorV3(newCreditConfigurator).allowedAdapters();
        uint256 num = newAllowedAdapters.length;
        if (num != allowedAdaptersSet.length()) revert IncorrectAdaptersSetException(); // I:[CC-23]
        unchecked {
            for (uint256 i; i < num; ++i) {
                if (!allowedAdaptersSet.contains(newAllowedAdapters[i])) revert IncorrectAdaptersSetException(); // I:[CC-23]
            }
        }

        CreditManagerV3(creditManager).setCreditConfigurator(newCreditConfigurator); // I:[CC-23]
        emit SetCreditConfigurator(newCreditConfigurator); // I:[CC-23]
    }

    // ------------- //
    // CREDIT FACADE //
    // ------------- //

    /// @notice Sets the new min debt limit in the credit facade
    /// @param minDebt New minimum debt per credit account
    /// @dev Reverts if `minDebt` is greater than the current max debt
    function setMinDebtLimit(uint128 minDebt)
        external
        override
        controllerOrConfiguratorOnly // I:[CC-2B]
    {
        (, uint128 currentMaxDebt) = CreditFacadeV3(creditFacade()).debtLimits();
        _setLimits(minDebt, currentMaxDebt);
    }

    /// @notice Sets the new max debt limit in the credit facade
    /// @param maxDebt New maximum debt per credit account
    /// @dev Reverts if `maxDebt` is less than the current min debt
    function setMaxDebtLimit(uint128 maxDebt)
        external
        override
        controllerOrConfiguratorOnly // I:[CC-2B]
    {
        (uint128 currentMinDebt,) = CreditFacadeV3(creditFacade()).debtLimits();
        _setLimits(currentMinDebt, maxDebt);
    }

    /// @dev `set{Min|Max}DebtLimit` implementation
    function _setLimits(uint128 minDebt, uint128 maxDebt) internal {
        if (minDebt > maxDebt) {
            revert IncorrectLimitsException(); // I:[CC-15]
        }

        CreditFacadeV3 cf = CreditFacadeV3(creditFacade());

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
        controllerOrConfiguratorOnly // I:[CC-2B]
    {
        _setMaxDebtPerBlockMultiplier(newMaxDebtLimitPerBlockMultiplier); // I:[CC-24]
    }

    /// @notice Disables borrowing in the credit facade by setting max debt per block multiplier to zero
    function forbidBorrowing()
        external
        override
        pausableAdminsOnly // I:[CC-2A]
    {
        _setMaxDebtPerBlockMultiplier(0); // I:[CC-24]
    }

    /// @dev `setMaxDebtPerBlockMultiplier` implementation
    function _setMaxDebtPerBlockMultiplier(uint8 newMaxDebtLimitPerBlockMultiplier) internal {
        CreditFacadeV3 cf = CreditFacadeV3(creditFacade());

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
        controllerOrConfiguratorOnly // I:[CC-2B]
    {
        _setMaxCumulativeLoss(newMaxCumulativeLoss); // I:[CC-31]
    }

    /// @dev `setMaxCumulativeLoss` implementation
    function _setMaxCumulativeLoss(uint128 _maxCumulativeLoss) internal {
        CreditFacadeV3 cf = CreditFacadeV3(creditFacade());

        (, uint128 maxCumulativeLossCurrent) = cf.lossParams(); // I:[CC-31]
        if (_maxCumulativeLoss == maxCumulativeLossCurrent) return;

        cf.setCumulativeLossParams(_maxCumulativeLoss, false); // I:[CC-31]
        emit SetMaxCumulativeLoss(_maxCumulativeLoss); // I:[CC-31]
    }

    /// @notice Resets the current cumulative loss from bad debt liquidations to zero
    function resetCumulativeLoss()
        external
        override
        controllerOrConfiguratorOnly // I:[CC-2B]
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
        configuratorOnly // I:[CC-2]
    {
        _setExpirationDate(newExpirationDate); // I:[CC-25]
    }

    /// @dev `setExpirationDate` implementation
    function _setExpirationDate(uint40 newExpirationDate) internal {
        CreditFacadeV3 cf = CreditFacadeV3(creditFacade());

        if (block.timestamp > newExpirationDate || cf.expirationDate() >= newExpirationDate) {
            revert IncorrectExpirationDateException(); // I:[CC-25]
        }

        cf.setExpirationDate(newExpirationDate); // I:[CC-25]
        emit SetExpirationDate(newExpirationDate); // I:[CC-25]
    }

    /// @notice Adds an address to the list of emergency liquidators
    /// @param liquidator Address to add to the list
    function addEmergencyLiquidator(address liquidator)
        external
        override
        configuratorOnly // I:[CC-2]
    {
        _addEmergencyLiquidator(liquidator); // I:[CC-27]
    }

    /// @dev `addEmergencyLiquidator` implementation
    function _addEmergencyLiquidator(address liquidator) internal {
        CreditFacadeV3 cf = CreditFacadeV3(creditFacade());

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

        if (cf.canLiquidateWhilePaused(liquidator)) {
            cf.setEmergencyLiquidator(liquidator, AllowanceAction.FORBID); // I:[CC-28]
            emit RemoveEmergencyLiquidator(liquidator); // I:[CC-28]
        }
    }

    // --------- //
    // INTERNALS //
    // --------- //

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
