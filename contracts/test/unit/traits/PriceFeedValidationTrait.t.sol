// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {PriceFeedValidationTrait} from "../../../traits/PriceFeedValidationTrait.sol";
import {TestHelper} from "../../lib/helper.sol";
import {PriceFeedFallbackMock} from "../../mocks/oracles/PriceFeedFallbackMock.sol";

contract PriceFeedValidationTraitUnitTest is PriceFeedValidationTrait, TestHelper {
    function test_U_PFVT_01_validatePriceFeed_works_correctly_for_PF_with_fallback() public {
        address priceFeed = address(new PriceFeedFallbackMock(1e8, 8, false));

        _validatePriceFeed(priceFeed, 1000);

        priceFeed = address(new PriceFeedFallbackMock(1e8, 8, true));
        _validatePriceFeed(priceFeed, 1000);
    }
}
