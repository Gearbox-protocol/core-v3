// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.17;

import "../../../interfaces/IAddressProviderV3.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {
    ICreditManagerV3,
    ClosureAction,
    CollateralDebtData,
    CollateralCalcTask
} from "../../../interfaces/ICreditManagerV3.sol";
import {IPoolV3} from "../../../interfaces/IPoolV3.sol";
import {IPoolQuotaKeeper} from "../../../interfaces/IPoolQuotaKeeper.sol";
import {ClaimAction} from "../../../interfaces/IWithdrawalManager.sol";

import "../../../interfaces/IExceptions.sol";

import "../../lib/constants.sol";

contract CreditManagerMock {
    /// @dev Factory contract for Credit Accounts
    address public addressProvider;

    /// @dev Address of the underlying asset
    address public underlying;

    /// @dev Address of the connected pool
    address public poolService;
    address public pool;

    /// @dev Address of WETH
    address public weth;

    /// @dev Address of WETH Gateway
    address public wethGateway;

    mapping(address => uint256) public getTokenMaskOrRevert;

    address public creditConfigurator;
    address borrower;
    uint256 public quotedTokensMask;
    bool public supportsQuotas;

    CollateralDebtData collateralDebtData;
    uint256 internal enabledTokensMask;

    address nextCreditAccount;

    constructor(address _addressProvider, address _pool) {
        addressProvider = _addressProvider;
        weth = IAddressProviderV3(addressProvider).getAddressOrRevert(AP_WETH_TOKEN, NO_VERSION_CONTROL); // U:[CM-1]
        wethGateway = IAddressProviderV3(addressProvider).getAddressOrRevert(AP_WETH_GATEWAY, 3_00); // U:[CM-1]
        setPoolService(_pool);
        creditConfigurator = CONFIGURATOR;
        supportsQuotas = true;
    }

    function setSupportsQuotas(bool _supportsQuotas) external {
        supportsQuotas = _supportsQuotas;
    }

    function setPoolService(address newPool) public {
        poolService = newPool;
        pool = newPool;
    }

    /// @notice Outdated
    function lendCreditAccount(uint256 borrowedAmount, address ca) external {
        IPoolV3(poolService).lendCreditAccount(borrowedAmount, ca);
    }

    /// @notice Outdated
    function repayCreditAccount(uint256 borrowedAmount, uint256 profit, uint256 loss) external {
        IPoolV3(poolService).repayCreditAccount(borrowedAmount, profit, loss);
    }

    /// @notice Outdated
    function updateQuota(address _creditAccount, address token, int96 quotaChange)
        external
        returns (uint256 caQuotaInterestChange, bool tokensToEnable, uint256 tokensToDisable)
    {
        (caQuotaInterestChange,,) =
            IPoolQuotaKeeper(IPoolV3(pool).poolQuotaKeeper()).updateQuota(_creditAccount, token, quotaChange);
    }

    function addToken(address token, uint256 mask) external {
        getTokenMaskOrRevert[token] = mask;
    }

    function setBorrower(address _borrower) external {
        borrower = _borrower;
    }

    function getBorrowerOrRevert(address creditAccount) external view returns (address) {
        if (borrower == address(0)) revert CreditAccountNotExistsException();
        return borrower;
    }

    function setReturnOpenCreditAccount(address _nextCreditAccount) external {
        nextCreditAccount = _nextCreditAccount;
    }

    function openCreditAccount(uint256 debt, address onBehalfOf) external returns (address creditAccount) {
        return nextCreditAccount;
    }

    function closeCreditAccount(
        address creditAccount,
        ClosureAction closureAction,
        CollateralDebtData memory collateralDebtData,
        address payer,
        address to,
        uint256 skipTokensMask,
        bool convertToETH
    ) external returns (uint256 remainingFunds, uint256 loss) {}

    function fullCollateralCheck(
        address creditAccount,
        uint256 enabledTokensMask,
        uint256[] memory collateralHints,
        uint16 minHealthFactor
    ) external {}

    function setActiveCreditAccount(address creditAccount) external {
        // _activeCreditAccount = creditAccount;
    }

    function setQuotedTokensMask(uint256 _quotedTokensMask) external {
        quotedTokensMask = _quotedTokensMask;
    }

    function calcDebtAndCollateral(address creditAccount, CollateralCalcTask task)
        external
        view
        returns (CollateralDebtData memory)
    {
        return collateralDebtData;
    }

    function setDebtAndCollateralData(CollateralDebtData calldata _collateralDebtData) external {
        collateralDebtData = _collateralDebtData;
    }

    function claimWithdrawals(address creditAccount, address to, ClaimAction action)
        external
        returns (uint256 tokensToEnable)
    {}

    function enabledTokensMaskOf(address creditAccount) external view returns (uint256) {
        return enabledTokensMask;
    }

    function setEnabledTokensMask(uint256 _enabledTokensMask) external {
        enabledTokensMask = _enabledTokensMask;
    }
}
