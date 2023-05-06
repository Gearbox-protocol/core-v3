// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import {MultiCall} from "@gearbox-protocol/core-v2/contracts/libraries/MultiCall.sol";
import {Balance, BalanceOps} from "@gearbox-protocol/core-v2/contracts/libraries/Balances.sol";
import {ICreditFacade, ICreditFacadeMulticall} from "../interfaces/ICreditFacade.sol";

interface CreditFacadeMulticaller {}

library CreditFacadeCalls {
    function revertIfReceivedLessThan(CreditFacadeMulticaller creditFacade, Balance[] memory expectedBalances)
        internal
        pure
        returns (MultiCall memory)
    {
        return MultiCall({
            target: address(creditFacade),
            callData: abi.encodeCall(ICreditFacadeMulticall.revertIfReceivedLessThan, (expectedBalances))
        });
    }

    function addCollateral(CreditFacadeMulticaller creditFacade, address token, uint256 amount)
        internal
        pure
        returns (MultiCall memory)
    {
        return MultiCall({
            target: address(creditFacade),
            callData: abi.encodeCall(ICreditFacadeMulticall.addCollateral, (token, amount))
        });
    }

    function increaseDebt(CreditFacadeMulticaller creditFacade, uint256 amount)
        internal
        pure
        returns (MultiCall memory)
    {
        return MultiCall({
            target: address(creditFacade),
            callData: abi.encodeCall(ICreditFacadeMulticall.increaseDebt, (amount))
        });
    }

    function decreaseDebt(CreditFacadeMulticaller creditFacade, uint256 amount)
        internal
        pure
        returns (MultiCall memory)
    {
        return MultiCall({
            target: address(creditFacade),
            callData: abi.encodeCall(ICreditFacadeMulticall.decreaseDebt, (amount))
        });
    }

    function enableToken(CreditFacadeMulticaller creditFacade, address token)
        internal
        pure
        returns (MultiCall memory)
    {
        return MultiCall({
            target: address(creditFacade),
            callData: abi.encodeCall(ICreditFacadeMulticall.enableToken, (token))
        });
    }

    function disableToken(CreditFacadeMulticaller creditFacade, address token)
        internal
        pure
        returns (MultiCall memory)
    {
        return MultiCall({
            target: address(creditFacade),
            callData: abi.encodeCall(ICreditFacadeMulticall.disableToken, (token))
        });
    }

    function updateQuota(CreditFacadeMulticaller creditFacade, address token, int96 quotaChange)
        internal
        pure
        returns (MultiCall memory)
    {
        return MultiCall({
            target: address(creditFacade),
            callData: abi.encodeCall(ICreditFacadeMulticall.updateQuota, (token, quotaChange))
        });
    }

    function setFullCheckParams(
        CreditFacadeMulticaller creditFacade,
        uint256[] memory collateralHints,
        uint16 minHealthFactor
    ) internal pure returns (MultiCall memory) {
        return MultiCall({
            target: address(creditFacade),
            callData: abi.encodeCall(ICreditFacadeMulticall.setFullCheckParams, (collateralHints, minHealthFactor))
        });
    }
}
