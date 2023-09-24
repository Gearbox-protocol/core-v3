// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {GearboxInstance} from "./Deployer.sol";

import {ICreditFacadeV3Multicall} from "../../interfaces/ICreditFacadeV3.sol";
import {MultiCall} from "../../interfaces/ICreditFacadeV3.sol";
import {MultiCallBuilder} from "../lib/MultiCallBuilder.sol";
import "forge-std/Test.sol";
import "../lib/constants.sol";
import "forge-std/console.sol";
import "forge-std/Vm.sol";

contract Handler {
    Vm internal vm;
    GearboxInstance gi;

    uint256 b;
    uint256 counter;

    constructor(GearboxInstance _gi) {
        gi = _gi;
        vm = gi.getVm();
        b = block.timestamp;
    }

    function openCA(uint256 _debt) public {
        vm.roll(++b);
        console.log(++counter);
        (uint256 minDebt, uint256 maxDebt) = gi.creditFacade().debtLimits();

        uint256 debt = minDebt + (_debt % (maxDebt - minDebt));

        if (gi.pool().availableLiquidity() < 2 * debt) {
            gi.tokenTestSuite().mint(gi.underlyingT(), INITIAL_LP, 3 * debt);
            gi.tokenTestSuite().approve(gi.underlyingT(), INITIAL_LP, address(gi.pool()));

            vm.startPrank(INITIAL_LP);
            gi.pool().deposit(3 * debt, INITIAL_LP);
            vm.stopPrank();
        }

        if (gi.pool().creditManagerBorrowable(address(gi.creditManager())) > debt) {
            gi.tokenTestSuite().mint(gi.underlyingT(), address(this), debt);
            gi.tokenTestSuite().approve(gi.underlyingT(), address(this), address(gi.creditManager()));

            gi.creditFacade().openCreditAccount(
                address(this),
                MultiCallBuilder.build(
                    MultiCall({
                        target: address(gi.creditFacade()),
                        callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (debt))
                    }),
                    MultiCall({
                        target: address(gi.creditFacade()),
                        callData: abi.encodeCall(ICreditFacadeV3Multicall.addCollateral, (gi.underlying(), debt))
                    })
                ),
                0
            );
        }
    }
}
