// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
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

/// @title Pool quota keeper
/// @dev The PQK works as an intermediary between the Credit Manager and the pool with regards to quotas and quota interest.
///      The PQK stores all of the quotas and related parameters, and computes and updates the quota revenue value used by
///      the pool to include quota interest in its liquidity.
/// @dev Account quotas are user-set values that limit the exposure of an account to a particular asset. The USD value of an asset
///      counted towards account's collateral cannot exceed the USD calue of the respective quota. Users pay interest on their quotas,
///      both as an anti-spam measure and a way to price-discriminate based on asset's risk
contract PoolQuotaKeeperV3 is IPoolQuotaKeeperV3, ACLNonReentrantTrait, ContractsRegisterTrait {
    using EnumerableSet for EnumerableSet.AddressSet;
    using QuotasLogic for TokenQuotaParams;

    /// @notice Address of the underlying token
    address public immutable underlying;

    /// @notice Address of the liquidity pool
    address public immutable override pool;

    /// @notice The list of all connected Credit Managers
    EnumerableSet.AddressSet internal creditManagerSet;

    /// @notice The list of all quoted tokens
    EnumerableSet.AddressSet internal quotaTokensSet;

    /// @notice Mapping from token address to global per-token params
    mapping(address => TokenQuotaParams) public totalQuotaParams;

    /// @notice Mapping from creditAccount => token => per-account quota params
    mapping(address => mapping(address => AccountQuota)) internal accountQuotas;

    /// @notice Address of the Gauge
    address public gauge;

    /// @notice Timestamp of the last time quota rates were batch-updated
    uint40 public lastQuotaRateUpdate;

    /// @notice Contract version
    uint256 public constant override version = 3_00;

    /// @dev Reverts if the function is called by non-gauge
    modifier gaugeOnly() {
        _revertIfCallerNotGauge(); // F:[PQK-3]
        _;
    }

    /// @dev Reverts if the function is called by non-Credit Manager
    modifier creditManagerOnly() {
        _revertIfCallerNotCreditManager();
        _;
    }

    //
    // CONSTRUCTOR
    //

    /// @dev Constructor
    /// @param _pool Pool address
    constructor(address _pool)
        ACLNonReentrantTrait(IPoolV3(_pool).addressProvider())
        ContractsRegisterTrait(IPoolV3(_pool).addressProvider())
    {
        pool = _pool; // U:[PQK-1]
        underlying = IPoolV3(_pool).asset(); // U:[PQK-1]
    }

    /// @notice Updates a Credit Account's quota amount for a token
    /// @param creditAccount Address of credit account
    /// @param token Address of the token
    /// @param quotaChange Signed quota change amount
    /// @param minQuota Minimum deisred quota amount
    /// @return caQuotaInterestChange Accrued quota interest since last interest update.
    ///                               It is expected that this value is stored/used by the caller,
    ///                               as PQK will update the interest index, which will set local accrued interest to 0
    /// @return tradingFees Trading fees computed during increasing quota
    /// @return realQuotaChange Actual quota change. Can be lower than requested on quota increase, it total quotas are
    ///                         at capacity.
    /// @return enableToken Whether the token needs to be enabled
    /// @return disableToken Whether the token needs to be disabled
    function updateQuota(address creditAccount, address token, int96 quotaChange, uint96 minQuota, uint96 maxQuota)
        external
        override
        creditManagerOnly // U:[PQK-4]
        returns (
            uint128 caQuotaInterestChange,
            uint128 tradingFees,
            int96 realQuotaChange,
            bool enableToken,
            bool disableToken
        )
    {
        AccountQuota storage accountQuota = accountQuotas[creditAccount][token];
        TokenQuotaParams storage tokenQuotaParams = totalQuotaParams[token];

        uint96 quoted = accountQuota.quota;

        (uint16 rate, uint192 tqCumulativeIndexLU, uint16 quotaIncreaseFee) =
            _getTokenQuotaParamsOrRevert(tokenQuotaParams);

        uint192 cumulativeIndexNow = QuotasLogic.cumulativeIndexSince(tqCumulativeIndexLU, rate, lastQuotaRateUpdate);

        {
            // FOR ANY CHANGE: Computes the accrued quota interest since last update and the new index,
            // Since interest is computed dynamically as a multiplier of current quota amount,
            // the outstanding interest has to be cached beforehand to avoid interest also being
            // changed with the amount. The cached interest is stored in the CM, so the outstanding interest
            // value is returned there, while the cumulative index is written to account's
            // cumulativeIndexLU to set local quota interest to zero

            caQuotaInterestChange =
                QuotasLogic.calcAccruedQuotaInterest(quoted, cumulativeIndexNow, accountQuota.cumulativeIndexLU); // U: [PQK-15]
        }

        uint96 newQuoted;

        realQuotaChange = quotaChange;

        if (realQuotaChange > 0) {
            // INCREASE

            (uint96 totalQuoted, uint96 limit) = _getTokenQuotaTotalAndLimit(tokenQuotaParams);

            // Computes the current capacity until quota limit and checks the amount against it
            // If the requested increase amount is above capacity, only the remaining capacity will
            // be provided as a quota
            realQuotaChange = QuotasLogic.calcRealQuotaIncreaseChange(totalQuoted, limit, realQuotaChange); // U: [PQK-15]

            // If applicable, trading fees are computed on the quota increase amount and
            // added to accrued fees in the CM
            // For some tokens, a one-time quota increase fee may be charged. This is a proxy for
            // trading fees for tokens with high volume but short position duration, in which
            // case trading fees are a more effective pricing policy than charging interest over time
            tradingFees = uint128(uint96(realQuotaChange)) * quotaIncreaseFee / PERCENTAGE_FACTOR; // U: [PQK-15]

            // Quoted tokens are only enabled in the CM when their quotas are changed
            // from zero to non-zero. This is done to correctly
            // update quotas on closing the account - if a token ends up disabled while having a non-zero quota,
            // the CM will fail to zero it on closing an account, which will break quota interest computations.
            // This value is returned in order for Credit Manager to update enabled tokens locally.
            if (quoted <= 1) {
                enableToken = true; // U: [PQK-15]
            }

            // Increases the account quota and total quota by the amount (or remaining capacity, if the amount exceeds it)
            newQuoted = quoted + uint96(realQuotaChange);

            tokenQuotaParams.totalQuoted = totalQuoted + uint96(realQuotaChange); // U: [PQK-15]
        } else {
            /// DECREASE
            /// Decreases the account quota and total quota by the amount

            newQuoted = quoted - uint96(-realQuotaChange);
            tokenQuotaParams.totalQuoted -= uint96(-realQuotaChange); // U: [PQK-15]

            /// Computes whether the token should be disabled (quota changed from non-zero to zero)
            if (newQuoted <= 1) {
                disableToken = true; // U: [PQK-15]
            }
        }

        // Checks that quota is in desired boudnaries
        if (newQuoted < minQuota || newQuoted > maxQuota) revert QuotaIsOutOfBoundsException(); // U: [PQK-15]

        // The cumulative index is updated to current in order to zero local interest
        accountQuota.quota = newQuoted; // U: [PQK-15]
        accountQuota.cumulativeIndexLU = cumulativeIndexNow; // U: [PQK-15]

        // Computes the total quota revenue change
        int256 quotaRevenueChange = QuotasLogic.calcQuotaRevenueChange(rate, int256(realQuotaChange)); // U: [PQK-15]

        // Quota revenue must be changed on each quota update, so that the
        // pool can correctly compute its liquidity metrics in the future
        if (quotaRevenueChange != 0) {
            IPoolV3(pool).updateQuotaRevenue(quotaRevenueChange); // U: [PQK-15]
        }
    }

    /// @notice Updates all Credit Account quotas to zero
    /// @param creditAccount Address of the Credit Account to remove quotas from
    /// @param tokens Array of all active quoted tokens on the account
    /// @param setLimitsToZero Whether limits for affected tokens should be set to zero
    function removeQuotas(address creditAccount, address[] calldata tokens, bool setLimitsToZero)
        external
        override
        creditManagerOnly // U:[PQK-4]
    {
        int256 quotaRevenueChange;

        uint256 len = tokens.length;

        for (uint256 i; i < len;) {
            address token = tokens[i];
            if (token == address(0)) break; // U: [PQK-16]

            AccountQuota storage accountQuota = accountQuotas[creditAccount][token];
            TokenQuotaParams storage tokenQuotaParams = totalQuotaParams[token];

            uint96 quoted = accountQuota.quota;

            if (quoted > 1) {
                quoted--;

                uint16 rate = tokenQuotaParams.rate;
                uint96 totalQuoted = tokenQuotaParams.totalQuoted;

                /// Computes quota revenue change
                quotaRevenueChange += QuotasLogic.calcQuotaRevenueChange(rate, -int256(uint256(quoted))); // U: [PQK-16]

                /// Decreases the total token quota by the account's quota
                tokenQuotaParams.totalQuoted = totalQuoted - quoted; // U: [PQK-16]
            }

            // Sets account quota to zero
            if (quoted != 0) {
                accountQuota.quota = 1; // U: [PQK-16]
            }

            // Unlike general quota updates, quota removals do not update accountQuota.cumulativeIndexLU to save gas (i.e., do not accrue interest)
            // This is safe, since the quota is set to 1 and the index will be updated to the correct value on next change from
            // zero to non-zero, without breaking any interest calculations.

            /// On some critical triggers (such as account liquidating with a loss), the Credit Manager
            /// may request the PQK to set quota limits to 0, effectively preventing any further exposure
            /// to the token until the limit is raised again
            if (setLimitsToZero) {
                _setTokenLimit({tokenQuotaParams: tokenQuotaParams, token: token, limit: 1}); // U: [PQK-16]
            }

            unchecked {
                ++i;
            }
        }

        if (quotaRevenueChange != 0) {
            IPoolV3(pool).updateQuotaRevenue(quotaRevenueChange); // U: [PQK-16]
        }
    }

    /// @notice Updates interest indexes for all Credit Account's quotas to current index
    /// @dev This effectively sets accrued interest to 0 locally - the function assumes
    ///      that the calling Credit Manager has computed and stored pending interest
    ///      beforehand
    /// @param creditAccount Address of the Credit Account to accrue interest for
    /// @param tokens Array of all active quoted tokens on the account
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
                if (token == address(0)) break;

                AccountQuota storage accountQuota = accountQuotas[creditAccount][token];
                TokenQuotaParams storage tokenQuotaParams = totalQuotaParams[token];

                (uint16 rate, uint192 tqCumulativeIndexLU,) = _getTokenQuotaParamsOrRevert(tokenQuotaParams); // U: [PQK-17]

                accountQuota.cumulativeIndexLU =
                    QuotasLogic.cumulativeIndexSince(tqCumulativeIndexLU, rate, lastQuotaRateUpdate_); // U: [PQK-17]
            }
        }
    }

    //
    // GETTERS
    //

    /// @notice Returns the account's quota and accrued interest since last update
    /// @param creditAccount Credit Account to compute values for
    /// @param token Token to compute values for
    /// @return quoted Account's quota amount
    /// @return outstandingInterest Interest accrued since last interest update
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

        outstandingInterest = QuotasLogic.calcAccruedQuotaInterest(quoted, cumulativeIndexNow, aqCumulativeIndexLU); // U: [PQK-15]
    }

    /// @notice Returns current interest index in RAY for a quoted token. Returns 0 for non-quoted tokens.
    function cumulativeIndex(address token) public view override returns (uint192) {
        TokenQuotaParams storage tokenQuotaParams = totalQuotaParams[token];
        (uint16 rate, uint192 tqCumulativeIndexLU,) = _getTokenQuotaParamsOrRevert(tokenQuotaParams);

        return QuotasLogic.cumulativeIndexSince(tqCumulativeIndexLU, rate, lastQuotaRateUpdate);
    }

    /// @notice Returns quota interest rate for a token in PERCENTAGE FORMAT
    function getQuotaRate(address token) external view override returns (uint16) {
        return totalQuotaParams[token].rate;
    }

    /// @notice Returns an array of all quoted tokens
    function quotedTokens() external view override returns (address[] memory) {
        return quotaTokensSet.values();
    }

    /// @notice Returns whether a token is quoted
    function isQuotedToken(address token) external view override returns (bool) {
        return quotaTokensSet.contains(token);
    }

    /// @notice Returns quota parameters for a single (account, token) pair
    function getQuota(address creditAccount, address token)
        external
        view
        returns (uint96 quota, uint192 cumulativeIndexLU)
    {
        AccountQuota storage aq = accountQuotas[creditAccount][token];
        return (aq.quota, aq.cumulativeIndexLU);
    }

    /// @notice Returns list of connected credit managers
    function creditManagers() external view returns (address[] memory) {
        return creditManagerSet.values(); // F:[PQK-10]
    }

    //
    // GAUGE-ONLY FUNCTIONS
    //

    /// @notice Registers a new quoted token
    /// @param token Address of the token
    function addQuotaToken(address token)
        external
        gaugeOnly // U:[PQK-3]
    {
        if (quotaTokensSet.contains(token)) {
            revert TokenAlreadyAddedException(); // U:[PQK-6]
        }

        /// The interest rate is not set immediately on adding a quoted token,
        /// since all rates are updated during a general epoch update in the Gauge
        quotaTokensSet.add(token); // U:[PQK-5]
        totalQuotaParams[token].cumulativeIndexLU = uint192(RAY); // U:[PQK-5]

        emit NewQuotaTokenAdded(token); // U:[PQK-5]
    }

    /// @notice Batch updates the quota rates and changes the combined quota revenue
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

            /// Before writing a new rate, the token's interest index current value is also
            /// saved, to ensure that further calculations with the new rates are correct
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

    //
    // CONFIGURATION
    //

    /// @notice Sets a new gauge contract to compute quota rates
    /// @param _gauge The new contract's address
    function setGauge(address _gauge)
        external
        configuratorOnly // U:[PQK-2]
    {
        if (gauge != _gauge) {
            gauge = _gauge; // U:[PQK-8]
            lastQuotaRateUpdate = uint40(block.timestamp); // U:[PQK-8]
            emit SetGauge(_gauge); // U:[PQK-8]
        }
    }

    /// @notice Adds a new Credit Manager to the set of allowed CM's
    /// @param _creditManager Address of the new Credit Manager
    function addCreditManager(address _creditManager)
        external
        configuratorOnly // U:[PQK-2]
        nonZeroAddress(_creditManager)
        registeredCreditManagerOnly(_creditManager) // U:[PQK-9]
    {
        if (ICreditManagerV3(_creditManager).pool() != pool) {
            revert IncompatibleCreditManagerException(); // U:[PQK-9]
        }

        /// Checks if creditManager is already in list
        if (!creditManagerSet.contains(_creditManager)) {
            creditManagerSet.add(_creditManager); // U:[PQK-10]
            emit AddCreditManager(_creditManager); // U:[PQK-10]
        }
    }

    /// @notice Sets an upper limit for total quotas across all accounts for a token
    /// @param token Address of token to set the limit for
    /// @param limit The limit to set
    function setTokenLimit(address token, uint96 limit)
        external
        controllerOnly // U:[PQK-2]
    {
        TokenQuotaParams storage tokenQuotaParams = totalQuotaParams[token];
        _setTokenLimit(tokenQuotaParams, token, limit);
    }

    /// @dev IMPLEMENTATION: setTokenLimit
    function _setTokenLimit(TokenQuotaParams storage tokenQuotaParams, address token, uint96 limit) internal {
        // setLimit checks that token is initialize, otherwise it reverts
        // F:[PQK-11]

        if (!isInitialised(tokenQuotaParams)) {
            revert TokenIsNotQuotedException(); // F:[PQK-11]
        }

        if (tokenQuotaParams.limit != limit) {
            tokenQuotaParams.limit = limit; // U:[PQK-12]
            emit SetTokenLimit(token, limit); // U:[PQK-12]
        }
    }

    /// @notice Sets the one-time fee paid on each quota increase
    /// @param token Token to set the fee for
    /// @param fee The new fee value in PERCENTAGE_FACTOR format
    function setTokenQuotaIncreaseFee(address token, uint16 fee)
        external
        controllerOnly // U:[PQK-2]
    {
        TokenQuotaParams storage tokenQuotaParams = totalQuotaParams[token]; // U:[PQK-13]

        if (!isInitialised(tokenQuotaParams)) {
            revert TokenIsNotQuotedException();
        }

        if (tokenQuotaParams.quotaIncreaseFee != fee) {
            tokenQuotaParams.quotaIncreaseFee = fee; // U:[PQK-13]
            emit SetQuotaIncreaseFee(token, fee); // U:[PQK-13]
        }
    }

    //
    // STORAGE ACCESS OPTIMISATION
    //

    /// @dev Returns whether the quoted token data is initialized
    /// @dev Since for initialized quoted token the interest index starts at RAY,
    ///      it is sufficient to check that it is not equal to 0
    function isInitialised(TokenQuotaParams storage tokenQuotaParams) internal view returns (bool) {
        return tokenQuotaParams.cumulativeIndexLU != 0;
    }

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
            revert TokenIsNotQuotedException(); // U: [PQK-14]
        }
    }

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

    //
    // ACCESS
    //
    function _revertIfCallerNotCreditManager() internal view {
        if (!creditManagerSet.contains(msg.sender)) {
            revert CallerNotCreditManagerException(); // F:[PQK-4]
        }
    }

    function _revertIfCallerNotGauge() internal view {
        if (msg.sender != gauge) revert CallerNotGaugeException(); // F:[PQK-3]
    }
}
