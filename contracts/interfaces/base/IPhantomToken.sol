// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {PhantomTokenType} from "@gearbox-protocol/sdk-gov/contracts/Tokens.sol";
import {MultiCall} from "../ICreditFacadeV3.sol";

interface IPhantomToken {
    function _gearboxPhantomTokenType() external view returns (PhantomTokenType);

    function getWithdrawalMultiCall(address creditAccount, uint256 amount)
        external
        returns (address tokenOut, uint256 amountOut, address targetContract, bytes memory callData);
}
