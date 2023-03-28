// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {AddressProvider} from "@gearbox-protocol/core-v2/contracts/core/AddressProvider.sol";
import {ContractsRegister} from "@gearbox-protocol/core-v2/contracts/core/ContractsRegister.sol";
import {IPriceOracleV2} from "@gearbox-protocol/core-v2/contracts/interfaces/IPriceOracle.sol";

import {ACLNonReentrantTrait} from "../core/ACLNonReentrantTrait.sol";

import {Quotas} from "../libraries/Quotas.sol";

import {IPool4626} from "../interfaces/IPool4626.sol";
import {
    IPoolQuotaKeeper, QuotaUpdate, TokenLT, TokenQuotaParams, AccountQuota
} from "../interfaces/IPoolQuotaKeeper.sol";
import {IGauge} from "../interfaces/IGauge.sol";
import {ICreditManagerV2} from "../interfaces/ICreditManagerV2.sol";

import {RAY, SECONDS_PER_YEAR, MAX_WITHDRAW_FEE} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/PercentageMath.sol";

// EXCEPTIONS
import {
    ZeroAddressException,
    CreditManagerNotRegsiterException,
    CallerNotCreditManagerException,
    TokenAlreadyAddedException,
    TokenNotAllowedException
} from "../interfaces/IErrors.sol";

import "forge-std/console.sol";

uint192 constant RAY_DIVIDED_BY_PERCENTAGE = uint192(RAY / PERCENTAGE_FACTOR);

/// @title Manage pool accountQuotas
contract PoolQuotaKeeper is IPoolQuotaKeeper, ACLNonReentrantTrait {
    using EnumerableSet for EnumerableSet.AddressSet;
    using Quotas for TokenQuotaParams;

    /// @dev Address provider
    address public immutable underlying;

    /// @dev Address of the protocol treasury
    IPool4626 public immutable override pool;

    /// @dev The list of all Credit Managers
    EnumerableSet.AddressSet internal creditManagerSet;

    /// @dev The list of all Credit Managers
    EnumerableSet.AddressSet internal quotaTokensSet;

    /// @dev Mapping from token address to its respective quota parameters
    mapping(address => TokenQuotaParams) public totalQuotaParams;

    /// @dev Mapping from (user, token) to per-account quota parameters
    mapping(address => mapping(address => mapping(address => AccountQuota))) internal accountQuotas;

    /// @dev Mapping for cached token masks
    mapping(address => mapping(address => uint256)) internal tokenMaskCached;

    /// @dev Address of the gauge that determines quota rates
    address public gauge;

    /// @dev Timestamp of the last time quota rates were batch-updated
    uint40 public lastQuotaRateUpdate;

    /// @dev Contract version
    uint256 public constant override version = 3_00;

    /// @dev Reverts if the function is called by non-gauge
    modifier gaugeOnly() {
        if (msg.sender != gauge) revert GaugeOnlyException(); // F:[PQK-3]
        _;
    }

    /// @dev Reverts if the function is called by non-Credit Manager
    modifier creditManagerOnly() {
        if (!creditManagerSet.contains(msg.sender)) {
            revert CallerNotCreditManagerException(); // F:[PQK-4]
        }
        _;
    }

    //
    // CONSTRUCTOR
    //

    /// @dev Constructor
    /// @param _pool Pool address
    constructor(address _pool) ACLNonReentrantTrait(address(IPool4626(_pool).addressProvider())) {
        pool = IPool4626(_pool); // F:[PQK-1]
        underlying = IPool4626(_pool).asset(); // F:[PQK-1]
    }

    /// @dev Updates credit account's accountQuotas for multiple tokens
    /// @param creditAccount Address of credit account
    /// @param quotaUpdates Requested quota updates, see `QuotaUpdate`
    function updateQuotas(address creditAccount, QuotaUpdate[] memory quotaUpdates, uint256 enableTokenMask)
        external
        override
        creditManagerOnly // F:[PQK-4]
        returns (uint256 caQuotaInterestChange, uint256 enableTokenMaskUpdated)
    {
        enableTokenMaskUpdated = enableTokenMask;
        uint256 len = quotaUpdates.length;
        int128 quotaRevenueChange;
        int128 qic;
        uint256 cap;

        for (uint256 i; i < len;) {
            (qic, cap, enableTokenMaskUpdated) = _updateQuota(
                msg.sender, creditAccount, quotaUpdates[i].token, quotaUpdates[i].quotaChange, enableTokenMaskUpdated
            ); // F:[CMQ-03]

            quotaRevenueChange += qic;
            caQuotaInterestChange += cap;

            unchecked {
                ++i;
            }
        }

        if (quotaRevenueChange != 0) {
            pool.changeQuotaRevenue(quotaRevenueChange);
        }
    }

    function getTokenMask(address creditManager, address token) internal returns (uint256 mask) {
        mask = tokenMaskCached[creditManager][token];
        if (mask == 0) {
            mask = ICreditManagerV2(creditManager).tokenMasksMap(token);
            if (mask == 0) revert TokenNotAllowedException();
            tokenMaskCached[creditManager][token] = mask;
        }
    }

    /// @dev Updates all accountQuotas to zero when closing a credit account, and computes the final quota interest change
    /// @param creditAccount Address of the Credit Account being closed
    /// @param tokensLT Array of all active quoted tokens on the account
    function closeCreditAccount(address creditAccount, TokenLT[] memory tokensLT)
        external
        override
        creditManagerOnly // F:[PQK-4]
        returns (uint256 totalInterest)
    {
        int128 quotaRevenueChange;

        uint256 len = tokensLT.length;
        for (uint256 i; i < len;) {
            address token = tokensLT[i].token;

            (int128 qic, uint256 caqi) = _removeQuota(msg.sender, creditAccount, token); // F:[CMQ-06]

            quotaRevenueChange += qic; // F:[CMQ-06]
            totalInterest += caqi; // F:[CMQ-06]
            unchecked {
                ++i;
            }
        }

        /// TODO: check side effect of updating expectedLiquidity
        pool.changeQuotaRevenue(quotaRevenueChange);
    }

    /// @dev Update function for a single quoted token
    function _updateQuota(
        address creditManager,
        address creditAccount,
        address token,
        int96 quotaChange,
        uint256 enableTokenMask
    ) internal returns (int128 quotaRevenueChange, uint256 caQuotaInterestChange, uint256 enableTokenMaskUpdated) {
        TokenQuotaParams storage tq = totalQuotaParams[token];

        if (!tq.isTokenRegistered()) {
            revert TokenIsNotQuotedException();
        }

        enableTokenMaskUpdated = enableTokenMask;

        AccountQuota storage accountQuota = accountQuotas[creditManager][creditAccount][token];

        uint96 quoted = accountQuota.quota;

        caQuotaInterestChange = _updateAccountQuota(tq, accountQuota, quoted);

        uint96 change;
        if (quotaChange > 0) {
            uint96 maxQuotaAllowed = tq.limit - tq.totalQuoted;

            if (maxQuotaAllowed == 0) {
                return (0, caQuotaInterestChange, enableTokenMaskUpdated);
            }

            change = uint96(quotaChange);
            change = change > maxQuotaAllowed ? maxQuotaAllowed : change; // F:[CMQ-08,10]

            // if quota was 0 and change > 0, we enable token
            if (quoted <= 1) {
                enableTokenMaskUpdated |= getTokenMask(creditManager, token);
            }

            accountQuota.quota += change;
            tq.totalQuoted += change;

            quotaRevenueChange = int128(int16(tq.rate)) * int96(change);
        } else {
            change = uint96(-quotaChange);

            tq.totalQuoted -= change;
            accountQuota.quota -= change; // F:[CMQ-03]

            if (accountQuota.quota <= 1) {
                enableTokenMaskUpdated &= ~getTokenMask(creditManager, token); // F:[CMQ-03]
            }

            quotaRevenueChange = -int128(int16(tq.rate)) * int96(change);
        }
    }

    /// @dev Internal function to zero the quota for a single quoted token
    function _removeQuota(address creditManager, address creditAccount, address token)
        internal
        returns (int128 quotaRevenueChange, uint256 caQuotaInterestChange)
    {
        AccountQuota storage accountQuota = accountQuotas[creditManager][creditAccount][token];
        uint96 quoted = accountQuota.quota;

        if (quoted <= 1) return (0, 0);

        TokenQuotaParams storage tq = totalQuotaParams[token];

        caQuotaInterestChange = _updateAccountQuota(tq, accountQuota, quoted); // F:[CMQ-06]
        accountQuota.quota = 1; // F:[CMQ-06]

        tq.totalQuoted -= quoted;

        return (-int128(uint128(quoted)) * int16(tq.rate), caQuotaInterestChange); // F:[CMQ-06]
    }

    function _updateAccountQuota(TokenQuotaParams storage tq, AccountQuota storage accountQuota, uint96 quoted)
        internal
        returns (uint256 caQuotaInterestChange)
    {
        uint192 cumulativeIndexNow = _cumulativeIndexNow(tq); // F:[CMQ-03]

        if (quoted > 1) {
            caQuotaInterestChange =
                _computeOutstandingQuotaInterest(quoted, cumulativeIndexNow, accountQuota.cumulativeIndexLU); // F:[CMQ-03]
        }

        accountQuota.cumulativeIndexLU = cumulativeIndexNow;
    }

    /// @dev Computes the accrued quota interest and updates interest indexes
    /// @param creditAccount Address of the Credit Account to accrue interest for
    /// @param tokensLT Array of all active quoted tokens on the account
    function accrueQuotaInterest(address creditAccount, TokenLT[] memory tokensLT)
        external
        override
        creditManagerOnly // F:[PQK-4]
        returns (uint256 caQuotaInterestChange)
    {
        uint256 len = tokensLT.length;

        for (uint256 i; i < len;) {
            address token = tokensLT[i].token;
            AccountQuota storage accountQuota = accountQuotas[msg.sender][creditAccount][token];

            uint96 quoted = accountQuota.quota;
            if (quoted > 1) {
                TokenQuotaParams storage tq = totalQuotaParams[token];
                caQuotaInterestChange += _updateAccountQuota(tq, accountQuota, quoted);
            }
            unchecked {
                ++i;
            }
        }
    }

    //
    // GETTERS
    //

    /// @dev Computes outstanding quota interest
    function outstandingQuotaInterest(address creditManager, address creditAccount, TokenLT[] memory tokensLT)
        external
        view
        override
        returns (uint256 caQuotaInterestChange)
    {
        uint256 len = tokensLT.length;

        for (uint256 i; i < len;) {
            address token = tokensLT[i].token;
            AccountQuota storage q = accountQuotas[creditManager][creditAccount][token];

            uint96 quoted = q.quota;
            if (quoted > 1) {
                TokenQuotaParams storage tq = totalQuotaParams[token];
                uint192 cumulativeIndexNow = _cumulativeIndexNow(tq);
                caQuotaInterestChange +=
                    _computeOutstandingQuotaInterest(quoted, cumulativeIndexNow, q.cumulativeIndexLU); // F:[CMQ-10]
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Internal function for outstanding quota interest computation
    function _computeOutstandingQuotaInterest(uint96 quoted, uint192 cumulativeIndexNow, uint192 cumulativeIndexLU)
        internal
        pure
        returns (uint256)
    {
        return (quoted * cumulativeIndexNow) / cumulativeIndexLU - quoted;
    }

    /// @dev Computes collateral value for quoted tokens on the account, as well as accrued quota interest
    function computeQuotedCollateralUSD(
        address creditManager,
        address creditAccount,
        address _priceOracle,
        TokenLT[] memory tokens
    ) external view override returns (uint256 value, uint256 totalQuotaInterest) {
        uint256 i;

        uint256 len = tokens.length;
        while (i < len && tokens[i].token != address(0)) {
            (uint256 currentUSD, uint256 outstandingInterest) =
                _getCollateralValue(creditManager, creditAccount, tokens[i].token, _priceOracle); // F:[CMQ-8]

            value += currentUSD * tokens[i].lt; // F:[CMQ-8]
            totalQuotaInterest += outstandingInterest; // F:[CMQ-8]

            unchecked {
                ++i;
            }
        }
    }

    /// @dev Gets the effective value (i.e., value in underlying included into TWV) for a quoted token on an account
    function _getCollateralValue(address creditManager, address creditAccount, address token, address _priceOracle)
        internal
        view
        returns (uint256 value, uint256 interest)
    {
        AccountQuota storage q = accountQuotas[creditManager][creditAccount][token];

        uint96 quoted = q.quota;

        if (quoted > 1) {
            uint256 quotaValueUSD = IPriceOracleV2(_priceOracle).convertToUSD(quoted, underlying); // F:[CMQ-8]
            uint256 balance = IERC20(token).balanceOf(creditAccount);
            if (balance > 1) {
                value = IPriceOracleV2(_priceOracle).convertToUSD(balance, token); // F:[CMQ-8]
                if (value > quotaValueUSD) value = quotaValueUSD; // F:[CMQ-8]
            }

            interest = _computeOutstandingQuotaInterest(quoted, cumulativeIndex(token), q.cumulativeIndexLU); // F:[CMQ-8]
        }
    }

    /// @dev Returns cumulative index in RAY for a quoted token. Returns 0 for non-quoted tokens.
    function cumulativeIndex(address token) public view override returns (uint192) {
        return _cumulativeIndexNow(totalQuotaParams[token]);
    }

    function _cumulativeIndexNow(TokenQuotaParams storage tq) internal view returns (uint192) {
        return tq.cumulativeIndexSince(lastQuotaRateUpdate);
    }

    /// @dev Returns quota rate in PERCENTAGE FORMAT
    function getQuotaRate(address token) external view override returns (uint16) {
        return totalQuotaParams[token].rate;
    }

    /// @dev Returns an array of all quoted tokens
    function quotedTokens() external view override returns (address[] memory) {
        return quotaTokensSet.values();
    }

    /// @dev Returns whether a token is quoted
    function isQuotedToken(address token) external view override returns (bool) {
        return quotaTokensSet.contains(token);
    }

    /// @dev Returns quota parameters for a single (account, token) pair
    function getQuota(address creditManager, address creditAccount, address token)
        external
        view
        returns (AccountQuota memory)
    {
        return accountQuotas[creditManager][creditAccount][token];
    }

    //
    // ASSET MANAGEMENT (VIA GAUGE)
    //

    /// @dev Batch updates the quota rates and changes the combined quota revenue
    /// @param qUpdates Array of new rates for all quoted tokens

    /// @dev Registers a new quoted token in the keeper
    function addQuotaToken(address token)
        external
        gaugeOnly // F:[PQK-3]
    {
        if (quotaTokensSet.contains(token)) {
            revert TokenAlreadyAddedException(); // F:[PQK-6]
        }

        quotaTokensSet.add(token); // F:[PQK-5]

        TokenQuotaParams storage qp = totalQuotaParams[token]; // F:[PQK-5]
        qp.cumulativeIndexLU_RAY = uint192(RAY); // F:[PQK-5]

        emit NewQuotaTokenAdded(token); // F:[PQK-5]
    }

    function updateRates()
        external
        override
        gaugeOnly // F:[PQK-3]
    {
        address[] memory tokens = quotaTokensSet.values();
        uint16[] memory rates = IGauge(gauge).getRates(tokens); // F:[PQK-7]

        uint256 timeFromLastUpdate = block.timestamp - lastQuotaRateUpdate;
        uint128 quotaRevenue;

        uint256 len = tokens.length;
        for (uint256 i; i < len;) {
            address token = tokens[i];
            uint16 rate = rates[i];

            TokenQuotaParams storage tq = totalQuotaParams[token];

            tq.cumulativeIndexLU_RAY = tq.calcLinearCumulativeIndex(rate, timeFromLastUpdate); // F:[PQK-7]
            tq.rate = rate; // F:[PQK-7]

            quotaRevenue += rate * tq.totalQuoted;
            emit QuotaRateUpdated(token, rate); // F:[PQK-7]

            unchecked {
                ++i;
            }
        }
        pool.updateQuotaRevenue(quotaRevenue);
        lastQuotaRateUpdate = uint40(block.timestamp);
    }

    //
    // CONFIGURATION
    //

    /// @dev Sets a new gauge contract to compute quota rates
    /// @param _gauge The new contract's address
    function setGauge(address _gauge)
        external
        configuratorOnly // F:[PQK-2]
    {
        if (gauge != _gauge) {
            gauge = _gauge;
            lastQuotaRateUpdate = uint40(block.timestamp);
            emit GaugeUpdated(_gauge);
        }
    }

    /// @dev Adds a new Credit Manager to the set of allowed CM's
    /// @param _creditManager Address of the new Credit Manager
    function addCreditManager(address _creditManager)
        external
        configuratorOnly // F:[PQK-2]
        nonZeroAddress(_creditManager)
    {
        if (
            !ContractsRegister(AddressProvider(pool.addressProvider()).getContractsRegister()).isCreditManager(
                _creditManager
            )
        ) {
            revert CreditManagerNotRegsiterException(); // F:[P4-19]
        }

        /// Checks if creditManager is already in list
        if (!creditManagerSet.contains(_creditManager)) {
            creditManagerSet.add(_creditManager); //
            emit CreditManagerAdded(_creditManager);
        }
    }

    /// @dev Sets an upper limit on accountQuotas for a token
    /// @param token Address of token to set the limit for
    /// @param limit The limit to set
    function setTokenLimit(address token, uint96 limit)
        external
        controllerOnly // F:[PQK-2]
    {
        if (totalQuotaParams[token].limit != limit) {
            totalQuotaParams[token].limit = limit;
            emit TokenLimitSet(token, limit);
        }
    }
}
