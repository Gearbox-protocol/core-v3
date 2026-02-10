pragma solidity ^0.8.23;

import {IInterestRateModel} from "../interfaces/base/IInterestRateModel.sol";

import {CreditLogic} from "../libraries/CreditLogic.sol";

import {RAY, PERCENTAGE_FACTOR} from "../libraries/Constants.sol";
import "../interfaces/IExceptions.sol";

contract FixedRateInterestModel is IInterestRateModel {
    using CreditLogic for uint256;

    bytes32 public constant override contractType = "IRM::FIXED_RATE";

    uint256 public constant override version = 3_20;

    uint256 public immutable fixedRateRAY;

    uint256 public interestIndexLU;

    uint40 internal lastUpdateTimestamp;

    constructor(uint256 _fixedRateRAY) {
        fixedRateRAY = _fixedRateRAY;
        interestIndexLU = RAY;
    }

    function calcBorrowRate() external view returns (uint256) {
        return fixedRateRAY;
    }

    function isGreaterOrEqualRate(address otherIrm) external view returns (bool) {
        bytes32 otherContractType = IInterestRateModel(otherIrm).contractType();

        if (otherContractType != contractType) {
            revert IRMNotComparableException();
        }

        uint256 otherFixedRateRAY = FixedRateInterestModel(otherIrm).fixedRateRAY();

        return otherFixedRateRAY >= fixedRateRAY;
    }

    function getCurrentIndex() public view returns (uint256) {
        if (uint256(lastUpdateTimestamp) == block.timestamp) return interestIndexLU;

        return interestIndexLU * (RAY + fixedRateRAY.calcLinearGrowth(lastUpdateTimestamp)) / RAY;
    }

    function accrueInterest() external {
        uint256 currentIndex = getCurrentIndex();

        interestIndexLU = currentIndex;
        lastUpdateTimestamp = uint40(block.timestamp);
    }

    function serialize() external view returns (bytes memory) {
        return abi.encode(fixedRateRAY, getCurrentIndex());
    }
}
