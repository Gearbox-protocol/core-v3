import {CreditManagerV3, CreditAccountInfo} from "../../../credit/CreditManagerV3.sol";
import {IPriceOracleV2} from "@gearbox-protocol/core-v2/contracts/interfaces/IPriceOracle.sol";
import {CollateralDebtData} from "../../../interfaces/ICreditManagerV3.sol";

contract CreditManagerV3Harness is CreditManagerV3 {
    constructor(address _addressProvider, address _pool) CreditManagerV3(_addressProvider, _pool) {}

    function setDebt(address creditAccount, CreditAccountInfo memory _creditAccountInfo) external {
        creditAccountInfo[creditAccount] = _creditAccountInfo;
    }

    function approveSpender(address token, address targetContract, address creditAccount, uint256 amount) external {
        _approveSpender(token, targetContract, creditAccount, amount);
    }

    function getTargetContractOrRevert() external view returns (address targetContract) {
        return _getTargetContractOrRevert();
    }

    function calcFullCollateral(
        address creditAccount,
        uint256 enabledTokensMask,
        uint16 minHealthFactor,
        uint256[] memory collateralHints,
        address _priceOracle,
        bool lazy
    ) external view returns (CollateralDebtData memory collateralDebtData) {
        return
            _calcFullCollateral(creditAccount, enabledTokensMask, minHealthFactor, collateralHints, _priceOracle, lazy);
    }

    function calcQuotedCollateral(address creditAccount, uint256 enabledTokensMask, address _priceOracle)
        external
        view
        returns (uint256 totalValueUSD, uint256 twvUSD, uint256 quotaInterest, address[] memory tokens)
    {
        return _calcQuotedCollateral(creditAccount, enabledTokensMask, _priceOracle);
    }

    function calcNotQuotedCollateral(
        address creditAccount,
        uint256 enabledTokensMask,
        uint256 enoughCollateralUSD,
        uint256[] memory collateralHints,
        address _priceOracle
    ) external view returns (uint256 tokensToDisable, uint256 totalValueUSD, uint256 twvUSD) {
        return _calcNotQuotedCollateral(
            creditAccount, enabledTokensMask, enoughCollateralUSD, collateralHints, _priceOracle
        );
    }

    function calcOneNonQuotedTokenCollateral(
        address _priceOracle,
        uint256 tokenMask,
        address creditAccount,
        uint256 _totalValueUSD,
        uint256 _twvUSDx10K
    ) external view returns (uint256 totalValueUSD, uint256 twvUSDx10K, bool nonZeroBalance) {
        return _calcOneNonQuotedTokenCollateral(_priceOracle, tokenMask, creditAccount, _totalValueUSD, _twvUSDx10K);
    }

    function _getQuotedTokensLT(uint256 enabledTokensMask, bool withLTs)
        external
        view
        returns (address[] memory tokens, uint256[] memory lts)
    {
        return _getQuotedTokens(enabledTokensMask, withLTs);
    }

    function transferAssetsTo(address creditAccount, address to, bool convertWETH, uint256 enabledTokensMask)
        external
    {
        _transferAssetsTo(creditAccount, to, convertWETH, enabledTokensMask);
    }

    function safeTokenTransfer(address creditAccount, address token, address to, uint256 amount, bool convertToETH)
        external
    {
        _safeTokenTransfer(creditAccount, token, to, amount, convertToETH);
    }

    function checkEnabledTokenLength(uint256 enabledTokensMask) external view {
        _checkEnabledTokenLength(enabledTokensMask);
    }

    function collateralTokensByMaskCalcLT(uint256 tokenMask, bool calcLT)
        external
        view
        returns (address token, uint16 liquidationThreshold)
    {
        return _collateralTokensByMask(tokenMask, calcLT);
    }

    function calcCreditAccountAccruedInterest(address creditAccount, uint256 quotaInterest)
        external
        view
        returns (uint256 debt, uint256 accruedInterest, uint256 accruedFees)
    {
        return _calcCreditAccountAccruedInterest(creditAccount, quotaInterest);
    }

    function getCreditAccountParameters(address creditAccount)
        external
        view
        returns (uint256 debt, uint256 cumulativeIndexLastUpdate, uint256 cumulativeIndexNow)
    {
        return _getCreditAccountParameters(creditAccount);
    }

    function hasWithdrawals(address creditAccount) external view returns (bool) {
        return _hasWithdrawals(creditAccount);
    }

    function calcCancellableWithdrawalsValue(address _priceOracle, address creditAccount, bool isForceCancel)
        external
    {
        _calcCancellableWithdrawalsValue(_priceOracle, creditAccount, isForceCancel);
    }

    function saveEnabledTokensMask(address creditAccount, uint256 enabledTokensMask) external {
        _saveEnabledTokensMask(creditAccount, enabledTokensMask);
    }

    function convertToUSD(address _priceOracle, uint256 amountInToken, address token)
        external
        returns (uint256 amountInUSD)
    {
        return _convertToUSD(_priceOracle, amountInToken, token);
    }
}
