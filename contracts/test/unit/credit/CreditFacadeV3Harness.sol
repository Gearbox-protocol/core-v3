pragma solidity ^0.8.17;

import {CreditFacadeV3} from "../../../credit/CreditFacadeV3.sol";
import {IPriceOracleV2} from "@gearbox-protocol/core-v2/contracts/interfaces/IPriceOracle.sol";
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/PercentageMath.sol";

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
}
