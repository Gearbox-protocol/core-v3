// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import "../../../interfaces/IAddressProviderV3.sol";

import {
    ICreditManagerV3,
    CollateralDebtData,
    CollateralCalcTask,
    ManageDebtAction,
    RevocationPair
} from "../../../interfaces/ICreditManagerV3.sol";
import {IPoolV3} from "../../../interfaces/IPoolV3.sol";

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

    /// @dev Address of withdrawal manager
    address public withdrawalManager;

    mapping(address => uint256) public tokenMasksMap;
    mapping(uint256 => address) public getTokenByMask;

    address public creditFacade;

    address public creditConfigurator;
    address borrower;
    uint256 public quotedTokensMask;

    CollateralDebtData return_collateralDebtData;

    CollateralDebtData _liquidateCollateralDebtData;
    bool _liquidateIsExpired;
    uint256 internal _enabledTokensMask;

    address nextCreditAccount;
    uint256 cw_return_tokensToEnable;

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
    uint256 md_return_tokensToEnable;
    uint256 md_return_tokensToDisable;

    uint256 ad_tokenMask;

    int96 qu_change;
    uint256 qu_tokensToEnable;
    uint256 qu_tokensToDisable;

    uint256 sw_tokensToDisable;

    constructor(address _addressProvider, address _pool) {
        addressProvider = _addressProvider;
        setPoolService(_pool);
        creditConfigurator = CONFIGURATOR;
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

    function liquidateCreditAccount(address, CollateralDebtData memory collateralDebtData, address, bool isExpired)
        external
        returns (uint256 remainingFunds, uint256 loss)
    {
        _liquidateCollateralDebtData = collateralDebtData;
        _liquidateIsExpired = isExpired;
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

    function liquidateIsExpired() external view returns (bool) {
        return _liquidateIsExpired;
    }

    function enabledTokensMaskOf(address) external view returns (uint256) {
        return _enabledTokensMask;
    }

    function setEnabledTokensMask(uint256 newEnabledTokensMask) external {
        _enabledTokensMask = newEnabledTokensMask;
    }

    function setContractAllowance(address adapter, address targetContract) external {
        adapterToContract[adapter] = targetContract; // U:[CM-45]
        contractToAdapter[targetContract] = adapter; // U:[CM-45]
    }

    function execute(bytes calldata data) external returns (bytes memory) {}

    /// FLAGS

    /// @notice Returns the mask containing miscellaneous account flags
    /// @dev Currently, the following flags are supported:
    ///      * 1 - BOT_PERMISSIONS_FLAG - whether the account has non-zero permissions for at least one bot
    function flagsOf(address) external view returns (uint16) {
        return flags; // U:[CM-35]
    }

    /// @notice Sets a flag for a Credit Account
    /// @param creditAccount Account to set a flag for
    /// @param flag Flag to set
    /// @param value The new flag value
    function setFlagFor(address creditAccount, uint16 flag, bool value) external {
        if (value) {
            _enableFlag(creditAccount, flag); // U:[CM-36]
        } else {
            _disableFlag(creditAccount, flag); // U:[CM-36]
        }
    }

    /// @notice Sets the flag in the CA's flag mask to 1
    function _enableFlag(address, uint16 flag) internal {
        flags |= flag; // U:[CM-36]
    }

    /// @notice Sets the flag in the CA's flag mask to 0
    function _disableFlag(address, uint16 flag) internal {
        flags &= ~flag; // U:[CM-36]
    }

    function setAddCollateral(uint256 tokenMask) external {
        ad_tokenMask = tokenMask;
    }

    function addCollateral(address, address, address, uint256) external view returns (uint256 tokenMask) {
        tokenMask = ad_tokenMask;
    }

    function setManageDebt(uint256 newDebt, uint256 tokensToEnable, uint256 tokensToDisable) external {
        return_newDebt = newDebt;
        md_return_tokensToEnable = tokensToEnable;
        md_return_tokensToDisable = tokensToDisable;
    }

    function manageDebt(address, uint256, uint256, ManageDebtAction)
        external
        view
        returns (uint256 newDebt, uint256 tokensToEnable, uint256 tokensToDisable)
    {
        newDebt = return_newDebt;
        tokensToEnable = md_return_tokensToEnable;
        tokensToDisable = md_return_tokensToDisable;
    }

    function setWithdrawCollateral(uint256 tokensToDisable) external {
        sw_tokensToDisable = tokensToDisable;
    }

    function withdrawCollateral(address, address, uint256, address) external view returns (uint256 tokensToDisable) {
        tokensToDisable = sw_tokensToDisable;
    }

    function revokeAdapterAllowances(address creditAccount, RevocationPair[] calldata revocations) external {}
}
