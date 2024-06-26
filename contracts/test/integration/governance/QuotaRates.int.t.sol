// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {Test} from "forge-std/Test.sol";

import {TumblerV3} from "../../../pool/TumblerV3.sol";
import {PoolQuotaKeeperV3} from "../../../pool/PoolQuotaKeeperV3.sol";

import {PoolMock} from "../../mocks/pool/PoolMock.sol";
import {ERC20Mock} from "../../mocks/token/ERC20Mock.sol";
import {AddressProviderV3ACLMock} from "../../mocks/core/AddressProviderV3ACLMock.sol";

/// @title Quota rates integration test
/// @notice I:[QR]: Tests that ensure that tumbler and quota keeper contracts interact correctly
contract QuotaRatesIntegrationTest is Test {
    TumblerV3 tumbler;
    PoolQuotaKeeperV3 quotaKeeper;

    PoolMock pool;
    ERC20Mock token1;
    ERC20Mock token2;
    ERC20Mock underlying;
    AddressProviderV3ACLMock addressProvider;

    function setUp() public {
        addressProvider = new AddressProviderV3ACLMock();
        underlying = new ERC20Mock("Underlying", "UND", 18);
        token1 = new ERC20Mock("Test Token 1", "TEST1", 18);
        token2 = new ERC20Mock("Test Token 2", "TEST2", 18);
        pool = new PoolMock(address(addressProvider), address(underlying));

        quotaKeeper = new PoolQuotaKeeperV3(address(addressProvider), address(addressProvider), address(pool));
        pool.setPoolQuotaKeeper(address(quotaKeeper));

        tumbler = new TumblerV3(address(addressProvider), address(quotaKeeper), 1 days);
        quotaKeeper.setGauge(address(tumbler));
    }

    /// @notice I:[QR-1]: `TumblerV3` allows to change rates in `PoolQuotaKeeperV3`
    function test_I_QR_01_tumbler_allows_to_change_rates_in_poolQuotaKeeper() public {
        tumbler.addToken(address(token1), 4200);
        tumbler.addToken(address(token2), 12000);

        address[] memory tokens = new address[](2);
        tokens[0] = address(token1);
        tokens[1] = address(token2);

        vm.expectCall(address(quotaKeeper), abi.encodeCall(quotaKeeper.updateRates, ()));
        vm.expectCall(address(tumbler), abi.encodeCall(tumbler.getRates, (tokens)));

        tumbler.updateRates();
        assertEq(quotaKeeper.getQuotaRate(address(token1)), 4200, "Incorrect token1 rate");
        assertEq(quotaKeeper.getQuotaRate(address(token2)), 12000, "Incorrect token2 rate");
    }
}
