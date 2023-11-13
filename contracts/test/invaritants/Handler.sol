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

struct CA {
    address creditAccount;
    bool isZero;
}

struct Actor {
    address actor;
    CA[] openedCreditAccounts;
}

// Probably I can start with one actor handler which tests user realted functionality by
// calling random numbers
// Then, it could be added liquidation layer if prices are manipulatable
// Then adapter to manipulate prices during multicall (Or simply set via priceUpdater)
// How to build a random miulticall (?)
//    - open multicall (generate random call during open CA)
//    - multicall with open CA and nonZero debt
//    - mutlicall with open CA and zeroDebt
//    - multicall during closing CA
//    - multicall during liquidation
//    - multicall for withdrawing
//
// In other words, to find a weak place, we should build possible attack vector behavior via handler and then keep all invariants there
contract Handler {
    Vm internal vm;
    GearboxInstance gi;

    Actor[] actors;

    uint16 actorsQty;

    uint256 b;
    uint256 counter;

    constructor(GearboxInstance _gi) {
        gi = _gi;
        vm = gi.getVm();
        b = block.timestamp;
    }

    function initActors(uint256 actorsQty) internal {}

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
