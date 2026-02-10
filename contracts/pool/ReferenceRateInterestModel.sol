pragma solidity ^0.8.23;

import {IInterestRateModel} from "../interfaces/base/IInterestRateModel.sol";
import {IReferenceRateProvider} from "../interfaces/base/IReferenceRateProvider.sol";

import {CreditLogic} from "../libraries/CreditLogic.sol";

import {RAY, PERCENTAGE_FACTOR} from "../libraries/Constants.sol";
import "../interfaces/IExceptions.sol";

contract ReferenceRateInterestModel is IInterestRateModel {
    using CreditLogic for uint256;

    bytes32 public constant override contractType = "IRM::REFERENCE_RATE";

    uint256 public constant override version = 3_20;

    address public immutable referenceRateProvider;

    uint256 public interestIndexLU;

    uint256 public immutable offsetRateRAY;

    uint256 public referenceRateRAY;

    uint40 internal lastUpdateTimestamp;

    constructor(address _referenceRateProvider, uint256 _initialReferenceRateRAY, uint256 _offsetRateRAY) {
        referenceRateProvider = _referenceRateProvider;
        referenceRateRAY = _initialReferenceRateRAY;
        offsetRateRAY = _offsetRateRAY;
        interestIndexLU = RAY;
    }

    function calcBorrowRate() external view returns (uint256) {
        return referenceRateRAY + offsetRateRAY;
    }

    function isGreaterOrEqualRate(address otherIrm) external view returns (bool) {
        bytes32 otherContractType = IInterestRateModel(otherIrm).contractType();

        if (otherContractType != contractType) {
            revert IRMNotComparableException();
        }

        address otherRRP = ReferenceRateInterestModel(otherIrm).referenceRateProvider();
        uint256 otherOffsetRate = ReferenceRateInterestModel(otherIrm).offsetRateRAY();

        if (otherRRP != referenceRateProvider) {
            revert IRMNotComparableException();
        }

        return otherOffsetRate >= offsetRateRAY;
    }

    function getCurrentIndex() public view returns (uint256) {
        if (uint256(lastUpdateTimestamp) == block.timestamp) return interestIndexLU;

        return interestIndexLU * (RAY + (referenceRateRAY + offsetRateRAY).calcLinearGrowth(lastUpdateTimestamp)) / RAY;
    }

    function updateReferenceRate() external {
        uint256 newReferenceRateRAY = IReferenceRateProvider(referenceRateProvider).getReferenceRateRAY();

        uint256 currentIndex = getCurrentIndex();

        interestIndexLU = currentIndex;
        lastUpdateTimestamp = uint40(block.timestamp);
        referenceRateRAY = newReferenceRateRAY;
    }

    function serialize() external view returns (bytes memory) {
        return abi.encode(referenceRateRAY, offsetRateRAY, getCurrentIndex());
    }
}
