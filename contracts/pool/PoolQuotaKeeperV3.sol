// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity 0.8.23;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {ICreditManagerV3} from "../interfaces/ICreditManagerV3.sol";
import {AccountQuota, IPoolQuotaKeeperV3, TokenQuotaParams} from "../interfaces/IPoolQuotaKeeperV3.sol";
import {IPoolV3} from "../interfaces/IPoolV3.sol";
import {IRateKeeper} from "../interfaces/base/IRateKeeper.sol";

import {PERCENTAGE_FACTOR} from "../libraries/Constants.sol";
import {QuotasLogic} from "../libraries/QuotasLogic.sol";

import {ACLNonReentrantTrait} from "../traits/ACLNonReentrantTrait.sol";
import {ContractsRegisterTrait} from "../traits/ContractsRegisterTrait.sol";

import "../interfaces/IExceptions.sol";

/// @title Pool quota keeper V3
/// @notice In Gearbox V3, quotas are used to limit the system exposure to risky assets.
///         In order for a risky token to be counted towards credit account's collateral, account owner must "purchase"
///         a quota for this token, which entails two kinds of payments:
///         * interest that accrues over time with rates determined by the gauge (more suited to leveraged farming), and
///         * increase fee that is charged when additional quota is purchased (more suited to leveraged trading).
///         Quota keeper stores information about quotas of accounts in all credit managers connected to the pool, and
///         performs calculations that help to keep pool's expected liquidity and credit managers' debt consistent.
/// @dev Any contract that implements the `IRateKeeper` interface can be used everywhere where the term "gauge" is used
contract PoolQuotaKeeperV3 is IPoolQuotaKeeperV3, ACLNonReentrantTrait, ContractsRegisterTrait {
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @notice Contract version
    uint256 public constant override version = 3_10;

    /// @notice Address of the underlying token
    address public immutable override underlying;

    /// @notice Address of the pool
    address public immutable override pool;

    /// @dev The set of all allowed credit managers
    EnumerableSet.AddressSet internal _creditManagersSet;

    /// @dev The set of all quoted tokens
    EnumerableSet.AddressSet internal _quotedTokensSet;

    /// @dev Mapping from token to global token quota params
    mapping(address => TokenQuotaParams) internal _tokenQuotaParams;

    /// @dev Mapping from (creditAccount, token) to account's token quota params
    mapping(address => mapping(address => AccountQuota)) internal _accountQuotas;

    /// @notice Address of the gauge
    address public override gauge;

    /// @notice Timestamp of the last quota rates update
    uint40 public override lastQuotaRateUpdate;

    /// @dev Ensures that function caller is the gauge
    modifier gaugeOnly() {
        _revertIfCallerNotGauge();
        _;
    }

    /// @dev Ensures that function caller is an allowed credit manager
    modifier creditManagerOnly() {
        _revertIfCallerNotCreditManager();
        _;
    }

    /// @notice Constructor
    /// @param acl_ ACL contract address
    /// @param contractsRegister_ Contracts register address
    /// @param pool_ Pool address
    /// @custom:tests U:[QK-1]
    constructor(address acl_, address contractsRegister_, address pool_)
        ACLNonReentrantTrait(acl_)
        ContractsRegisterTrait(contractsRegister_)
    {
        pool = pool_;
        underlying = IPoolV3(pool_).asset();
    }

    /// @notice Whether `creditManager` is added
    function isCreditManagerAdded(address creditManager) external view override returns (bool) {
        return _creditManagersSet.contains(creditManager);
    }

    /// @notice Returns the list of all added credit managers
    function creditManagers() external view override returns (address[] memory) {
        return _creditManagersSet.values();
    }

    /// @notice Whether `token` is quoted
    function isQuotedToken(address token) external view override returns (bool) {
        return _quotedTokensSet.contains(token);
    }

    /// @notice Returns an array of all quoted tokens
    function quotedTokens() external view override returns (address[] memory) {
        return _quotedTokensSet.values();
    }

    /// @notice Returns global quota params for `token`
    function tokenQuotaParams(address token) external view override returns (TokenQuotaParams memory) {
        return _tokenQuotaParams[token];
    }

    /// @notice Returns `creditAccount`'s quota params for `token`
    function accountQuotas(address creditAccount, address token) external view override returns (AccountQuota memory) {
        return _accountQuotas[creditAccount][token];
    }

    // ----------------- //
    // QUOTAS MANAGEMENT //
    // ----------------- //

    /// @notice Updates `creditAccount`'s quota for `token`
    ///         - Updates account's quota by requested delta subject to the total quota limit
    ///         - Updates account's interest index to the current value for a token
    ///         - Updates pool's quota revenue
    /// @param  creditAccount Credit account to update the quota for
    /// @param  token Token to update the quota for
    /// @param  quotaChange Requested quota change in units of underlying
    /// @param  minQuota Minimum deisred quota amount
    /// @param  maxQuota Maximum allowed quota amount
    /// @return outstandingInterest Token quota interest accrued by account since the last update
    /// @return fees Quota increase fees, if any
    /// @return enableToken Whether the token needs to be enabled as collateral
    /// @return disableToken Whether the token needs to be disabled as collateral
    /// @dev Reverts if `token` is not added or not yet initialized via `updateRates`
    /// @dev Reverts if new quota is not between `minQuota` and `maxQuota`
    /// @custom:tests U:[QK-4], U:[QK-11], U:[QK-12]
    function updateQuota(address creditAccount, address token, int96 quotaChange, uint96 minQuota, uint96 maxQuota)
        external
        override
        creditManagerOnly
        returns (uint128 outstandingInterest, uint128 fees, bool enableToken, bool disableToken)
    {
        TokenQuotaParams memory tqp = _tokenQuotaParams[token];
        AccountQuota memory aq = _accountQuotas[creditAccount][token];
        if (tqp.rate == 0) revert TokenIsNotQuotedException();

        if (quotaChange > 0) {
            // `limit` can be at most `type(int96).max`, so cast is safe
            quotaChange = int96(
                QuotasLogic.calcQuotaIncrease({
                    totalQuoted: tqp.totalQuoted,
                    limit: tqp.limit,
                    requested: uint96(quotaChange)
                })
            );
            // downcast to `uint128` is safe because the result is at most `quotaChange` which fits into `uint96`
            fees = uint128(uint256(uint96(quotaChange)) * tqp.quotaIncreaseFee / PERCENTAGE_FACTOR);
        } else if (quotaChange < 0) {
            // `aq.quota` can be at most `type(int96).max` so negation can't underflow
            if (quotaChange == type(int96).min || uint96(-quotaChange) > aq.quota) quotaChange = -int96(aq.quota);
        }

        // `quotaChange` was adjusted such that `quota + quotaChange` is between `0` and `type(int96).max`
        uint96 newQuota = uint96(int96(aq.quota) + quotaChange);
        if (newQuota < minQuota || newQuota > maxQuota) revert QuotaIsOutOfBoundsException();
        if (quotaChange == 0) return (0, 0, false, false);

        uint192 cumulativeIndexNow = QuotasLogic.cumulativeIndexSince({
            cumulativeIndexLU: tqp.cumulativeIndexLU,
            rate: tqp.rate,
            lastQuotaRateUpdate: lastQuotaRateUpdate
        });
        outstandingInterest = QuotasLogic.calcAccruedQuotaInterest({
            quoted: aq.quota,
            cumulativeIndexNow: cumulativeIndexNow,
            cumulativeIndexLU: aq.cumulativeIndexLU
        });
        enableToken = aq.quota == 0 && newQuota != 0;
        disableToken = aq.quota != 0 && newQuota == 0;

        // `quotaChange` was adjusted such that `totalQuoted + quotaChange` is between `0` and `type(int96).max`
        _tokenQuotaParams[token].totalQuoted = uint96(int96(tqp.totalQuoted) + quotaChange);
        _accountQuotas[creditAccount][token] = AccountQuota({quota: newQuota, cumulativeIndexLU: cumulativeIndexNow});
        emit UpdateQuota({creditAccount: creditAccount, token: token, quotaChange: quotaChange});

        int256 quotaRevenueChange = QuotasLogic.calcQuotaRevenueChange({rate: tqp.rate, change: quotaChange});
        if (quotaRevenueChange != 0) IPoolV3(pool).updateQuotaRevenue(quotaRevenueChange);
    }

    /// @notice Removes `creditAccount`'s quotas for `tokens`
    ///         - Sets account's tokens quotas to zero
    ///         - Account's interest indexes updates are skipped since quotas are zero
    ///         - Decreases pool's quota revenue
    ///         - Optionally sets quota limits for tokens to zero, effectively preventing further exposure
    ///           to them in extreme cases (e.g., liquidations with loss)
    /// @param  creditAccount Credit account to remove quotas for
    /// @param  tokens Array of tokens to remove quotas for
    /// @param  setLimitsToZero Whether tokens quota limits should be set to zero
    /// @dev    Reverts if any of `tokens` is not added or not yet initialized via `updateRates`
    /// @custom:tests U:[QK-4], U:[QK-13]
    function removeQuotas(address creditAccount, address[] calldata tokens, bool setLimitsToZero)
        external
        override
        creditManagerOnly
    {
        int256 quotaRevenueChange;

        uint256 len = tokens.length;
        for (uint256 i; i < len; ++i) {
            address token = tokens[i];

            uint16 rate = _tokenQuotaParams[token].rate;
            uint96 quota = _accountQuotas[creditAccount][token].quota;
            if (rate == 0) revert TokenIsNotQuotedException();

            // `quota` can be at most `type(int96).max`, so negation can't underflow
            int96 quotaChange = -int96(quota);

            _tokenQuotaParams[token].totalQuoted -= quota;
            _accountQuotas[creditAccount][token].quota = 0;
            emit UpdateQuota({creditAccount: creditAccount, token: token, quotaChange: quotaChange});

            quotaRevenueChange += QuotasLogic.calcQuotaRevenueChange({rate: rate, change: quotaChange});
            if (setLimitsToZero) _setTokenLimit(token, 0);
        }

        if (quotaRevenueChange != 0) IPoolV3(pool).updateQuotaRevenue(quotaRevenueChange);
    }

    /// @notice Updates `creditAccount`'s interest indexes for `tokens`
    /// @param  creditAccount Credit account to accrue interest for
    /// @param  tokens Array of tokens to accrue interest for
    /// @dev    Reverts if any of `tokens` is not added or not yet initialized via `updateRates`
    /// @custom:tests U:[QK-4], U:[QK-14]
    function accrueQuotaInterest(address creditAccount, address[] calldata tokens)
        external
        override
        creditManagerOnly
    {
        uint40 lastQuotaRateUpdate_ = lastQuotaRateUpdate;
        uint256 len = tokens.length;
        for (uint256 i; i < len; ++i) {
            address token = tokens[i];
            _accountQuotas[creditAccount][token].cumulativeIndexLU = _getCumulativeIndexNow(token, lastQuotaRateUpdate_);
        }
    }

    /// @notice Returns `creditAccount`'s quota for `token` and interest accrued since the last update
    /// @param  creditAccount Account to compute the values for
    /// @param  token Token to compute the values for
    /// @return quoted Account's token quota
    /// @return outstandingInterest Quota interest accrued since the last update
    /// @dev    Reverts if `token` is not added or not yet initialized via `updateRates`
    function getQuotaAndOutstandingInterest(address creditAccount, address token)
        external
        view
        override
        returns (uint96 quoted, uint128 outstandingInterest)
    {
        AccountQuota storage aq = _accountQuotas[creditAccount][token];
        quoted = aq.quota;
        outstandingInterest = QuotasLogic.calcAccruedQuotaInterest({
            quoted: quoted,
            cumulativeIndexNow: _getCumulativeIndexNow(token, lastQuotaRateUpdate),
            cumulativeIndexLU: aq.cumulativeIndexLU
        });
    }

    // ------------- //
    // CONFIGURATION //
    // ------------- //

    /// @notice Adds `token` to the set of quoted tokens
    /// @dev    Reverts if caller is not gauge
    /// @dev    Reverts if `token` is underlying or is already added
    /// @custom:tests U:[QK-3], U:[QK-5]
    function addQuotaToken(address token) external override gaugeOnly {
        if (token == underlying) revert TokenNotAllowedException();
        if (!_quotedTokensSet.add(token)) revert TokenAlreadyAddedException();
        emit AddQuotaToken(token);
    }

    /// @notice Updates quota rates
    ///         - Updates global token cumulative indexes before changing rates
    ///         - Queries new rates for all quoted tokens from the gauge
    ///         - Sets new pool quota revenue
    /// @dev    Reverts if caller is not gauge
    /// @dev    Reverts if gauge returns zero rates for some of the added tokens
    /// @custom:tests U:[QK-3], U:[QK-6]
    function updateRates() external override gaugeOnly {
        address[] memory tokens = _quotedTokensSet.values();
        uint16[] memory rates = IRateKeeper(gauge).getRates(tokens);

        uint256 quotaRevenue;
        uint256 lastQuotaRateUpdate_ = lastQuotaRateUpdate;

        uint256 len = tokens.length;
        for (uint256 i; i < len; ++i) {
            (address token, uint16 rate) = (tokens[i], rates[i]);
            if (rate == 0) revert IncorrectParameterException();

            TokenQuotaParams memory tqp = _tokenQuotaParams[token];
            _tokenQuotaParams[token].rate = rate;
            _tokenQuotaParams[token].cumulativeIndexLU = QuotasLogic.cumulativeIndexSince({
                cumulativeIndexLU: tqp.cumulativeIndexLU,
                rate: tqp.rate,
                lastQuotaRateUpdate: lastQuotaRateUpdate_
            });

            quotaRevenue += uint256(tqp.totalQuoted) * rate / PERCENTAGE_FACTOR;

            emit UpdateTokenQuotaRate(token, rate);
        }

        IPoolV3(pool).setQuotaRevenue(quotaRevenue);
        lastQuotaRateUpdate = uint40(block.timestamp);
    }

    /// @notice Sets `newGauge` as a new rate keeper
    /// @dev    Reverts if caller is not configurator
    /// @dev    Reverts if `newGauge` is connected to a different quota keeper or doesn't have all needed tokens added
    /// @custom:tests U:[QK-2], U:[QK-7]
    function setGauge(address newGauge) external override configuratorOnly {
        if (IRateKeeper(newGauge).quotaKeeper() != address(this)) revert IncompatibleGaugeException();
        uint256 len = _quotedTokensSet.length();
        for (uint256 i; i < len; ++i) {
            if (!IRateKeeper(gauge).isTokenAdded(_quotedTokensSet.at(i))) revert TokenIsNotQuotedException();
        }
        if (newGauge != gauge) {
            gauge = newGauge;
            emit SetGauge(newGauge);
        }
    }

    /// @notice Adds `creditManager` to the set of allowed credit managers
    /// @dev    Reverts if caller is not configurator
    /// @dev    Reverts if `creditManager` is not registered or is connected to a different pool
    /// @custom:tests U:[QK-2], U:[QK-8]
    function addCreditManager(address creditManager)
        external
        override
        configuratorOnly
        registeredCreditManagerOnly(creditManager)
    {
        if (ICreditManagerV3(creditManager).pool() != pool) revert IncompatibleCreditManagerException();
        if (_creditManagersSet.add(creditManager)) emit AddCreditManager(creditManager);
    }

    /// @notice Sets `token`'s total quota limit to `limit` (in units of underlying)
    /// @dev    Reverts if caller is not controller or configurator
    /// @dev    Reverts if `limit` is above `type(int96).max`
    /// @dev    Reverts if `token` is not added
    /// @custom:tests U:[QK-2], U:[QK-9]
    function setTokenLimit(address token, uint96 limit) external override controllerOrConfiguratorOnly {
        if (limit > uint96(type(int96).max)) revert IncorrectParameterException();
        if (!_quotedTokensSet.contains(token)) revert TokenIsNotQuotedException();

        _setTokenLimit(token, limit);
    }

    /// @notice Sets `token`'s  one-time quota increase fee to `fee` (in bps)
    /// @dev    Reverts if caller is not controller or configurator
    /// @dev    Reverts if `fee` is above 100%
    /// @dev    Reverts if `token` is not added
    /// @custom:tests U:[QK-2], U:[QK-10]
    function setTokenQuotaIncreaseFee(address token, uint16 fee) external override controllerOrConfiguratorOnly {
        if (fee > PERCENTAGE_FACTOR) revert IncorrectParameterException();
        if (!_quotedTokensSet.contains(token)) revert TokenIsNotQuotedException();

        if (_tokenQuotaParams[token].quotaIncreaseFee != fee) {
            _tokenQuotaParams[token].quotaIncreaseFee = fee;
            emit SetQuotaIncreaseFee(token, fee);
        }
    }

    // --------- //
    // INTERNALS //
    // --------- //

    /// @dev Returns `token`'s current cumulative index
    function _getCumulativeIndexNow(address token, uint40 lastQuotaRateUpdateCached) internal view returns (uint192) {
        TokenQuotaParams storage tqp = _tokenQuotaParams[token];
        uint16 rate = tqp.rate;
        if (rate == 0) revert TokenIsNotQuotedException();
        return QuotasLogic.cumulativeIndexSince({
            cumulativeIndexLU: tqp.cumulativeIndexLU,
            rate: rate,
            lastQuotaRateUpdate: lastQuotaRateUpdateCached
        });
    }

    /// @dev Sets `token`'s quota limit to `limit`
    function _setTokenLimit(address token, uint96 limit) internal {
        if (_tokenQuotaParams[token].limit != limit) {
            _tokenQuotaParams[token].limit = limit;
            emit SetTokenLimit(token, limit);
        }
    }

    /// @dev Reverts if `msg.sender` is not an allowed credit manager
    function _revertIfCallerNotCreditManager() internal view {
        if (!_creditManagersSet.contains(msg.sender)) revert CallerNotCreditManagerException();
    }

    /// @dev Reverts if `msg.sender` is not gauge
    function _revertIfCallerNotGauge() internal view {
        if (msg.sender != gauge) revert CallerNotGaugeException();
    }
}
