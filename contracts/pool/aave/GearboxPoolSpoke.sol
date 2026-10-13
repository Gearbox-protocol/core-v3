// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2026.
pragma solidity ^0.8.17;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {ReentrancyGuardTrait} from "../../traits/ReentrancyGuardTrait.sol";
import {SanityCheckTrait} from "../../traits/SanityCheckTrait.sol";
import {ACLTrait} from "../../traits/ACLTrait.sol";

import {ICreditManagerV3} from "../../interfaces/ICreditManagerV3.sol";
import {CreditLogic} from "../../libraries/CreditLogic.sol";
import {PERCENTAGE_FACTOR, RAY} from "../../libraries/Constants.sol";
import {
    QuotaIsOutOfBoundsException,
    TokenIsNotQuotedException,
    ZeroAddressException
} from "../../interfaces/IExceptions.sol";

import {IHubBase} from "./IHubBase.sol";

struct CreditAccountData {
    int256 premiumOffset;
    uint16 lastRiskPremium;
    mapping(address token => bool isEnabled) isTokenEnabled;
}

/// @title GearboxPoolSpoke
/// @notice Prototype pool and quota keeper that borrows one hub asset for Gearbox credit managers.
///         Collateral and solvency stay in the credit manager. The spoke does not take deposits.
/// @dev The active credit account is read from `CreditManager.getActiveCreditAccountOrRevert`.
///      Setting that account is left to a later facade change.
contract GearboxPoolSpoke is ReentrancyGuardTrait, SanityCheckTrait, ACLTrait {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeCast for uint256;

    struct CreditManagerParams {
        address primaryToken;
        uint16 riskPremium;
        uint256 drawnShares;
        bool registered;
    }

    struct AccountState {
        uint256 debt;
        uint256 indexLU;
        uint256 totalPremium;
        uint256 indexNow;
        uint16 riskPremium;
        int256 premiumOffset;
        uint16 feeInterest;
    }

    IHubBase public immutable hub;
    uint256 public immutable assetId;
    address public immutable underlying;
    address public immutable treasury;

    mapping(address creditManager => CreditManagerParams) internal _creditManagers;
    mapping(address creditAccount => CreditAccountData) internal _creditAccountData;

    EnumerableSet.AddressSet internal _quotedTokens;
    EnumerableSet.AddressSet internal _managers;

    address public repayingCreditAccount;

    error ActiveCreditAccountMismatchException();
    error CreditManagerNotRegisteredException();
    error InsufficientRepaymentException();
    error NoCreditAccountToRepayException();

    modifier onlyCreditManager() {
        if (!_creditManagers[msg.sender].registered) revert CreditManagerNotRegisteredException();
        _;
    }

    constructor(address _acl, address hub_, address underlying_, address treasury_) ACLTrait(_acl) {
        if (hub_ == address(0) || underlying_ == address(0) || treasury_ == address(0)) {
            revert ZeroAddressException();
        }
        hub = IHubBase(hub_);
        assetId = IHubBase(hub_).getAssetId(underlying_);
        underlying = underlying_;
        treasury = treasury_;
    }

    // --------------- //
    // POOL SURFACE    //
    // --------------- //

    function underlyingToken() external view returns (address) {
        return underlying;
    }

    function poolQuotaKeeper() external view returns (address) {
        return address(this);
    }

    function baseInterestIndex() public view returns (uint256) {
        return hub.getAssetDrawnIndex(assetId);
    }

    function lendCreditAccount(uint256 borrowedAmount, address creditAccount) external nonReentrant onlyCreditManager {
        if (borrowedAmount == 0) revert InsufficientRepaymentException();
        address creditManager = msg.sender;
        if (creditAccount != ICreditManagerV3(creditManager).getActiveCreditAccountOrRevert()) {
            revert ActiveCreditAccountMismatchException();
        }

        AccountState memory accountBefore = _loadAccount(creditManager, creditAccount);
        AccountState memory accountAfter = _calcStateIncrease(creditManager, accountBefore, borrowedAmount);

        _creditAccountData[creditAccount].lastRiskPremium = accountAfter.riskPremium;
        _creditAccountData[creditAccount].premiumOffset = accountAfter.premiumOffset;

        hub.draw(assetId, borrowedAmount, creditAccount);

        _refreshPremium(_getPremiumSharesDelta(accountBefore, accountAfter), 0, accountAfter.indexNow);
    }

    function repayCreditAccount(uint256 repaidAmount, uint256 profit, uint256 loss)
        external
        nonReentrant
        onlyCreditManager
    {
        address creditManager = msg.sender;

        if (repayingCreditAccount == address(0)) revert NoCreditAccountToRepayException();

        address creditAccount = repayingCreditAccount;
        uint256 totalAmount = IERC20(underlying).balanceOf(address(this));

        AccountState memory accountBefore = _loadAccount(creditManager, creditAccount);

        /// Full repayment (which includes full liquidations - the only case where loss can be non-zero)
        if (repaidAmount == accountBefore.debt) {
            uint256 premiumDebt = _calcPremiumDebt(accountBefore);
            uint256 premiumShares = _getAccountPremiumShares(accountBefore);

            IHubBase.PremiumDelta memory premiumDelta;

            uint256 drawnAmount = totalAmount - premiumDebt - profit;

            if (loss > 0) {
                (uint256 lostPremium, uint256 lostDrawnAmount) = _applyLoss(premiumDebt, drawnAmount, loss);

                premiumDelta = _getPremiumDelta(-premiumShares.toInt256(), lostPremium, accountBefore.indexNow);

                hub.reportDeficit(assetId, lostDrawnAmount, premiumDelta);

                if (drawnAmount > lostDrawnAmount) {
                    premiumDelta = _getPremiumDelta(0, premiumDebt - lostPremium, accountBefore.indexNow);
                    _sendAndRestore(drawnAmount - lostDrawnAmount, premiumDebt - lostPremium, premiumDelta);
                }
            } else {
                premiumDelta = _getPremiumDelta(-premiumShares.toInt256(), premiumDebt, accountBefore.indexNow);
                _sendAndRestore(drawnAmount, premiumDebt, premiumDelta);
            }

            _creditAccountData[creditAccount].lastRiskPremium = _creditManagers[creditManager].riskPremium;
            _creditAccountData[creditAccount].premiumOffset = 0;
        } else {
            AccountState memory accountAfter = _calcStateDecrease(creditManager, accountBefore, totalAmount);

            (uint256 premiumPaid, uint256 drawnPaid) = _calcRepayments(accountBefore, accountAfter, totalAmount);

            IHubBase.PremiumDelta memory premiumDelta = _getPremiumDelta(
                _getPremiumSharesDelta(accountBefore, accountAfter), premiumPaid, accountAfter.indexNow
            );

            _sendAndRestore(drawnPaid, premiumPaid, premiumDelta);

            _creditAccountData[creditAccount].lastRiskPremium = _creditManagers[creditManager].riskPremium;
            _creditAccountData[creditAccount].premiumOffset = accountAfter.premiumOffset;
        }

        if (profit != 0) IERC20(underlying).safeTransfer(treasury, profit);

        repayingCreditAccount = address(0);
    }

    // --------------- //
    // QUOTA KEEPER    //
    // --------------- //

    function isQuotedToken(address token) external view returns (bool) {
        return _quotedTokens.contains(token);
    }

    function getQuotaAndOutstandingInterest(address creditAccount, address token)
        external
        view
        onlyCreditManager
        returns (uint96 quoted, uint128 outstandingInterest)
    {
        quoted = _creditAccountData[creditAccount].isTokenEnabled[token] ? type(uint96).max : 0;
        if (token == _creditManagers[msg.sender].primaryToken) {
            AccountState memory account = _loadAccount(msg.sender, creditAccount);
            (,, uint128 accruedQuotaInterest,,,,,) = ICreditManagerV3(msg.sender).creditAccountInfo(creditAccount);
            outstandingInterest = _calcPremiumDebt(account).toUint128() - accruedQuotaInterest;
        }
    }

    function updateQuota(address creditAccount, address token, int96 requestedChange, uint96, uint96)
        external
        onlyCreditManager
        returns (uint128 caQuotaInterestChange, uint128 fees, bool enableToken, bool disableToken)
    {
        if (!_quotedTokens.contains(token)) revert TokenIsNotQuotedException();

        bool isEnabled = _creditAccountData[creditAccount].isTokenEnabled[token];
        bool newEnabled = requestedChange > type(int96).min;

        _creditAccountData[creditAccount].isTokenEnabled[token] = newEnabled;

        return (0, 0, !isEnabled && newEnabled, isEnabled && !newEnabled);
    }

    function accrueQuotaInterest(address creditAccount, address[] calldata) external onlyCreditManager {
        repayingCreditAccount = creditAccount;
    }

    function removeQuotas(address creditAccount, address[] calldata tokens, bool) external onlyCreditManager {
        for (uint256 i; i < tokens.length; ++i) {
            _creditAccountData[creditAccount].isTokenEnabled[tokens[i]] = false;
        }
        repayingCreditAccount = creditAccount;
    }

    // --------------- //
    // CURATOR         //
    // --------------- //

    function addCreditManager(address creditManager, address primaryToken, uint16 riskPremium)
        external
        configuratorOnly
    {
        if (creditManager == address(0) || primaryToken == address(0)) revert ZeroAddressException();
        if (_creditManagers[creditManager].registered) revert CreditManagerNotRegisteredException();
        _creditManagers[creditManager] = CreditManagerParams({
            primaryToken: primaryToken, riskPremium: riskPremium, drawnShares: 0, registered: true
        });
        _quotedTokens.add(primaryToken);
        _managers.add(creditManager);
    }

    function addQuotaToken(address token) external configuratorOnly {
        if (token == address(0)) revert ZeroAddressException();
        _quotedTokens.add(token);
    }

    /// @notice Updates one manager's risk premium.
    /// @dev    In order to avoid unbounded gas consumption, risk updates are `lazy` - they are not applied
    ///         to accounts until they change they increase or decrease debt.
    function setRiskPremium(address creditManager, uint16 newRiskPremium) external configuratorOnly {
        CreditManagerParams storage params = _creditManagers[creditManager];
        if (!params.registered) revert CreditManagerNotRegisteredException();

        params.riskPremium = newRiskPremium;
    }

    /// TODO: revert on amount > deficit
    /// TODO: consider auto-coverage in `repayCreditAccount` instead of manual
    /// @notice Pulls `amount` from the treasury, mints hub supply shares, and burns them to clear this spoke's deficit.
    function eliminateDeficit(uint256 amount) external configuratorOnly {
        IERC20(underlying).safeTransferFrom(treasury, address(hub), amount);
        hub.add(assetId, amount);
        hub.eliminateDeficit(assetId, amount, address(this));

        uint256 leftover = hub.getSpokeAddedShares(assetId, address(this));
        if (leftover != 0) {
            uint256 assets = hub.previewRemoveByShares(assetId, leftover);
            if (assets != 0) hub.remove(assetId, assets, treasury);
        }
    }

    // --------------- //
    // ACCOUNT STATE   //
    // --------------- //

    /// @dev Memory assignment aliases structs, so snapshots have to be copied field by field.
    function _clone(AccountState memory state) internal pure returns (AccountState memory copy) {
        copy.debt = state.debt;
        copy.indexLU = state.indexLU;
        copy.indexNow = state.indexNow;
        copy.riskPremium = state.riskPremium;
        copy.premiumOffset = state.premiumOffset;
        copy.feeInterest = state.feeInterest;
        copy.totalPremium = state.totalPremium;
    }

    function _loadAccount(address creditManager, address creditAccount)
        internal
        view
        returns (AccountState memory state)
    {
        uint128 accruedQuotaInterest;
        (state.debt, state.indexLU, accruedQuotaInterest,,,,,) =
            ICreditManagerV3(creditManager).creditAccountInfo(creditAccount);
        state.indexNow = baseInterestIndex();
        state.riskPremium = _creditAccountData[creditAccount].lastRiskPremium;
        state.premiumOffset = _creditAccountData[creditAccount].premiumOffset;
        (state.feeInterest,,,,) = ICreditManagerV3(creditManager).fees();
        state.totalPremium = _calcPremiumDebt(state);
    }

    function _calcStateIncrease(address creditManager, AccountState memory accountBefore, uint256 borrowedAmount)
        internal
        view
        returns (AccountState memory accountAfter)
    {
        accountAfter = _clone(accountBefore);
        (accountAfter.debt, accountAfter.indexLU) =
            CreditLogic.calcIncrease(borrowedAmount, accountBefore.debt, accountBefore.indexNow, accountBefore.indexLU);
        accountAfter.riskPremium = _creditManagers[creditManager].riskPremium;
        accountAfter.totalPremium = accountBefore.totalPremium;
        accountAfter.premiumOffset =
            accountBefore.premiumOffset + _calcPremiumOffsetDelta(accountBefore, accountAfter, 0);
    }

    function _calcStateDecrease(address creditManager, AccountState memory accountBefore, uint256 amount)
        internal
        view
        returns (AccountState memory accountAfter)
    {
        accountAfter = _clone(accountBefore);
        (accountAfter.debt, accountAfter.indexLU,, accountAfter.totalPremium,) = CreditLogic.calcDecrease(
            amount,
            accountBefore.debt,
            accountBefore.indexNow,
            accountBefore.indexLU,
            accountBefore.totalPremium.toUint128(),
            0,
            accountBefore.feeInterest
        );
        accountAfter.riskPremium = _creditManagers[creditManager].riskPremium;
        accountAfter.premiumOffset = accountBefore.premiumOffset
            + _calcPremiumOffsetDelta(
                accountBefore, accountAfter, accountAfter.totalPremium - accountBefore.totalPremium
            );
    }

    function _calcPremiumOffsetDelta(
        AccountState memory accountBefore,
        AccountState memory accountAfter,
        uint256 premiumPaid
    ) internal pure returns (int256) {
        uint256 baseAfter =
            accountAfter.riskPremium * accountAfter.debt / PERCENTAGE_FACTOR;
        uint256 nonOffsetDebtAfter = baseAfter * accountAfter.indexNow / accountAfter.indexLU;

        return accountBefore.totalPremium.toInt256() - nonOffsetDebtAfter.toInt256() - premiumPaid.toInt256();
    }

    function _calcPremiumDebt(AccountState memory account) internal pure returns (uint256 premiumDebt) {
        if (account.debt == 0) return 0;

        uint256 debtBase = account.riskPremium * account.debt / PERCENTAGE_FACTOR;
        uint256 nonOffsetDebt = debtBase * account.indexNow / account.indexLU;
        premiumDebt = uint256(nonOffsetDebt.toInt256() + account.premiumOffset);
    }

    function _calcRepayments(AccountState memory accountBefore, AccountState memory accountAfter, uint256 amount)
        internal
        pure
        returns (uint256 premiumPaid, uint256 drawnPaid)
    {
        premiumPaid = accountAfter.totalPremium - accountBefore.totalPremium;
        drawnPaid = amount - premiumPaid;
    }

    function _applyLoss(uint256 premiumDebt, uint256 drawnAmount, uint256 loss)
        internal
        pure
        returns (uint256 lostPremium, uint256 lostDrawnAmount)
    {
        uint256 remainingLoss = loss;
        (remainingLoss, lostPremium) =
            remainingLoss > premiumDebt ? (remainingLoss - premiumDebt, premiumDebt) : (0, remainingLoss);
        (remainingLoss, lostDrawnAmount) =
            remainingLoss > drawnAmount ? (remainingLoss - drawnAmount, drawnAmount) : (0, remainingLoss);
        return (lostPremium, lostDrawnAmount);
    }

    // --------------- //
    // HUB SYNC        //
    // --------------- //

    function _sendAndRestore(uint256 drawnAmount, uint256 premiumAmount, IHubBase.PremiumDelta memory premiumDelta)
        internal
    {
        IERC20(underlying).safeTransfer(address(hub), drawnAmount + premiumAmount);
        hub.restore(assetId, drawnAmount, premiumDelta);
    }

    /// @dev Refreshes this Spoke's total premium in the Hub, based on account's update
    function _refreshPremium(int256 premiumSharesDelta, uint256 restoredAssets, uint256 indexNow) internal {
        IHubBase.PremiumDelta memory delta = _getPremiumDelta(premiumSharesDelta, restoredAssets, indexNow);
        hub.refreshPremium(assetId, delta);
    }

    function _getPremiumDelta(int256 premiumSharesDelta, uint256 restoredAssets, uint256 indexNow)
        internal
        view
        returns (IHubBase.PremiumDelta memory delta)
    {
        (uint256 oldShares, int256 oldOffset) = hub.getSpokePremiumData(assetId, address(this));

        uint256 oldPremiumRay = uint256((oldShares * indexNow).toInt256() - oldOffset);
        uint256 restoredRay = restoredAssets * RAY;

        if (restoredRay > oldPremiumRay) restoredRay = oldPremiumRay;

        int256 offsetRayDelta = premiumSharesDelta * indexNow.toInt256() + restoredRay.toInt256();

        delta = IHubBase.PremiumDelta({
            sharesDelta: premiumSharesDelta, offsetRayDelta: offsetRayDelta, restoredPremiumRay: restoredRay
        });
    }

    /// @dev Computes the change in premium shares after updating an account
    /// @dev Update is comprised of two elements:
    ///      - Change in shares due to change in risk premium (computed as `previousDrawnShares * premiumDelta`);
    ///      - Change in shares due to change in debt (computed as `drawnSharesDelta * currentPremium`);
    function _getPremiumSharesDelta(AccountState memory accountBefore, AccountState memory accountAfter)
        internal
        pure
        returns (int256)
    {
        int256 premiumDelta =
            uint256(accountAfter.riskPremium).toInt256() - uint256(accountBefore.riskPremium).toInt256();
        int256 debtDelta = accountAfter.debt.toInt256() - accountBefore.debt.toInt256();
        return _toSharesDown(premiumDelta * accountBefore.debt.toInt256(), accountBefore.indexLU)
            + _toSharesDown(int16(accountAfter.riskPremium) * debtDelta, accountBefore.indexNow);
    }

    function _getAccountPremiumShares(AccountState memory account) internal pure returns (uint256) {
        return _toSharesDown(account.riskPremium * account.debt, account.indexLU);
    }

    function _toSharesDown(int256 assets, uint256 indexNow) internal pure returns (int256) {
        bool isNegative = assets < 0;
        uint256 absAssets = isNegative ? uint256(-assets) : uint256(assets);
        uint256 absShares = _toSharesDown(absAssets, indexNow);
        return isNegative ? -absShares.toInt256() : absShares.toInt256();
    }

    function _toSharesDown(uint256 assets, uint256 indexNow) internal pure returns (uint256) {
        if (assets == 0) return 0;
        return Math.mulDiv(assets, RAY, indexNow, Math.Rounding.Down);
    }
}
