pragma solidity ^0.8.17;

import "../../../interfaces/ICreditFacade.sol";
import {CreditFacadeV3} from "../../../credit/CreditFacadeV3.sol";

contract CreditFacadeV3Harness is CreditFacadeV3 {
    constructor(address _creditManager, address _degenNFT, bool _expirable)
        CreditFacadeV3(_creditManager, _degenNFT, _expirable)
    {}

    function setReentrancy(uint8 _status) external {
        _reentrancyStatus = _status;
    }

    function setCumulativeLoss(uint128 newLoss) external {
        lossParams.currentCumulativeLoss = newLoss;
    }

    function setTotalBorrowedInBlock(uint128 _totalBorrowedInBlock) external {
        totalBorrowedInBlock = _totalBorrowedInBlock;
    }

    function multicallInt(address creditAccount, MultiCall[] calldata calls, uint256 enabledTokensMask, uint256 flags)
        external
        returns (FullCheckParams memory fullCheckParams)
    {
        return _multicall(creditAccount, calls, enabledTokensMask, flags);
    }

    function revertIfNoPermission(uint256 flags, uint256 permission) external pure {
        _revertIfNoPermission(flags, permission);
    }
}
