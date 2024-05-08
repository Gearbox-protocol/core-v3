// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {LinearInterestRateModelV3} from "../pool/LinearInterestRateModelV3.sol";

contract LinearModelDeployerV3 {
    function deployLinearModelV3(
        uint16 U_1,
        uint16 U_2,
        uint16 R_base,
        uint16 R_slope1,
        uint16 R_slope2,
        uint16 R_slope3,
        bool _isBorrowingMoreU2Forbidden
    ) external returns (address) {
        return address(
            new LinearInterestRateModelV3(U_1, U_2, R_base, R_slope1, R_slope2, R_slope3, _isBorrowingMoreU2Forbidden)
        );
    }
}
