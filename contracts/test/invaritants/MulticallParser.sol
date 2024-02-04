// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {GearboxInstance} from "./Deployer.sol";
import {BalanceDelta} from "../../libraries/BalancesLogic.sol";

import {IPriceOracleV3} from "../../interfaces/IPriceOracleV3.sol";
import {ICreditManagerV3, CollateralCalcTask} from "../../interfaces/ICreditManagerV3.sol";
import {ICreditFacadeV3, ICreditFacadeV3Multicall} from "../../interfaces/ICreditFacadeV3.sol";
import {IPoolQuotaKeeperV3} from "../../interfaces/IPoolQuotaKeeperV3.sol";
import {MultiCall} from "../../interfaces/ICreditFacadeV3.sol";
import {MultiCallBuilder} from "../lib/MultiCallBuilder.sol";

import {ParseLib} from "../lib/ParseLib.sol";
import "forge-std/Test.sol";
import "../lib/constants.sol";
import "forge-std/console.sol";
import "forge-std/Vm.sol";

contract MulticallParser {
    using Strings for uint256;
    using Strings for address;
    using ParseLib for string;

    ICreditManagerV3 creditManager;
    address underlying;

    constructor(ICreditManagerV3 _cm) {
        creditManager = _cm;
        underlying = creditManager.underlying();
    }

    function print(MultiCall[] calldata calls) public {
        uint256 len = calls.length;
        for (uint256 i; i < len; ++i) {
            print(calls[i], i);
        }
    }

    function print(MultiCall calldata call, uint256 index) public {
        return print(call, string.concat("[", index.toString(), "]: "));
    }

    function print(MultiCall calldata call) public {
        return print(call, "");
    }

    function print(MultiCall calldata call, string memory prefix) public {
        if (call.target == address(creditManager.creditFacade())) {
            bytes4 method = bytes4(call.callData);
            bytes memory callData = call.callData[4:];

            // storeExpectedBalances
            if (method == ICreditFacadeV3Multicall.storeExpectedBalances.selector) {
                console.log(string.concat(prefix, "creditFacade.storeExpectedBalances("));
                BalanceDelta[] memory balanceDeltas = abi.decode(callData, (BalanceDelta[])); // U:[FA-23]
            }
            // compareBalances
            else if (method == ICreditFacadeV3Multicall.compareBalances.selector) {
                console.log(string.concat(prefix, "creditFacade.compareBalances()"));
            }
            // addCollateral
            else if (method == ICreditFacadeV3Multicall.addCollateral.selector) {
                (address token, uint256 amount) = abi.decode(callData, (address, uint256));

                console.log(
                    string.concat(prefix, "creditFacade.addCollateral({token: %s, amount: %s});"),
                    formatToken(token),
                    formatAmount(token, amount)
                );
            }
            // addCollateralWithPermit
            else if (method == ICreditFacadeV3Multicall.addCollateralWithPermit.selector) {
                (address token, uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s) =
                    abi.decode(callData, (address, uint256, uint256, uint8, bytes32, bytes32));

                console.log(
                    string.concat(prefix, "creditFacade.addCollateralWithPermit(%s, %s, %s,"),
                    formatToken(token),
                    amount,
                    deadline
                );

                console.log("v: %s,", v);
                console.log("r: %s,", uint256(r));
                console.log("s:%s)", uint256(s));
            }
            // updateQuota
            else if (method == ICreditFacadeV3Multicall.updateQuota.selector) {
                (address token, int96 quotaChange, uint96 minQuota) = abi.decode(callData, (address, int96, uint96)); // U:[FA-34]

                console.log(string.concat(prefix, "creditFacade.updateQuota({token: %s, quota:"), formatToken(token));
                // console.log(int256(quotaChange));
                console.log("minQuota: %s})", uint256(minQuota));
            }
            // withdrawCollateral
            else if (method == ICreditFacadeV3Multicall.withdrawCollateral.selector) {
                (address token, uint256 amount, address to) = abi.decode(callData, (address, uint256, address)); // U:[FA-35]

                console.log(
                    string.concat(prefix, "creditFacade.withdrawCollateral({token: %s, amount: %s, to: %s})"),
                    formatToken(token),
                    formatAmount(token, amount),
                    to
                );
            }
            // increaseDebt
            else if (method == ICreditFacadeV3Multicall.increaseDebt.selector) {
                uint256 amount = abi.decode(callData, (uint256));
                console.log(
                    string.concat(prefix, "creditFacade.increaseDebt({amount: %s})"), formatAmount(underlying, amount)
                );
            }
            // decreaseDebt
            else if (method == ICreditFacadeV3Multicall.decreaseDebt.selector) {
                uint256 amount = abi.decode(callData, (uint256));
                console.log(
                    string.concat(prefix, "creditFacade.decreaseDebt({amount: %s})"), formatAmount(underlying, amount)
                );
            }
            // setFullCheckParams
            else if (method == ICreditFacadeV3Multicall.setFullCheckParams.selector) {
                console.log(string.concat(prefix, "creditFacade.setFullCheckParams("));
                (uint256[] memory collateralHints, uint16 minHealthFactor) = abi.decode(callData, (uint256[], uint16)); // U:[FA-24]
                uint256 len = collateralHints.length;
                unchecked {
                    for (uint256 i = 0; i < len; ++i) {
                        console.log("mask for token:", formatToken(creditManager.getTokenByMask(collateralHints[i])));
                    }
                }
                console.log(", minHealhFactor: %s)", minHealthFactor);
            }
            // enableToken
            else if (method == ICreditFacadeV3Multicall.enableToken.selector) {
                address token = abi.decode(callData, (address));
                console.log(string.concat(prefix, "creditFacade.enableToken({token: %s })"), formatToken(token));
            }
            // disableToken
            else if (method == ICreditFacadeV3Multicall.disableToken.selector) {
                address token = abi.decode(callData, (address));
                console.log(string.concat(prefix, "creditFacade.disableToken({token: %s })"), formatToken(token));
            }
            // revokeAdapterAllowances
            else if (method == ICreditFacadeV3Multicall.revokeAdapterAllowances.selector) {
                console.log(string.concat(prefix, "creditFacade.revokeAdapterAllowances("));

                address token = abi.decode(callData, (address)); // U:[FA-33]
            }
            // unknown method
            else {
                console.log(string.concat(prefix, "UnknownMethodException()")); // U:[FA-22]
            }
        } else {
            console.log(string.concat(prefix, "External call to: %s:"), call.target);
        }
    }

    function formatToken(address token) internal returns (string memory) {
        return string.concat(IERC20Metadata(token).symbol(), " (", token.toHexString(), ")");
    }

    function formatAmount(address token, uint256 amount) internal returns (string memory result) {
        return string.concat(result.add_amount_token("", amount, token).add("[ ", amount), "]");
    }
}
