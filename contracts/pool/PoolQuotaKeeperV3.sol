// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;
pragma abicoder v1;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// LIBS & TRAITS
import {ACLNonReentrantTrait} from "../traits/ACLNonReentrantTrait.sol";
import {ContractsRegisterTrait} from "../traits/ContractsRegisterTrait.sol";
import {QuotasLogic} from "../libraries/QuotasLogic.sol";

import {IPoolV3} from "../interfaces/IPoolV3.sol";
import {IPoolQuotaKeeperV3, TokenQuotaParams, AccountQuota} from "../interfaces/IPoolQuotaKeeperV3.sol";
import {IGaugeV3} from "../interfaces/IGaugeV3.sol";
import {ICreditManagerV3} from "../interfaces/ICreditManagerV3.sol";

import {PERCENTAGE_FACTOR, RAY} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";

// EXCEPTIONS
import "../interfaces/IExceptions.sol";

/// @title Pool quota keeper V3
/// @notice In Gearbox V3, quotas are used to limit the system exposure to risky assets.
///         In order for a risky token to be counted towards credit account's collateral, account owner must "purchase"
///         a quota for this token, which entails two kinds of payments:
///         * interest that accrues over time with rates determined by the gauge (more suited to leveraged farming), and
///         * increase fee that is charged when additional quota is purchased (more suited to leveraged trading).
///         Quota keeper stores information about quotas of accounts in all credit managers connected to the pool, and
///         performs calculations that help to keep pool's expected liquidity and credit managers' debt consistent.
contract PoolQuotaKeeperV3 is IPoolQuotaKeeperV3, ACLNonReentrantTrait, ContractsRegisterTrait {
    using EnumerableSet for EnumerableSet.AddressSet;
    using QuotasLogic for TokenQuotaParams;

    /// @notice Contract version
    uint256 public constant override version = 3_00;

    /// @notice Address of the underlying token
    address public immutable override underlying;

    /// @notice Address of the pool
    address public immutable override pool;

    /// @dev The list of all allowed credit managers
    EnumerableSet.AddressSet internal creditManagerSet;

    /// @dev The list of all quoted tokens
    EnumerableSet.AddressSet internal quotaTokensSet;

    /// @notice Mapping from token to global token quota params
    mapping(address => TokenQuotaParams) internal totalQuotaParams;

    /// @dev Mapping from (creditAccount, token) to account's token quota params
    mapping(address => mapping(address => AccountQuota)) internal accountQuotas;

    /// @notice Address of the gauge
    address public override gauge;

    /// @notice Timestamp of the last quota rates update
    uint40 public override lastQuotaRateUpdate;

    /// @dev Ensures that function caller is gauge
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
    /// @param _pool Pool address
    constructor(address _pool)
        ACLNonReentrantTrait(IPoolV3(_pool).addressProvider())
        ContractsRegisterTrait(IPoolV3(_pool).addressProvider())
    {
        pool = _pool; // U:[PQK-1]
        underlying = IPoolV3(_pool).asset(); // U:[PQK-1]
    }

    // ----------------- //
    // QUOTAS MANAGEMENT //
    // ----------------- //

    /// @notice Updates credit account's quota for a token
    ///         - Updates account's interest index
    ///         - Updates account's quota by requested delta subject to the total quota limit (which is considered
    ///           to be zero for tokens added to the quota keeper but not yet activated via `updateRates`)
    ///         - Checks that the resulting quota is no less than the user-specified min desired value
    ///           and no more than system-specified max allowed value
    ///         - Updates pool's quota revenue
    /// @param creditAccount Credit account to update the quota for
    /// @param token Token to update the quota for
    /// @param requestedChange Requested quota change in pool's underlying asset units
    /// @param minQuota Minimum deisred quota amount
    /// @param maxQuota Maximum allowed quota amount
    /// @return caQuotaInterestChange Token quota interest accrued by account since the last update
    /// @return fees Quota increase fees, if any
    /// @return enableToken Whether the token needs to be enabled as collateral
    /// @return disableToken Whether the token needs to be disabled as collateral
    function updateQuota(address creditAccount, address token, int96 requestedChange, uint96 minQuota, uint96 maxQuota)
        external
        override
        creditManagerOnly // U:[PQK-4]
        returns (uint128 caQuotaInterestChange, uint128 fees, bool enableToken, bool disableToken)
    {
        int96 quotaChange;
        (caQuotaInterestChange, fees, quotaChange, enableToken, disableToken) =
            _updateQuota(creditAccount, token, requestedChange, minQuota, maxQuota);

        if (quotaChange != 0) {
            emit UpdateQuota({creditAccount: creditAccount, token: token, quotaChange: quotaChange});
        }
    }

    /// @dev Implementation of `updateQuota`
    function _updateQuota(address creditAccount, address token, int96 requestedChange, uint96 minQuota, uint96 maxQuota)
        internal
        returns (uint128 caQuotaInterestChange, uint128 fees, int96 quotaChange, bool enableToken, bool disableToken)
    {
        AccountQuota storage accountQuota = accountQuotas[creditAccount][token];
        TokenQuotaParams storage tokenQuotaParams = totalQuotaParams[token];

        uint96 quoted = accountQuota.quota;

        (uint16 rate, uint192 tqCumulativeIndexLU, uint16 quotaIncreaseFee) =
            _getTokenQuotaParamsOrRevert(tokenQuotaParams);

        uint192 cumulativeIndexNow = QuotasLogic.cumulativeIndexSince(tqCumulativeIndexLU, rate, lastQuotaRateUpdate);

        // Accrued quota interest depends on the quota and thus must be computed before updating it
        caQuotaInterestChange =
            QuotasLogic.calcAccruedQuotaInterest(quoted, cumulativeIndexNow, accountQuota.cumulativeIndexLU); // U:[PQK-15]

        uint96 newQuoted;
        quotaChange = requestedChange;
        if (quotaChange > 0) {
            (uint96 totalQuoted, uint96 limit) = _getTokenQuotaTotalAndLimit(tokenQuotaParams);
            quotaChange = (rate == 0) ? int96(0) : QuotasLogic.calcActualQuotaChange(totalQuoted, limit, quotaChange); // U:[PQK-15]

            fees = uint128(uint256(uint96(quotaChange)) * quotaIncreaseFee / PERCENTAGE_FACTOR); // U:[PQK-15]

            newQuoted = quoted + uint96(quotaChange);
            if (quoted == 0 && newQuoted != 0) {
                enableToken = true; // U:[PQK-15]
            }

            tokenQuotaParams.totalQuoted = totalQuoted + uint96(quotaChange); // U:[PQK-15]
        } else {
            if (quotaChange == type(int96).min) {
                quotaChange = -int96(quoted);
            }

            uint96 absoluteChange = uint96(-quotaChange);
            newQuoted = quoted - absoluteChange;
            tokenQuotaParams.totalQuoted -= absoluteChange; // U:[PQK-15]

            if (quoted != 0 && newQuoted == 0) {
                disableToken = true; // U:[PQK-15]
            }
        }

        if (newQuoted < minQuota || newQuoted > maxQuota) revert QuotaIsOutOfBoundsException(); // U:[PQK-15]

        accountQuota.quota = newQuoted; // U:[PQK-15]
        accountQuota.cumulativeIndexLU = cumulativeIndexNow; // U:[PQK-15]

        int256 quotaRevenueChange = QuotasLogic.calcQuotaRevenueChange(rate, int256(quotaChange)); // U:[PQK-15]
        if (quotaRevenueChange != 0) {
            IPoolV3(pool).updateQuotaRevenue(quotaRevenueChange); // U:[PQK-15]
        }
    }

    /// @notice Removes credit account's quotas for provided tokens
    ///         - Sets account's tokens quotas to zero
    ///         - Optionally sets quota limits for tokens to zero, effectively preventing further exposure
    ///           to them in extreme cases (e.g., liquidations with loss)
    ///         - Does not update account's interest indexes (can be skipped since quotas are zero)
    ///         - Decreases pool's quota revenue
    /// @param creditAccount Credit account to remove quotas for
    /// @param tokens Array of tokens to remove quotas for
    /// @param setLimitsToZero Whether tokens quota limits should be set to zero
    function removeQuotas(address creditAccount, address[] calldata tokens, bool setLimitsToZero)
        external
        override
        creditManagerOnly // U:[PQK-4]
    {
        int256 quotaRevenueChange;

        uint256 len = tokens.length;
        for (uint256 i; i < len;) {
            address token = tokens[i];

            AccountQuota storage accountQuota = accountQuotas[creditAccount][token];
            TokenQuotaParams storage tokenQuotaParams = totalQuotaParams[token];

            uint96 quoted = accountQuota.quota;
            if (quoted != 0) {
                uint16 rate = tokenQuotaParams.rate;
                quotaRevenueChange += QuotasLogic.calcQuotaRevenueChange(rate, -int256(uint256(quoted))); // U:[PQK-16]
                tokenQuotaParams.totalQuoted -= quoted; // U:[PQK-16]
                accountQuota.quota = 0; // U:[PQK-16]
                emit UpdateQuota({creditAccount: creditAccount, token: token, quotaChange: -int96(quoted)});
            }

            if (setLimitsToZero) {
                _setTokenLimit({tokenQuotaParams: tokenQuotaParams, token: token, limit: 0}); // U:[PQK-16]
            }

            unchecked {
                ++i;
            }
        }

        if (quotaRevenueChange != 0) {
            IPoolV3(pool).updateQuotaRevenue(quotaRevenueChange); // U:[PQK-16]
        }
    }

    /// @notice Updates credit account's interest indexes for provided tokens
    /// @param creditAccount Credit account to accrue interest for
    /// @param tokens Array tokens to accrue interest for
    function accrueQuotaInterest(address creditAccount, address[] calldata tokens)
        external
        override
        creditManagerOnly // U:[PQK-4]
    {
        uint256 len = tokens.length;
        uint40 lastQuotaRateUpdate_ = lastQuotaRateUpdate;

        unchecked {
            for (uint256 i; i < len; ++i) {
                address token = tokens[i];

                AccountQuota storage accountQuota = accountQuotas[creditAccount][token];
                TokenQuotaParams storage tokenQuotaParams = totalQuotaParams[token];

                (uint16 rate, uint192 tqCumulativeIndexLU,) = _getTokenQuotaParamsOrRevert(tokenQuotaParams); // U:[PQK-17]

                accountQuota.cumulativeIndexLU =
                    QuotasLogic.cumulativeIndexSince(tqCumulativeIndexLU, rate, lastQuotaRateUpdate_); // U:[PQK-17]
            }
        }
    }

    /// @notice Returns credit account's token quota and interest accrued since the last update
    /// @param creditAccount Account to compute the values for
    /// @param token Token to compute the values for
    /// @return quoted Account's token quota
    /// @return outstandingInterest Quota interest accrued since the last update
    function getQuotaAndOutstandingInterest(address creditAccount, address token)
        external
        view
        override
        returns (uint96 quoted, uint128 outstandingInterest)
    {
        AccountQuota storage accountQuota = accountQuotas[creditAccount][token];

        uint192 cumulativeIndexNow = cumulativeIndex(token);

        quoted = accountQuota.quota;
        uint192 aqCumulativeIndexLU = accountQuota.cumulativeIndexLU;

        outstandingInterest = QuotasLogic.calcAccruedQuotaInterest(quoted, cumulativeIndexNow, aqCumulativeIndexLU); // U:[PQK-15]
    }

    /// @notice Returns current quota interest index for a token in ray
    function cumulativeIndex(address token) public view override returns (uint192) {
        TokenQuotaParams storage tokenQuotaParams = totalQuotaParams[token];
        (uint16 rate, uint192 tqCumulativeIndexLU,) = _getTokenQuotaParamsOrRevert(tokenQuotaParams);

        return QuotasLogic.cumulativeIndexSince(tqCumulativeIndexLU, rate, lastQuotaRateUpdate);
    }

    /// @notice Returns quota interest rate for a token in bps
    function getQuotaRate(address token) external view override returns (uint16) {
        return totalQuotaParams[token].rate;
    }

    /// @notice Returns an array of all quoted tokens
    function quotedTokens() external view override returns (address[] memory) {
        return quotaTokensSet.values();
    }

    /// @notice Whether a token is quoted
    function isQuotedToken(address token) external view override returns (bool) {
        return quotaTokensSet.contains(token);
    }

    /// @notice Returns account's quota params for a token
    function getQuota(address creditAccount, address token)
        external
        view
        override
        returns (uint96 quota, uint192 cumulativeIndexLU)
    {
        AccountQuota storage aq = accountQuotas[creditAccount][token];
        return (aq.quota, aq.cumulativeIndexLU);
    }

    /// @notice Returns global quota params for a token
    function getTokenQuotaParams(address token)
        external
        view
        override
        returns (
            uint16 rate,
            uint192 cumulativeIndexLU,
            uint16 quotaIncreaseFee,
            uint96 totalQuoted,
            uint96 limit,
            bool isActive
        )
    {
        TokenQuotaParams memory tq = totalQuotaParams[token];
        rate = tq.rate;
        cumulativeIndexLU = tq.cumulativeIndexLU;
        quotaIncreaseFee = tq.quotaIncreaseFee;
        totalQuoted = tq.totalQuoted;
        limit = tq.limit;
        isActive = rate != 0;
    }

    /// @notice Returns the pool's quota revenue (in units of underlying per year)
    function poolQuotaRevenue() external view virtual override returns (uint256 quotaRevenue) {
        address[] memory tokens = quotaTokensSet.values();

        uint256 len = tokens.length;

        for (uint256 i; i < len;) {
            address token = tokens[i];

            TokenQuotaParams storage tokenQuotaParams = totalQuotaParams[token];
            (uint16 rate,,) = _getTokenQuotaParamsOrRevert(tokenQuotaParams);
            (uint256 totalQuoted,) = _getTokenQuotaTotalAndLimit(tokenQuotaParams);

            quotaRevenue += totalQuoted * rate / PERCENTAGE_FACTOR;

            unchecked {
                ++i;
            }
        }
    }

    /// @notice Returns the list of allowed credit managers
    function creditManagers() external view override returns (address[] memory) {
        return creditManagerSet.values(); // U:[PQK-10]
    }

    // ------------- //
    // CONFIGURATION //
    // ------------- //

    /// @notice Adds a new quota token
    /// @param token Address of the token
    function addQuotaToken(address token)
        external
        override
        gaugeOnly // U:[PQK-3]
    {
        if (quotaTokensSet.contains(token)) {
            revert TokenAlreadyAddedException(); // U:[PQK-6]
        }

        // The rate will be set during a general epoch update in the gauge
        quotaTokensSet.add(token); // U:[PQK-5]
        totalQuotaParams[token].cumulativeIndexLU = 1; // U:[PQK-5]

        emit AddQuotaToken(token); // U:[PQK-5]
    }

    /// @notice Updates quota rates
    ///         - Updates global token cumulative indexes before changing rates
    ///         - Queries new rates for all quoted tokens from the gauge
    ///         - Sets new pool quota revenue
    function updateRates()
        external
        override
        gaugeOnly // U:[PQK-3]
    {
        address[] memory tokens = quotaTokensSet.values();
        uint16[] memory rates = IGaugeV3(gauge).getRates(tokens); // U:[PQK-7]

        uint256 quotaRevenue;
        uint256 timestampLU = lastQuotaRateUpdate;
        uint256 len = tokens.length;

        for (uint256 i; i < len;) {
            address token = tokens[i];
            uint16 rate = rates[i];

            TokenQuotaParams storage tokenQuotaParams = totalQuotaParams[token]; // U:[PQK-7]
            (uint16 prevRate, uint192 tqCumulativeIndexLU,) = _getTokenQuotaParamsOrRevert(tokenQuotaParams);

            tokenQuotaParams.cumulativeIndexLU =
                QuotasLogic.cumulativeIndexSince(tqCumulativeIndexLU, prevRate, timestampLU); // U:[PQK-7]

            tokenQuotaParams.rate = rate; // U:[PQK-7]

            quotaRevenue += uint256(tokenQuotaParams.totalQuoted) * rate / PERCENTAGE_FACTOR; // U:[PQK-7]

            emit UpdateTokenQuotaRate(token, rate); // U:[PQK-7]

            unchecked {
                ++i;
            }
        }

        IPoolV3(pool).setQuotaRevenue(quotaRevenue); // U:[PQK-7]
        lastQuotaRateUpdate = uint40(block.timestamp); // U:[PQK-7]
    }

    /// @notice Sets a new gauge contract to compute quota rates
    /// @param _gauge Address of the new gauge contract
    function setGauge(address _gauge)
        external
        override
        configuratorOnly // U:[PQK-2]
    {
        if (gauge != _gauge) {
            gauge = _gauge; // U:[PQK-8]
            emit SetGauge(_gauge); // U:[PQK-8]
        }
    }

    /// @notice Adds an address to the set of allowed credit managers
    /// @param _creditManager Address of the new credit manager
    function addCreditManager(address _creditManager)
        external
        override
        configuratorOnly // U:[PQK-2]
        nonZeroAddress(_creditManager)
        registeredCreditManagerOnly(_creditManager) // U:[PQK-9]
    {
        if (ICreditManagerV3(_creditManager).pool() != pool) {
            revert IncompatibleCreditManagerException(); // U:[PQK-9]
        }

        if (!creditManagerSet.contains(_creditManager)) {
            creditManagerSet.add(_creditManager); // U:[PQK-10]
            emit AddCreditManager(_creditManager); // U:[PQK-10]
        }
    }

    /// @notice Sets the total quota limit for a token
    /// @param token Address of token to set the limit for
    /// @param limit The limit to set
    function setTokenLimit(address token, uint96 limit)
        external
        override
        controllerOnly // U:[PQK-2]
    {
        TokenQuotaParams storage tokenQuotaParams = totalQuotaParams[token];
        _setTokenLimit(tokenQuotaParams, token, limit);
    }

    /// @dev Implementation of `setTokenLimit`
    function _setTokenLimit(TokenQuotaParams storage tokenQuotaParams, address token, uint96 limit) internal {
        if (!isInitialised(tokenQuotaParams)) {
            revert TokenIsNotQuotedException(); // U:[PQK-11]
        }

        if (tokenQuotaParams.limit != limit) {
            tokenQuotaParams.limit = limit; // U:[PQK-12]
            emit SetTokenLimit(token, limit); // U:[PQK-12]
        }
    }

    /// @notice Sets the one-time quota increase fee for a token
    /// @param token Token to set the fee for
    /// @param fee The new fee value in bps
    function setTokenQuotaIncreaseFee(address token, uint16 fee)
        external
        override
        controllerOnly // U:[PQK-2]
    {
        if (fee > PERCENTAGE_FACTOR) {
            revert IncorrectParameterException();
        }

        TokenQuotaParams storage tokenQuotaParams = totalQuotaParams[token]; // U:[PQK-13]

        if (!isInitialised(tokenQuotaParams)) {
            revert TokenIsNotQuotedException();
        }

        if (tokenQuotaParams.quotaIncreaseFee != fee) {
            tokenQuotaParams.quotaIncreaseFee = fee; // U:[PQK-13]
            emit SetQuotaIncreaseFee(token, fee); // U:[PQK-13]
        }
    }

    // --------- //
    // INTERNALS //
    // --------- //

    /// @dev Whether quota params for token are initialized
    function isInitialised(TokenQuotaParams storage tokenQuotaParams) internal view returns (bool) {
        return tokenQuotaParams.cumulativeIndexLU != 0;
    }

    /// @dev Efficiently loads quota params of a token from storage
    function _getTokenQuotaParamsOrRevert(TokenQuotaParams storage tokenQuotaParams)
        internal
        view
        returns (uint16 rate, uint192 cumulativeIndexLU, uint16 quotaIncreaseFee)
    {
        // rate = tokenQuotaParams.rate;
        // cumulativeIndexLU = tokenQuotaParams.cumulativeIndexLU;
        // quotaIncreaseFee = tokenQuotaParams.quotaIncreaseFee;
        assembly {
            let data := sload(tokenQuotaParams.slot)
            rate := and(data, 0xFFFF)
            cumulativeIndexLU := and(shr(16, data), 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
            quotaIncreaseFee := shr(208, data)
        }

        if (cumulativeIndexLU == 0) {
            revert TokenIsNotQuotedException(); // U:[PQK-14]
        }
    }

    /// @dev Efficiently loads quota and limit of a token from storage
    function _getTokenQuotaTotalAndLimit(TokenQuotaParams storage tokenQuotaParams)
        internal
        view
        returns (uint96 totalQuoted, uint96 limit)
    {
        // totalQuoted = tokenQuotaParams.totalQuoted;
        // limit = tokenQuotaParams.limit;
        assembly {
            let data := sload(add(tokenQuotaParams.slot, 1))
            totalQuoted := and(data, 0xFFFFFFFFFFFFFFFFFFFFFFFF)
            limit := shr(96, data)
        }
    }

    /// @dev Reverts if `msg.sender` is not an allowed credit manager
    function _revertIfCallerNotCreditManager() internal view {
        if (!creditManagerSet.contains(msg.sender)) {
            revert CallerNotCreditManagerException(); // U:[PQK-4]
        }
    }

    /// @dev Reverts if `msg.sender` is not gauge
    function _revertIfCallerNotGauge() internal view {
        if (msg.sender != gauge) revert CallerNotGaugeException(); // U:[PQK-3]
    }
}
