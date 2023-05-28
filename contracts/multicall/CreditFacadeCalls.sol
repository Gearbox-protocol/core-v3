// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import {MultiCall} from "@gearbox-protocol/core-v2/contracts/libraries/MultiCall.sol";
import {Balance} from "../libraries/BalancesLogic.sol";
import {ICreditFacadeV3, ICreditFacadeV3Multicall} from "../interfaces/ICreditFacadeV3.sol";

interface CreditFacadeMulticaller {}

library CreditFacadeCalls {
    function revertIfReceivedLessThan(CreditFacadeMulticaller creditFacade, Balance[] memory expectedBalances)
        internal
        pure
        returns (MultiCall memory)
    {
        return MultiCall({
            target: address(creditFacade),
            callData: abi.encodeCall(ICreditFacadeV3Multicall.revertIfReceivedLessThan, (expectedBalances))
        });
    }

    function addCollateral(CreditFacadeMulticaller creditFacade, address token, uint256 amount)
        internal
        pure
        returns (MultiCall memory)
    {
        return MultiCall({
            target: address(creditFacade),
            callData: abi.encodeCall(ICreditFacadeV3Multicall.addCollateral, (token, amount))
        });
    }

    function increaseDebt(CreditFacadeMulticaller creditFacade, uint256 amount)
        internal
        pure
        returns (MultiCall memory)
    {
        return MultiCall({
            target: address(creditFacade),
            callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (amount))
        });
    }

    function decreaseDebt(CreditFacadeMulticaller creditFacade, uint256 amount)
        internal
        pure
        returns (MultiCall memory)
    {
        return MultiCall({
            target: address(creditFacade),
            callData: abi.encodeCall(ICreditFacadeV3Multicall.decreaseDebt, (amount))
        });
    }

    function enableToken(CreditFacadeMulticaller creditFacade, address token)
        internal
        pure
        returns (MultiCall memory)
    {
        return MultiCall({
            target: address(creditFacade),
            callData: abi.encodeCall(ICreditFacadeV3Multicall.enableToken, (token))
        });
    }

    function disableToken(CreditFacadeMulticaller creditFacade, address token)
        internal
        pure
        returns (MultiCall memory)
    {
        return MultiCall({
            target: address(creditFacade),
            callData: abi.encodeCall(ICreditFacadeV3Multicall.disableToken, (token))
        });
    }

    function updateQuota(CreditFacadeMulticaller creditFacade, address token, int96 quotaChange, uint96 minQuota)
        internal
        pure
        returns (MultiCall memory)
    {
        return MultiCall({
            target: address(creditFacade),
            callData: abi.encodeCall(ICreditFacadeV3Multicall.updateQuota, (token, quotaChange, minQuota))
        });
    }

    function setFullCheckParams(
        CreditFacadeMulticaller creditFacade,
        uint256[] memory collateralHints,
        uint16 minHealthFactor
    ) internal pure returns (MultiCall memory) {
        return MultiCall({
            target: address(creditFacade),
            callData: abi.encodeCall(ICreditFacadeV3Multicall.setFullCheckParams, (collateralHints, minHealthFactor))
        });
    }
}
