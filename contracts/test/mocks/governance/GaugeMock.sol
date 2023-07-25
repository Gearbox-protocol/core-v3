// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SafeERC20} from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {ACLNonReentrantTrait} from "../../../traits/ACLNonReentrantTrait.sol";

// interfaces

import {IPoolQuotaKeeperV3} from "../../../interfaces/IPoolQuotaKeeperV3.sol";

import {PoolV3} from "../../../pool/PoolV3.sol";

/// @title Gauge fore new 4626 pools
contract GaugeMock is ACLNonReentrantTrait {
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for IERC20;

    /// @dev Address provider
    address public immutable addressProvider;

    /// @dev Address of the pool
    PoolV3 public immutable pool;

    /// @dev Mapping from token address to its rate parameters
    mapping(address => uint16) public rates;

    //
    // CONSTRUCTOR
    //

    /// @dev Constructor

    constructor(address _pool) ACLNonReentrantTrait(address(PoolV3(_pool).addressProvider())) nonZeroAddress(_pool) {
        addressProvider = address(PoolV3(_pool).addressProvider()); // F:[P4-01]
        pool = PoolV3(payable(_pool)); // F:[P4-01]
    }

    /// @dev Rolls the new epoch and updates all quota rates
    function updateEpoch() external {
        /// compute all compounded rates
        IPoolQuotaKeeperV3 keeper = IPoolQuotaKeeperV3(pool.poolQuotaKeeper());

        // /// update rates & cumulative indexes
        // address[] memory tokens = keeper.quotedTokens();
        // uint256 len = tokens.length;
        // uint16[] memory rateUpdates = new uint16[](len);

        // unchecked {
        //     for (uint256 i; i < len; ++i) {
        //         address token = tokens[i];
        //         rateUpdates[i] = rates[token];
        //     }
        // }

        keeper.updateRates();
    }

    function addQuotaToken(address token, uint16 rate) external configuratorOnly {
        rates[token] = rate;
        IPoolQuotaKeeperV3 keeper = IPoolQuotaKeeperV3(pool.poolQuotaKeeper());
        keeper.addQuotaToken(token);
    }

    function changeQuotaTokenRateParams(address token, uint16 rate) external configuratorOnly {
        rates[token] = rate;
    }

    function getRates(address[] memory tokens) external view returns (uint16[] memory result) {
        uint256 len = tokens.length;
        result = new uint16[](len);
        unchecked {
            for (uint256 i; i < len; ++i) {
                address token = tokens[i];
                result[i] = rates[token];
            }
        }
    }
}
