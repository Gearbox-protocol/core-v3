// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

enum PriceFeedType {
    CHAINLINK_ORACLE,
    YEARN_ORACLE,
    CURVE_2LP_ORACLE,
    CURVE_3LP_ORACLE,
    CURVE_4LP_ORACLE,
    ZERO_ORACLE,
    WSTETH_ORACLE,
    BOUNDED_ORACLE,
    COMPOSITE_ORACLE,
    AAVE_ORACLE,
    EULER_ORACLE,
    COMPOUND_ORACLE,
    BALANCER_STABLE_LP_ORACLE,
    BALANCER_WEIGHTED_LP_ORACLE
}

interface IPriceFeedType {
    /// @dev Returns the price feed type
    function priceFeedType() external view returns (PriceFeedType);

    /// @dev Returns whether sanity checks on price feed result should be skipped
    function skipPriceCheck() external view returns (bool);
}
