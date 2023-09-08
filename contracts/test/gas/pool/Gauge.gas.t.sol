// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

// TESTS
import "../../lib/constants.sol";
import {IntegrationTestHelper} from "../../helpers/IntegrationTestHelper.sol";
import {ERC20Mock} from "../../mocks/token/ERC20Mock.sol";

import "forge-std/console.sol";

// Low limit set for speed test, if you need real value, use 30_000_000
uint256 constant GAS_LIMIT = 20_000; // 30_000_000;

contract GaugeGasTest is IntegrationTestHelper {
    ///
    ///
    ///  TESTS
    ///
    ///

    /// @dev G:[GA-1]: updateEpoch gas usage
    function test_G_GA_01_updateEpoch_gas_usage() public creditTest {
        uint256 gasUsed;
        uint256 i;
        unchecked {
            while (gasUsed < GAS_LIMIT) {
                ERC20Mock token = new ERC20Mock("TST", "TEST Token", 18);

                vm.startPrank(CONFIGURATOR);
                gauge.addQuotaToken(address(token), 500, 500);
                poolQuotaKeeper.setTokenLimit(address(token), type(uint96).max);
                vm.stopPrank();

                vm.warp(block.timestamp + 7 days);

                uint256 gasBefore = gasleft();
                gauge.updateEpoch();
                gasUsed = gasBefore - gasleft();
                ++i;
            }
        }

        console.log("[%d tokens] gas used: %d", i, gasUsed);
    }
}
