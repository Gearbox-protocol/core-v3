// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {AddressProvider} from "@gearbox-protocol/core-v2/contracts/core/AddressProvider.sol";
import {IPriceOracleV2} from "@gearbox-protocol/core-v2/contracts/interfaces/IPriceOracle.sol";

/// LIBS & TRAITS
import {ACLNonReentrantTrait} from "../traits/ACLNonReentrantTrait.sol";
import {ContractsRegisterTrait} from "../traits/ContractsRegisterTrait.sol";
import {CreditLogic} from "../libraries/CreditLogic.sol";

import {QuotasLogic} from "../libraries/QuotasLogic.sol";

import {IPool4626} from "../interfaces/IPool4626.sol";
import {IPoolQuotaKeeper, TokenQuotaParams, AccountQuota} from "../interfaces/IPoolQuotaKeeper.sol";
import {IGauge} from "../interfaces/IGauge.sol";
import {ICreditManagerV3} from "../interfaces/ICreditManagerV3.sol";

import {RAY, SECONDS_PER_YEAR, MAX_WITHDRAW_FEE} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/PercentageMath.sol";

// EXCEPTIONS
import "../interfaces/IExceptions.sol";

import "forge-std/console.sol";

uint192 constant RAY_DIVIDED_BY_PERCENTAGE = uint192(RAY / PERCENTAGE_FACTOR);

/// @title Manage pool accountQuotas
contract PoolQuotaKeeper is IPoolQuotaKeeper, ACLNonReentrantTrait, ContractsRegisterTrait {
    using EnumerableSet for EnumerableSet.AddressSet;
    using QuotasLogic for TokenQuotaParams;

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

    /// @dev Mapping from creditAccount => token > quota parameters
    mapping(address => mapping(address => AccountQuota)) internal accountQuotas;

    /// @dev Address of the gauge that determines quota rates
    address public gauge;

    /// @dev Timestamp of the last time quota rates were batch-updated
    uint40 public lastQuotaRateUpdate;

    /// @dev Contract version
    uint256 public constant override version = 3_00;

    /// @dev Reverts if the function is called by non-gauge
    modifier gaugeOnly() {
        if (msg.sender != gauge) revert CallerNotGaugeException(); // F:[PQK-3]
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
    constructor(address _pool)
        ACLNonReentrantTrait(address(IPool4626(_pool).addressProvider()))
        ContractsRegisterTrait(address(IPool4626(_pool).addressProvider()))
    {
        pool = IPool4626(_pool); // F:[PQK-1]
        underlying = IPool4626(_pool).asset(); // F:[PQK-1]
    }

    /// @dev Updates credit account's accountQuotas for multiple tokens
    /// @param creditAccount Address of credit account
    function updateQuota(address creditAccount, address token, int96 quotaChange)
        external
        override
        creditManagerOnly // F:[PQK-4]
        returns (uint256 caQuotaInterestChange, bool enableToken, bool disableToken)
    {
        TokenQuotaParams storage tokenQuotaParams = totalQuotaParams[token];
        AccountQuota storage accountQuota = accountQuotas[creditAccount][token];
        int128 quotaRevenueChange;

        (caQuotaInterestChange, quotaRevenueChange, enableToken, disableToken) = QuotasLogic.changeQuota({
            tokenQuotaParams: tokenQuotaParams,
            accountQuota: accountQuota,
            lastQuotaRateUpdate: lastQuotaRateUpdate,
            quotaChange: quotaChange
        });

        if (quotaRevenueChange != 0) {
            pool.changeQuotaRevenue(quotaRevenueChange);
        }
    }

    /// @dev Updates all accountQuotas to zero when closing a credit account, and computes the final quota interest change
    /// @param creditAccount Address of the Credit Account being closed
    /// @param tokens Array of all active quoted tokens on the account
    function removeQuotas(address creditAccount, address[] memory tokens, bool setLimitsToZero)
        external
        override
        creditManagerOnly // F:[PQK-4]
    {
        int128 quotaRevenueChange;

        uint256 len = tokens.length;

        for (uint256 i; i < len;) {
            address token = tokens[i];
            if (token == address(0)) break;

            AccountQuota storage accountQuota = accountQuotas[creditAccount][token];
            TokenQuotaParams storage tokenQuotaParams = totalQuotaParams[token];

            quotaRevenueChange +=
                QuotasLogic.removeQuota({tokenQuotaParams: tokenQuotaParams, accountQuota: accountQuota}); // F:[CMQ-06]

            if (setLimitsToZero) {
                _setTokenLimit({tokenQuotaParams: tokenQuotaParams, token: token, limit: 1});
            }

            unchecked {
                ++i;
            }
        }

        if (quotaRevenueChange > 0) {
            pool.changeQuotaRevenue(quotaRevenueChange);
        }
    }

    /// @dev Computes the accrued quota interest and updates interest indexes
    /// @param creditAccount Address of the Credit Account to accrue interest for
    /// @param tokens Array of all active quoted tokens on the account
    function accrueQuotaInterest(address creditAccount, address[] memory tokens)
        external
        override
        creditManagerOnly // F:[PQK-4]
        returns (uint256 caQuotaInterestChange)
    {
        uint256 len = tokens.length;

        for (uint256 i; i < len;) {
            address token = tokens[i];
            if (token == address(0)) break;

            caQuotaInterestChange += QuotasLogic.accrueAccountQuotaInterest({
                tokenQuotaParams: totalQuotaParams[token],
                accountQuota: accountQuotas[creditAccount][token],
                lastQuotaRateUpdate: lastQuotaRateUpdate
            });

            unchecked {
                ++i;
            }
        }
    }

    //
    // GETTERS
    //

    /// @dev Computes outstanding quota interest
    function outstandingQuotaInterest(address creditAccount, address[] memory tokens)
        external
        view
        override
        returns (uint256 caQuotaInterestChange)
    {
        uint256 len = tokens.length;
        for (uint256 i; i < len;) {
            address token = tokens[i];
            if (token == address(0)) break;

            caQuotaInterestChange += QuotasLogic.calcOutstandingQuotaInterest({
                tokenQuotaParams: totalQuotaParams[token],
                accountQuota: accountQuotas[creditAccount][token],
                lastQuotaRateUpdate: lastQuotaRateUpdate
            });

            unchecked {
                ++i;
            }
        }
    }

    /// @dev Computes collateral value for quoted tokens on the account, as well as accrued quota interest
    function computeQuotedCollateralUSD(
        address creditAccount,
        address _priceOracle,
        address[] memory tokens,
        uint256[] memory lts
    ) external view override returns (uint256 totalValueUSD, uint256 twvUSD, uint256 totalQuotaInterest) {
        uint256 len = tokens.length;
        for (uint256 i; i < len;) {
            address token = tokens[i];
            if (token == address(0)) break;

            (uint256 currentUSD, uint256 outstandingInterest) = _getCollateralValue(creditAccount, token, _priceOracle); // F:[CMQ-8]

            totalValueUSD += currentUSD;
            twvUSD += currentUSD * lts[i]; // F:[CMQ-8]
            totalQuotaInterest += outstandingInterest; // F:[CMQ-8]

            unchecked {
                ++i;
            }
        }

        twvUSD /= PERCENTAGE_FACTOR;
    }

    /// @dev Gets the effective value (i.e., value in underlying included into TWV) for a quoted token on an account
    function _getCollateralValue(address creditAccount, address token, address _priceOracle)
        internal
        view
        returns (uint256 value, uint256 interest)
    {
        AccountQuota storage accountQuota = accountQuotas[creditAccount][token];

        uint96 quoted = accountQuota.quota;

        if (quoted > 1) {
            uint256 quotaValueUSD = IPriceOracleV2(_priceOracle).convertToUSD(quoted, underlying); // F:[CMQ-8]
            uint256 balance = IERC20(token).balanceOf(creditAccount);
            if (balance > 1) {
                value = IPriceOracleV2(_priceOracle).convertToUSD(balance, token); // F:[CMQ-8]
                if (value > quotaValueUSD) value = quotaValueUSD; // F:[CMQ-8]
            }

            interest = CreditLogic.calcAccruedInterest({
                amount: quoted,
                cumulativeIndexLastUpdate: accountQuota.cumulativeIndexLU,
                cumulativeIndexNow: cumulativeIndex(token)
            }); // F:[CMQ-8]
        }
    }

    /// @dev Returns cumulative index in RAY for a quoted token. Returns 0 for non-quoted tokens.
    function cumulativeIndex(address token) public view override returns (uint192) {
        return totalQuotaParams[token].cumulativeIndexSince(lastQuotaRateUpdate);
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
    function getQuota(address creditAccount, address token) external view returns (AccountQuota memory) {
        return accountQuotas[creditAccount][token];
    }

    /// @dev Returns list of connected credit managers
    function creditManagers() external view returns (address[] memory) {
        return creditManagerSet.values(); // F:[PQK-10]
    }

    //
    // ASSET MANAGEMENT (VIA GAUGE)
    //

    /// @dev Registers a new quoted token in the keeper
    function addQuotaToken(address token)
        external
        gaugeOnly // F:[PQK-3]
    {
        if (quotaTokensSet.contains(token)) {
            revert TokenAlreadyAddedException(); // F:[PQK-6]
        }

        quotaTokensSet.add(token); // F:[PQK-5]
        totalQuotaParams[token].initialise(); // F:[PQK-5]

        emit NewQuotaTokenAdded(token); // F:[PQK-5]
    }

    /// @dev Batch updates the quota rates and changes the combined quota revenue
    function updateRates()
        external
        override
        gaugeOnly // F:[PQK-3]
    {
        address[] memory tokens = quotaTokensSet.values();
        uint16[] memory rates = IGauge(gauge).getRates(tokens); // F:[PQK-7]

        /// TODO: add check for equal length(?)

        uint128 quotaRevenue;
        uint256 timeFromLastUpdate = block.timestamp - lastQuotaRateUpdate;
        uint256 len = tokens.length;

        for (uint256 i; i < len;) {
            address token = tokens[i];
            uint16 rate = rates[i];

            TokenQuotaParams storage tokenQuotaParams = totalQuotaParams[token];
            quotaRevenue += tokenQuotaParams.updateRate(timeFromLastUpdate, rate);

            emit UpdateTokenQuotaRate(token, rate); // F:[PQK-7]

            unchecked {
                ++i;
            }
        }

        pool.updateQuotaRevenue(quotaRevenue); // F:[PQK-7]
        lastQuotaRateUpdate = uint40(block.timestamp); // F:[PQK-7]
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
            gauge = _gauge; // F:[PQK-8]
            lastQuotaRateUpdate = uint40(block.timestamp); // F:[PQK-8]
            emit SetGauge(_gauge); // F:[PQK-8]
        }
    }

    /// @dev Adds a new Credit Manager to the set of allowed CM's
    /// @param _creditManager Address of the new Credit Manager
    function addCreditManager(address _creditManager)
        external
        configuratorOnly // F:[PQK-2]
        nonZeroAddress(_creditManager)
        registeredCreditManagerOnly(_creditManager) // F:[PQK-9]
    {
        if (ICreditManagerV3(_creditManager).pool() != address(pool)) {
            revert IncompatibleCreditManagerException(); // F:[PQK-9]
        }

        /// Checks if creditManager is already in list
        if (!creditManagerSet.contains(_creditManager)) {
            creditManagerSet.add(_creditManager); // F:[PQK-10]
            emit AddCreditManager(_creditManager); // F:[PQK-10]
        }
    }

    /// @dev Sets an upper limit on accountQuotas for a token
    /// @param token Address of token to set the limit for
    /// @param limit The limit to set
    function setTokenLimit(address token, uint96 limit)
        external
        controllerOnly // F:[PQK-2]
    {
        TokenQuotaParams storage tokenQuotaParams = totalQuotaParams[token];
        _setTokenLimit(tokenQuotaParams, token, limit);
    }

    function _setTokenLimit(TokenQuotaParams storage tokenQuotaParams, address token, uint96 limit) internal {
        if (tokenQuotaParams.setLimit(limit)) {
            emit SetTokenLimit(token, limit);
        } // F:[PQK-12]
    }
}
