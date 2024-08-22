// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {Deployer} from "../Deployer.sol";
import {Invariants} from "../Invariants.sol";

contract InvariantTestBase is Deployer, Invariants {
    function _generateAddrs(string memory label, uint256 num) internal returns (address[] memory addrs) {
        addrs = new address[](num);
        for (uint256 i; i < num; ++i) {
            addrs[i] = makeAddr(string.concat(label, " ", vm.toString(i)));
        }
    }

    struct Selector {
        bytes4 selector;
        uint256 times;
    }

    function _addFuzzingTarget(address target, Selector[] memory selectors) internal {
        targetContract(target);
        for (uint256 i; i < selectors.length; ++i) {
            if (selectors[i].times == 0) continue;
            FuzzSelector memory fuzzSelector = FuzzSelector(target, new bytes4[](selectors[i].times));
            for (uint256 j; j < selectors[i].times; ++j) {
                fuzzSelector.selectors[j] = selectors[i].selector;
            }
            targetSelector(fuzzSelector);
        }
    }
}
