// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {
    ICreditManagerV3,
    CollateralDebtData,
    CollateralCalcTask,
    ManageDebtAction
} from "../../../interfaces/ICreditManagerV3.sol";
import {IPoolV3} from "../../../interfaces/IPoolV3.sol";

import "../../../interfaces/IExceptions.sol";

import "../../../libraries/Constants.sol";
import "../../lib/constants.sol";

contract CreditManagerMock {
    using SafeERC20 for IERC20;

    /// @dev Factory contract for Credit Accounts
    address public addressProvider;

    /// @dev Address of the underlying asset
    address public underlying;

    /// @dev Address of the connected pool
    address public poolService;
    address public pool;

    mapping(address => uint256) public tokenMasksMap;
    mapping(uint256 => address) public getTokenByMask;

    address public creditFacade;

    address public creditConfigurator;
    address borrower;
    uint256 public quotedTokensMask;

    CollateralDebtData return_collateralDebtData;

    CollateralDebtData _liquidateCollateralDebtData;
    uint256 internal _enabledTokensMask;

    address nextCreditAccount;

    address activeCreditAccount;
    bool revertOnSetActiveAccount;

    uint16 flags;

    address public priceOracle;

    /// @notice Maps allowed adapters to their respective target contracts.
    mapping(address => address) public adapterToContract;

    /// @notice Maps 3rd party contracts to their respective adapters
    mapping(address => address) public contractToAdapter;

    uint256 return_remainingFunds;
    uint256 return_loss;

    uint256 return_newDebt;

    int96 qu_change;
    uint256 qu_tokensToEnable;
    uint256 qu_tokensToDisable;

    uint256 sw_tokensToDisable;

    bool _transfersActivated;

    constructor(address _addressProvider, address _pool) {
        addressProvider = _addressProvider;
        setPoolService(_pool);
        creditConfigurator = CONFIGURATOR;
        underlying = IPoolV3(_pool).underlyingToken();
    }

    function setPriceOracle(address _priceOracle) external {
        priceOracle = _priceOracle;
    }

    function getTokenMaskOrRevert(address token) public view returns (uint256 tokenMask) {
        tokenMask = tokenMasksMap[token];
        if (tokenMask == 0) revert TokenNotAllowedException();
    }

    function setPoolService(address newPool) public {
        poolService = newPool;
        pool = newPool;
    }

    function setCreditFacade(address _creditFacade) external {
        creditFacade = _creditFacade;
    }

    /// @notice Outdated
    function lendCreditAccount(uint256 borrowedAmount, address ca) external {
        IPoolV3(poolService).lendCreditAccount(borrowedAmount, ca);
    }

    /// @notice Outdated
    function repayCreditAccount(uint256 borrowedAmount, uint256 profit, uint256 loss) external {
        IPoolV3(poolService).repayCreditAccount(borrowedAmount, profit, loss);
    }

    function setUpdateQuota(uint256 tokensToEnable, uint256 tokensToDisable) external {
        qu_tokensToEnable = tokensToEnable;
        qu_tokensToDisable = tokensToDisable;
    }

    function updateQuota(address, address, int96, uint96, uint96)
        external
        view
        returns (uint256 tokensToEnable, uint256 tokensToDisable)
    {
        tokensToEnable = qu_tokensToEnable;
        tokensToDisable = qu_tokensToDisable;
    }

    function addToken(address token, uint256 mask) external {
        tokenMasksMap[token] = mask;
        getTokenByMask[mask] = token;
    }

    function setBorrower(address _borrower) external {
        borrower = _borrower;
    }

    function getBorrowerOrRevert(address) external view returns (address) {
        if (borrower == address(0)) revert CreditAccountDoesNotExistException();
        return borrower;
    }

    function setReturnOpenCreditAccount(address _nextCreditAccount) external {
        nextCreditAccount = _nextCreditAccount;
    }

    function openCreditAccount(address) external view returns (address creditAccount) {
        return nextCreditAccount;
    }

    function setLiquidateCreditAccountReturns(uint256 remainingFunds, uint256 loss) external {
        return_remainingFunds = remainingFunds;
        return_loss = loss;
    }

    function closeCreditAccount(address) external {}

    function liquidateCreditAccount(address, CollateralDebtData memory collateralDebtData, address, bool)
        external
        returns (uint256 remainingFunds, uint256 loss)
    {
        _liquidateCollateralDebtData = collateralDebtData;
        remainingFunds = return_remainingFunds;
        loss = return_loss;
    }

    function fullCollateralCheck(address, uint256 enabledTokensMask, uint256[] memory, uint16, bool)
        external
        pure
        returns (uint256)
    {
        return enabledTokensMask;
    }

    function setRevertOnActiveAccount(bool _value) external {
        revertOnSetActiveAccount = _value;
    }

    function setActiveCreditAccount(address creditAccount) external {
        activeCreditAccount = creditAccount;
    }

    function getActiveCreditAccountOrRevert() external view returns (address) {
        if (revertOnSetActiveAccount) revert ActiveCreditAccountNotSetException();
        return activeCreditAccount;
    }

    function setQuotedTokensMask(uint256 _quotedTokensMask) external {
        quotedTokensMask = _quotedTokensMask;
    }

    function calcDebtAndCollateral(address, CollateralCalcTask) external view returns (CollateralDebtData memory) {
        return return_collateralDebtData;
    }

    function setDebtAndCollateralData(CollateralDebtData calldata _collateralDebtData) external {
        return_collateralDebtData = _collateralDebtData;
    }

    function liquidateCollateralDebtData() external view returns (CollateralDebtData memory) {
        return _liquidateCollateralDebtData;
    }

    function enabledTokensMaskOf(address) external view returns (uint256) {
        return _enabledTokensMask;
    }

    function setEnabledTokensMask(uint256 newEnabledTokensMask) external {
        _enabledTokensMask = newEnabledTokensMask;
    }

    function setContractAllowance(address adapter, address targetContract) external {
        adapterToContract[adapter] = targetContract;
        contractToAdapter[targetContract] = adapter;
    }

    function execute(bytes calldata data) external returns (bytes memory) {}

    /// FLAGS

    /// @notice Returns the mask containing miscellaneous account flags
    /// @dev Currently, the following flags are supported:
    ///      * 1 - BOT_PERMISSIONS_FLAG - whether the account has non-zero permissions for at least one bot
    function flagsOf(address) external view returns (uint16) {
        return flags;
    }

    /// @notice Sets a flag for a Credit Account
    /// @param creditAccount Account to set a flag for
    /// @param flag Flag to set
    /// @param value The new flag value
    function setFlagFor(address creditAccount, uint16 flag, bool value) external {
        if (value) {
            _enableFlag(creditAccount, flag);
        } else {
            _disableFlag(creditAccount, flag);
        }
    }

    /// @notice Sets the flag in the CA's flag mask to 1
    function _enableFlag(address, uint16 flag) internal {
        flags |= flag;
    }

    /// @notice Sets the flag in the CA's flag mask to 0
    function _disableFlag(address, uint16 flag) internal {
        flags &= ~flag;
    }

    function setManageDebt(uint256 newDebt) external {
        return_newDebt = newDebt;
    }

    function manageDebt(address, uint256, uint256, ManageDebtAction)
        external
        view
        returns (uint256, uint256, uint256)
    {
        return (return_newDebt, 0, 0);
    }

    function activateTransfers() external {
        _transfersActivated = true;
    }

    function deactivateTransfers() external {
        _transfersActivated = false;
    }

    function addCollateral(address payer, address creditAccount, address token, uint256 amount)
        external
        returns (uint256)
    {
        if (_transfersActivated) IERC20(token).safeTransferFrom(payer, creditAccount, amount);
        return 0;
    }

    function withdrawCollateral(address creditAccount, address token, uint256 amount, address to)
        external
        returns (uint256)
    {
        if (_transfersActivated) IERC20(token).safeTransferFrom(creditAccount, to, amount);
        return 0;
    }

    function fees() external pure returns (uint16, uint16, uint16, uint16, uint16) {
        return (
            DEFAULT_FEE_INTEREST,
            DEFAULT_FEE_LIQUIDATION,
            PERCENTAGE_FACTOR - DEFAULT_LIQUIDATION_PREMIUM,
            DEFAULT_FEE_LIQUIDATION_EXPIRED,
            PERCENTAGE_FACTOR - DEFAULT_LIQUIDATION_PREMIUM_EXPIRED
        );
    }
}
