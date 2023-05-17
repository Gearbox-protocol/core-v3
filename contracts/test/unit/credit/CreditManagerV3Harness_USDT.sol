import {CreditManagerV3Harness} from "./CreditManagerV3Harness.sol";
import {USDT_Transfer} from "../../../traits/USDT_Transfer.sol";
import {IPoolBase} from "../../../interfaces/IPool4626.sol";
/// @title Credit Manager

contract CreditManagerV3Harness_USDT is CreditManagerV3Harness, USDT_Transfer {
    constructor(address _addressProvider, address _pool)
        CreditManagerV3Harness(_addressProvider, _pool)
        USDT_Transfer(IPoolBase(_pool).underlyingToken())
    {}

    function _amountWithFee(uint256 amount) internal view override returns (uint256) {
        return _amountUSDTWithFee(amount);
    }

    function _amountMinusFee(uint256 amount) internal view override returns (uint256) {
        return _amountUSDTMinusFee(amount);
    }
}
