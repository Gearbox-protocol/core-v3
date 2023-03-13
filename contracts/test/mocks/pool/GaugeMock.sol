// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.10;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {ACLNonReentrantTrait} from "../../../core/ACLNonReentrantTrait.sol";

import {AddressProvider} from "@gearbox-protocol/core-v2/contracts/core/AddressProvider.sol";
import {ContractsRegister} from "@gearbox-protocol/core-v2/contracts/core/ContractsRegister.sol";

// interfaces

import {IPoolQuotaKeeper, QuotaRateUpdate} from "../../../interfaces/IPoolQuotaKeeper.sol";
import {IGearStaking} from "../../../interfaces/IGearStaking.sol";

import {RAY, SECONDS_PER_YEAR, MAX_WITHDRAW_FEE} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/PercentageMath.sol";
import {Errors} from "@gearbox-protocol/core-v2/contracts/libraries/Errors.sol";
import {Pool4626} from "../../../pool/Pool4626.sol";
import {GaugeOpts} from "../../../interfaces/IGauge.sol";

// EXCEPTIONS
import {ZeroAddressException} from "../../../interfaces/IErrors.sol";

/// @title Gauge fore new 4626 pools
contract GaugeMock is ACLNonReentrantTrait {
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for IERC20;

    /// @dev Address provider
    address public immutable addressProvider;

    /// @dev Address of the pool
    Pool4626 public immutable pool;

    /// @dev Mapping from token address to its rate parameters
    mapping(address => uint16) public rates;

    //
    // CONSTRUCTOR
    //

    /// @dev Constructor
    /// @param opts Gauge options
    ///             * addressProvider - the AddressProvder contract
    ///             * pool - Address of the associated pool
    ///             * vote
    constructor(GaugeOpts memory opts) ACLNonReentrantTrait(address(Pool4626(opts.pool).addressProvider())) {
        // Additional check that receiver is not address(0)
        if (opts.pool == address(0)) {
            revert ZeroAddressException(); // F:[P4-02]
        }

        addressProvider = address(Pool4626(opts.pool).addressProvider()); // F:[P4-01]
        pool = Pool4626(payable(opts.pool)); // F:[P4-01]
    }

    /// @dev Rolls the new epoch and updates all quota rates
    function updateEpoch() external {
        /// compute all compounded rates
        IPoolQuotaKeeper keeper = IPoolQuotaKeeper(pool.poolQuotaKeeper());

        /// update rates & cumulative indexes
        address[] memory tokens = keeper.quotedTokens();
        uint256 len = tokens.length;
        QuotaRateUpdate[] memory qUpdates = new QuotaRateUpdate[](len);

        for (uint256 i; i < len;) {
            address token = tokens[i];

            uint16 newRate = rates[token];

            qUpdates[i] = QuotaRateUpdate({token: token, rate: newRate});

            unchecked {
                ++i;
            }
        }

        keeper.updateRates(qUpdates);
    }

    function addQuotaToken(address token, uint16 _rate) external configuratorOnly {
        rates[token] = _rate;
        IPoolQuotaKeeper keeper = IPoolQuotaKeeper(pool.poolQuotaKeeper());
        keeper.addQuotaToken(token);
    }

    function changeQuotaTokenRateParams(address token, uint16 _rate) external configuratorOnly {
        rates[token] = _rate;
    }
}
