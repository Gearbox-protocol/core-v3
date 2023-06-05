// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2023
pragma solidity ^0.8.17;
pragma abicoder v1;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

// INTERFACES
import {IAddressProviderV3, AP_TREASURY, NO_VERSION_CONTROL} from "../interfaces/IAddressProviderV3.sol";
import {ICreditManagerV3} from "../interfaces/ICreditManagerV3.sol";
import {IInterestRateModelV3} from "../interfaces/IInterestRateModelV3.sol";
import {IPoolQuotaKeeperV3} from "../interfaces/IPoolQuotaKeeperV3.sol";
import {IPoolV3} from "../interfaces/IPoolV3.sol";
import {IVersion} from "@gearbox-protocol/core-v2/contracts/interfaces/IVersion.sol";

// LIBS & TRAITS
import {CreditLogic} from "../libraries/CreditLogic.sol";
import {ACLNonReentrantTrait} from "../traits/ACLNonReentrantTrait.sol";
import {ContractsRegisterTrait} from "../traits/ContractsRegisterTrait.sol";

// CONSTANTS
import {
    RAY,
    MAX_WITHDRAW_FEE,
    SECONDS_PER_YEAR,
    PERCENTAGE_FACTOR
} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";

// EXCEPTIONS
import "../interfaces/IExceptions.sol";

/// @dev Struct that holds borrowed amount and debt limit
struct DebtParams {
    uint128 borrowed;
    uint128 limit;
}

/// @title Pool V3
/// @notice Pool contract that implements lending and borrowing logic, compatible with ERC-4626 standard
contract PoolV3 is ERC4626, ACLNonReentrantTrait, ContractsRegisterTrait, IPoolV3 {
    using Math for uint256;
    using SafeCast for int256;
    using SafeCast for uint256;
    using CreditLogic for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for IERC20;

    /// @inheritdoc IVersion
    uint256 public constant override version = 3_00;

    /// @inheritdoc IPoolV3
    address public immutable override addressProvider;

    /// @inheritdoc IPoolV3
    address public immutable override underlyingToken;

    /// @inheritdoc IPoolV3
    address public immutable override treasury;

    /// @inheritdoc IPoolV3
    bool public immutable override supportsQuotas;

    /// @inheritdoc IPoolV3
    address public override interestRateModel;
    /// @inheritdoc IPoolV3
    uint40 public override lastBaseInterestUpdate;
    /// @inheritdoc IPoolV3
    uint40 public override lastQuotaRevenueUpdate;
    /// @inheritdoc IPoolV3
    uint16 public override withdrawFee;

    /// @inheritdoc IPoolV3
    address public override poolQuotaKeeper;
    /// @dev Current quota revenue
    uint96 internal _quotaRevenue;

    /// @dev Current base interest rate in ray
    uint128 internal _baseInterestRate;
    /// @dev Cumulative base interest index stored as of last update in ray
    uint128 internal _baseInterestIndexLU;

    /// @dev Expected liquidity stored as of last update
    uint128 internal _expectedLiquidityLU;

    /// @dev Aggregate debt params
    DebtParams internal _totalDebt;

    /// @dev Mapping credit manager => debt params
    mapping(address => DebtParams) internal _creditManagerDebt;

    /// @dev List of all connected credit managers
    EnumerableSet.AddressSet internal _creditManagerSet;

    /// @dev Ensures that function can only be called by the pool quota keeper
    modifier poolQuotaKeeperOnly() {
        _revertIfCallerIsNotPoolQuotaKeeper();
        _;
    }

    function _revertIfCallerIsNotPoolQuotaKeeper() internal view {
        if (msg.sender != poolQuotaKeeper) revert CallerNotPoolQuotaKeeperException(); // U:[P4-5]
    }

    /// @notice Constructor
    /// @param addressProvider_ Address provider contract address
    /// @param underlyingToken_ Pool underlying token address
    /// @param interestRateModel_ Interest rate model contract address
    /// @param totalDebtLimit_ Initial total debt limit, `type(uint256).max` for no limit
    /// @param supportsQuotas_ Whether pool should support quotas
    /// @param namePrefix_ String to prefix underlying token name with to form pool token name
    /// @param symbolPrefix_ String to prefix underlying token symbol with to form pool token symbol
    constructor(
        address addressProvider_,
        address underlyingToken_,
        address interestRateModel_,
        uint256 totalDebtLimit_,
        bool supportsQuotas_,
        string memory namePrefix_,
        string memory symbolPrefix_
    )
        ACLNonReentrantTrait(addressProvider_)
        ContractsRegisterTrait(addressProvider_)
        ERC4626(IERC20(underlyingToken_))
        ERC20(
            string(abi.encodePacked(namePrefix_, underlyingToken_ != address(0) ? ERC20(underlyingToken_).name() : "")),
            string(abi.encodePacked(symbolPrefix_, underlyingToken_ != address(0) ? ERC20(underlyingToken_).symbol() : ""))
        ) // U:[P4-1]
        nonZeroAddress(underlyingToken_) // U:[P4-2]
        nonZeroAddress(interestRateModel_) // U:[P4-2]
    {
        addressProvider = addressProvider_; // U:[P4-1]
        underlyingToken = underlyingToken_; // U:[P4-1]

        treasury =
            IAddressProviderV3(addressProvider_).getAddressOrRevert({key: AP_TREASURY, _version: NO_VERSION_CONTROL}); // U:[P4-1]

        lastBaseInterestUpdate = uint40(block.timestamp); // U:[P4-1]
        _baseInterestIndexLU = uint128(RAY); // U:[P4-1]

        interestRateModel = interestRateModel_;
        emit SetInterestRateModel(interestRateModel_); // U:[P4-3]

        _setTotalDebtLimit(totalDebtLimit_); // U:[P4-3]
        supportsQuotas = supportsQuotas_; // U:[P4-1]
    }

    /// @inheritdoc IPoolV3
    function creditManagers() external view override returns (address[] memory) {
        return _creditManagerSet.values();
    }

    /// @inheritdoc IPoolV3
    function supplyRate() external view override returns (uint256) {
        uint256 assets = expectedLiquidity();
        uint256 baseInterestRate_ = baseInterestRate();
        if (assets == 0) return baseInterestRate_;
        return (baseInterestRate_ * _totalDebt.borrowed + quotaRevenue() * RAY) * (PERCENTAGE_FACTOR - withdrawFee)
            / PERCENTAGE_FACTOR / assets; // U:[P4-28]
    }

    /// @inheritdoc IPoolV3
    function availableLiquidity() public view override returns (uint256) {
        return IERC20(underlyingToken).balanceOf(address(this));
    }

    /// @inheritdoc IPoolV3
    function expectedLiquidity() public view override returns (uint256) {
        return _expectedLiquidityLU + _calcBaseInterestAccrued() + (supportsQuotas ? _calcQuotaRevenueAccrued() : 0);
    }

    /// @inheritdoc IPoolV3
    function expectedLiquidityLU() public view override returns (uint256) {
        return _expectedLiquidityLU;
    }

    // ---------------- //
    // ERC-4626 LENDING //
    // ---------------- //

    /// @inheritdoc IPoolV3
    function totalAssets() public view override(ERC4626, IPoolV3) returns (uint256 assets) {
        return expectedLiquidity();
    }

    /// @inheritdoc IPoolV3
    function deposit(uint256 assets, address receiver)
        public
        override(ERC4626, IPoolV3)
        whenNotPaused // U:[P4-4]
        nonReentrant
        nonZeroAddress(receiver)
        returns (uint256 shares)
    {
        uint256 assetsReceived = _amountMinusFee(assets); // U:[P4-5,7]
        shares = _convertToShares(assetsReceived, Math.Rounding.Down); // U:[P4-5,7]
        _deposit(receiver, assets, assetsReceived, shares); // U:[P4-5]
    }

    /// @inheritdoc IPoolV3
    function depositWithReferral(uint256 assets, address receiver, uint16 referralCode)
        external
        override
        returns (uint256 shares)
    {
        shares = deposit(assets, receiver); // U:[P4-5]
        emit Refer(receiver, referralCode, assets); // U:[P4-5]
    }

    /// @inheritdoc IPoolV3
    function mint(uint256 shares, address receiver)
        public
        override(ERC4626, IPoolV3)
        whenNotPaused // U:[P4-4]
        nonReentrant
        nonZeroAddress(receiver)
        returns (uint256 assets)
    {
        uint256 assetsReceived = _convertToAssets(shares, Math.Rounding.Up); // U:[P4-6,7]
        assets = _amountWithFee(assetsReceived); // U:[P4-6,7]
        _deposit(receiver, assets, assetsReceived, shares); // U:[P4-6,7]
    }

    /// @inheritdoc IPoolV3
    function withdraw(uint256 assets, address receiver, address owner)
        public
        override(ERC4626, IPoolV3)
        whenNotPaused // U:[P4-4]
        nonReentrant
        nonZeroAddress(receiver)
        returns (uint256 shares)
    {
        uint256 assetsSent = _amountWithWithdrawalFee(_amountWithFee(assets));
        shares = _convertToShares(assetsSent, Math.Rounding.Up); // U:[P4-8]
        _withdraw(receiver, owner, assetsSent, assets, shares); // U:[P4-8]
    }

    /// @inheritdoc IPoolV3
    function redeem(uint256 shares, address receiver, address owner)
        public
        override(ERC4626, IPoolV3)
        whenNotPaused // U:[P4-4]
        nonReentrant
        nonZeroAddress(receiver)
        returns (uint256 assets)
    {
        uint256 assetsSent = _convertToAssets(shares, Math.Rounding.Down); // U:[P4-9]
        assets = _amountMinusFee(_amountMinusWithdrawalFee(assetsSent)); // U:[P4-9]
        _withdraw(receiver, owner, assetsSent, assets, shares); // U:[P4-9]
    }

    /// @inheritdoc IPoolV3
    function previewDeposit(uint256 assets) public view override(ERC4626, IPoolV3) returns (uint256 shares) {
        shares = _convertToShares(_amountMinusFee(assets), Math.Rounding.Down);
    }

    /// @inheritdoc IPoolV3
    function previewMint(uint256 shares) public view override(ERC4626, IPoolV3) returns (uint256) {
        return _amountWithFee(_convertToAssets(shares, Math.Rounding.Up));
    }

    /// @inheritdoc IPoolV3
    function previewWithdraw(uint256 assets) public view override(ERC4626, IPoolV3) returns (uint256) {
        return _convertToShares(_amountWithWithdrawalFee(_amountWithFee(assets)), Math.Rounding.Up);
    }

    /// @inheritdoc IPoolV3
    function previewRedeem(uint256 shares) public view override(ERC4626, IPoolV3) returns (uint256) {
        return _amountMinusFee(_amountMinusWithdrawalFee(_convertToAssets(shares, Math.Rounding.Down)));
    }

    /// @inheritdoc IPoolV3
    function maxDeposit(address) public view override(ERC4626, IPoolV3) returns (uint256) {
        return paused() ? 0 : type(uint256).max;
    }

    /// @inheritdoc IPoolV3
    function maxMint(address) public view override(ERC4626, IPoolV3) returns (uint256) {
        return paused() ? 0 : type(uint256).max;
    }

    /// @inheritdoc IPoolV3
    function maxWithdraw(address owner) public view override(ERC4626, IPoolV3) returns (uint256) {
        return paused() ? 0 : Math.min(availableLiquidity(), _convertToAssets(balanceOf(owner), Math.Rounding.Down));
    }

    /// @inheritdoc IPoolV3
    function maxRedeem(address owner) public view override(ERC4626, IPoolV3) returns (uint256) {
        return paused() ? 0 : Math.min(balanceOf(owner), _convertToShares(availableLiquidity(), Math.Rounding.Down));
    }

    /// @notice `deposit` / `mint` implementation
    ///         - transfers underlying from the caller
    ///         - updates base interest rate and index
    ///         - mints pool shares to `receiver`
    function _deposit(address receiver, uint256 assetsSent, uint256 assetsReceived, uint256 shares) internal {
        IERC20(underlyingToken).safeTransferFrom({from: msg.sender, to: address(this), amount: assetsSent}); // U:[P4-5,6]

        _updateBaseInterest({
            expectedLiquidityDelta: assetsReceived.toInt256(),
            availableLiquidityDelta: 0,
            checkOptimalBorrowing: false
        }); // U:[P4-5,6]

        _mint(receiver, shares); // U:[P4-5,6]
        emit Deposit(msg.sender, receiver, assetsSent, shares); // U:[P4-5,6]
    }

    /// @notice `withdraw` / `redeem` implementation
    ///         - burns pool shares from `owner`
    ///         - updates base interest rate and index
    ///         - transfers underlying to `receiver` and, if withdrawal fee is activated, to the treasury
    function _withdraw(address receiver, address owner, uint256 assetsSent, uint256 assetsReceived, uint256 shares)
        internal
    {
        if (msg.sender != owner) _spendAllowance({owner: owner, spender: msg.sender, amount: shares}); // U:[P4-8,9]
        _burn(owner, shares); // U:[P4-8,9]

        _updateBaseInterest({
            expectedLiquidityDelta: -assetsSent.toInt256(),
            availableLiquidityDelta: -assetsSent.toInt256(),
            checkOptimalBorrowing: false
        }); // U:[P4-8,9]

        uint256 amountToUser = _amountWithFee(assetsReceived);
        IERC20(underlyingToken).safeTransfer({to: receiver, value: amountToUser}); // U:[P4-8,9]
        if (assetsSent > amountToUser) {
            unchecked {
                IERC20(underlyingToken).safeTransfer({to: treasury, value: assetsSent - amountToUser}); // U:[P4-8,9]
            }
        }
        emit Withdraw(msg.sender, receiver, owner, assetsReceived, shares); // U:[P4-8, 9]
    }

    // --------- //
    // BORROWING //
    // --------- //

    /// @inheritdoc IPoolV3
    function totalBorrowed() external view override returns (uint256) {
        return _totalDebt.borrowed;
    }

    /// @inheritdoc IPoolV3
    function totalDebtLimit() external view override returns (uint256) {
        return _convertToU256(_totalDebt.limit);
    }

    /// @inheritdoc IPoolV3
    function creditManagerBorrowed(address creditManager) external view override returns (uint256) {
        return _creditManagerDebt[creditManager].borrowed;
    }

    /// @inheritdoc IPoolV3
    function creditManagerDebtLimit(address creditManager) external view override returns (uint256) {
        return _convertToU256(_creditManagerDebt[creditManager].limit); // U:[P4-21]
    }

    /// @inheritdoc IPoolV3
    function creditManagerBorrowable(address creditManager) external view override returns (uint256 borrowable) {
        borrowable = _borrowable(_totalDebt); // U:[P4-27]
        if (borrowable == 0) return 0; // U:[P4-27]

        borrowable = Math.min(borrowable, _borrowable(_creditManagerDebt[creditManager])); // U:[P4-27]
        if (borrowable == 0) return 0; // U:[P4-27]

        uint256 available = IInterestRateModelV3(interestRateModel).availableToBorrow({
            expectedLiquidity: expectedLiquidity(),
            availableLiquidity: availableLiquidity()
        }); // U:[P4-27]

        borrowable = Math.min(borrowable, available); // U:[P4-27]
    }

    /// @inheritdoc IPoolV3
    function lendCreditAccount(uint256 borrowedAmount, address creditAccount)
        external
        override
        whenNotPaused // U:[P4-4]
        nonReentrant
    {
        uint128 borrowedAmountU128 = borrowedAmount.toUint128();

        DebtParams storage cmDebt = _creditManagerDebt[msg.sender];
        uint128 totalBorrowed_ = _totalDebt.borrowed + borrowedAmountU128;
        uint128 cmBorrowed_ = cmDebt.borrowed + borrowedAmountU128;
        if (borrowedAmount == 0 || cmBorrowed_ > cmDebt.limit || totalBorrowed_ > _totalDebt.limit) {
            revert CreditManagerCantBorrowException(); // U:[P4-12]
        }

        _updateBaseInterest({
            expectedLiquidityDelta: 0,
            availableLiquidityDelta: -borrowedAmount.toInt256(),
            checkOptimalBorrowing: true
        }); // U:[P4-11]

        cmDebt.borrowed = cmBorrowed_; // U:[P4-11]
        _totalDebt.borrowed = totalBorrowed_; // U:[P4-11]

        IERC20(underlyingToken).safeTransfer({to: creditAccount, value: borrowedAmount}); // U:[P4-11]
        emit Borrow(msg.sender, creditAccount, borrowedAmount); // U:[P4-11]
    }

    /// @inheritdoc IPoolV3
    function repayCreditAccount(uint256 repaidAmount, uint256 profit, uint256 loss)
        external
        override
        whenNotPaused // U:[P4-4]
        nonReentrant
    {
        uint128 repaidAmountU128 = repaidAmount.toUint128();

        DebtParams storage cmDebt = _creditManagerDebt[msg.sender];
        uint128 cmBorrowed = cmDebt.borrowed;
        if (cmBorrowed == 0) {
            revert CallerNotCreditManagerException(); // U:[P4-13]
        }

        if (profit > 0) {
            _mint(treasury, convertToShares(profit)); // U:[P4-14]
        } else if (loss > 0) {
            address treasury_ = treasury;
            uint256 sharesInTreasury = balanceOf(treasury_);
            uint256 sharesToBurn = convertToShares(loss);
            if (sharesToBurn > sharesInTreasury) {
                unchecked {
                    emit IncurUncoveredLoss({
                        creditManager: msg.sender,
                        loss: convertToAssets(sharesToBurn - sharesInTreasury)
                    }); // U:[P4-14]
                }
                sharesToBurn = sharesInTreasury;
            }
            _burn(treasury_, sharesToBurn); // U:[P4-14]
        }

        _updateBaseInterest({
            expectedLiquidityDelta: profit.toInt256() - loss.toInt256(),
            availableLiquidityDelta: 0,
            checkOptimalBorrowing: false
        }); // U:[P4-14]

        _totalDebt.borrowed -= repaidAmountU128; // U:[P4-14]
        cmDebt.borrowed = cmBorrowed - repaidAmountU128; // U:[P4-14]

        emit Repay(msg.sender, repaidAmount, profit, loss); // U:[P4-14]
    }

    /// @dev Returns borrowable amount based on debt limit and current borrowed amount
    function _borrowable(DebtParams storage debt) internal view returns (uint256) {
        uint256 limit = debt.limit;
        if (limit == type(uint128).max) {
            return type(uint256).max;
        }
        uint256 borrowed = debt.borrowed;
        if (borrowed >= limit) return 0;
        unchecked {
            return limit - borrowed;
        }
    }

    // ------------- //
    // INTEREST RATE //
    // ------------- //

    /// @inheritdoc IPoolV3
    function baseInterestRate() public view override returns (uint256) {
        return _baseInterestRate;
    }

    /// @inheritdoc IPoolV3
    function baseInterestIndex() public view override returns (uint256) {
        uint256 timestampLU = lastBaseInterestUpdate;
        if (block.timestamp == timestampLU) return _baseInterestIndexLU; // U:[P4-15]
        return _calcBaseInterestIndex(timestampLU); // U:[P4-15]
    }

    /// @inheritdoc IPoolV3
    function calcLinearCumulative_RAY() external view override returns (uint256) {
        return baseInterestIndex(); // U:[P4-15]
    }

    /// @inheritdoc IPoolV3
    function baseInterestIndexLU() external view override returns (uint256) {
        return _baseInterestIndexLU;
    }

    /// @dev Computes base interest accrued since the last update
    function _calcBaseInterestAccrued() internal view returns (uint256) {
        uint256 timestampLU = lastBaseInterestUpdate;
        if (block.timestamp == timestampLU) return 0;
        return _calcBaseInterestAccrued(timestampLU);
    }

    /// @dev Adds accrued base interest to expected liquidity, then updates base interest rate and index
    function _updateBaseInterest(
        int256 expectedLiquidityDelta,
        int256 availableLiquidityDelta,
        bool checkOptimalBorrowing
    ) internal {
        uint256 expectedLiquidity_ = (expectedLiquidityLU().toInt256() + expectedLiquidityDelta).toUint256(); // U:[P4-16]
        uint256 availableLiquidity_ = (availableLiquidity().toInt256() + availableLiquidityDelta).toUint256(); // U:[P4-16]

        uint256 timestampLU = lastBaseInterestUpdate;
        if (block.timestamp != timestampLU) {
            expectedLiquidity_ += _calcBaseInterestAccrued(timestampLU); // U:[P4-16]
            _baseInterestIndexLU = _calcBaseInterestIndex(timestampLU).toUint128(); // U:[P4-16]
            lastBaseInterestUpdate = uint40(block.timestamp); // U:[P4-16]
        }

        _expectedLiquidityLU = expectedLiquidity_.toUint128(); // U:[P4-16]
        _baseInterestRate = IInterestRateModelV3(interestRateModel).calcBorrowRate({
            expectedLiquidity: expectedLiquidity_ + (supportsQuotas ? _calcQuotaRevenueAccrued() : 0),
            availableLiquidity: availableLiquidity_,
            checkOptimalBorrowing: checkOptimalBorrowing
        }).toUint128(); // U:[P4-16]
    }

    /// @dev Computes base interest accrued since given timestamp
    function _calcBaseInterestAccrued(uint256 timestamp) private view returns (uint256) {
        return _totalDebt.borrowed * baseInterestRate().calcLinearGrowth(timestamp) / RAY;
    }

    /// @dev Computes current value of base interest index
    function _calcBaseInterestIndex(uint256 timestamp) private view returns (uint256) {
        return _baseInterestIndexLU * (RAY + baseInterestRate().calcLinearGrowth(timestamp)) / RAY;
    }

    // ------ //
    // QUOTAS //
    // ------ //

    /// @inheritdoc IPoolV3
    function quotaRevenue() public view override returns (uint256) {
        return _quotaRevenue;
    }

    /// @inheritdoc IPoolV3
    function updateQuotaRevenue(int256 quotaRevenueDelta) external override nonReentrant poolQuotaKeeperOnly {
        _setQuotaRevenue((quotaRevenue().toInt256() + quotaRevenueDelta).toUint256()); // U:[P4-17]
    }

    /// @inheritdoc IPoolV3
    function setQuotaRevenue(uint256 newQuotaRevenue) external override nonReentrant poolQuotaKeeperOnly {
        _setQuotaRevenue(newQuotaRevenue); // U:[P4-17]
    }

    /// @dev Computes quota revenue accrued since the last update
    function _calcQuotaRevenueAccrued() internal view returns (uint256) {
        uint256 timestampLU = lastQuotaRevenueUpdate;
        if (block.timestamp == timestampLU) return 0; // U:[P4-17]
        return _calcQuotaRevenueAccrued(timestampLU); // U:[P4-17]
    }

    /// @dev Adds accrued quota revenue to the expected liquidity, then sets new quota revenue
    function _setQuotaRevenue(uint256 newQuotaRevenue) internal {
        uint256 timestampLU = lastQuotaRevenueUpdate;
        if (block.timestamp != timestampLU) {
            _expectedLiquidityLU += _calcQuotaRevenueAccrued(timestampLU).toUint128(); // U:[P4-17]
            lastQuotaRevenueUpdate = uint40(block.timestamp); // U:[P4-17]
        }
        _quotaRevenue = newQuotaRevenue.toUint96(); // U:[P4-17]
    }

    /// @dev Computes quota revenue accrued since given timestamp
    function _calcQuotaRevenueAccrued(uint256 timestamp) private view returns (uint256) {
        return quotaRevenue().calcLinearGrowth(timestamp);
    }

    // ------------- //
    // CONFIGURATION //
    // ------------- //

    /// @inheritdoc IPoolV3
    function setInterestRateModel(address newInterestRateModel)
        external
        override
        configuratorOnly // U:[P4-18]
        nonZeroAddress(newInterestRateModel)
    {
        interestRateModel = newInterestRateModel; // U:[P4-22]
        _updateBaseInterest(0, 0, false); // U:[P4-22]
        emit SetInterestRateModel(newInterestRateModel); // U:[P4-22]
    }

    /// @inheritdoc IPoolV3
    function setPoolQuotaKeeper(address newPoolQuotaKeeper)
        external
        override
        configuratorOnly // U:[P4-18]
        nonZeroAddress(newPoolQuotaKeeper)
    {
        if (!supportsQuotas) {
            revert QuotasNotSupportedException(); // U:[P4-23A]
        }
        if (IPoolQuotaKeeperV3(newPoolQuotaKeeper).pool() != address(this)) {
            revert IncompatiblePoolQuotaKeeperException(); // U:[P4-23B]
        }

        poolQuotaKeeper = newPoolQuotaKeeper; // U:[P4-23C]

        uint256 newQuotaRevenue = IPoolQuotaKeeperV3(poolQuotaKeeper).poolQuotaRevenue();
        _setQuotaRevenue(newQuotaRevenue); // U:[P4-23C]

        emit SetPoolQuotaKeeper(newPoolQuotaKeeper); // U:[P4-23C]
    }

    /// @inheritdoc IPoolV3
    function setTotalDebtLimit(uint256 newLimit)
        external
        override
        controllerOnly // U:[P4-18]
    {
        _setTotalDebtLimit(newLimit); // U:[P4-25]
    }

    /// @inheritdoc IPoolV3
    function setCreditManagerDebtLimit(address creditManager, uint256 newLimit)
        external
        override
        controllerOnly // U:[P4-18]
        nonZeroAddress(creditManager)
        registeredCreditManagerOnly(creditManager)
    {
        if (!_creditManagerSet.contains(creditManager)) {
            if (address(this) != ICreditManagerV3(creditManager).pool()) {
                revert IncompatibleCreditManagerException(); // U:[P4-20]
            }
            _creditManagerSet.add(creditManager); // U:[P4-21]
            emit AddCreditManager(creditManager); // U:[P4-21]
        }
        _creditManagerDebt[creditManager].limit = _convertToU128(newLimit); // U:[P4-21]
        emit SetCreditManagerDebtLimit(creditManager, newLimit); // U:[P4-21]
    }

    /// @inheritdoc IPoolV3
    function setWithdrawFee(uint256 newWithdrawFee)
        external
        override
        controllerOnly // U:[P4-18]
    {
        if (newWithdrawFee > MAX_WITHDRAW_FEE) {
            revert IncorrectParameterException(); // U:[P4-26]
        }
        withdrawFee = newWithdrawFee.toUint16(); // U:[P4-26]
        emit SetWithdrawFee(newWithdrawFee); // U:[P4-26]
    }

    /// @dev Sets new total debt limit
    function _setTotalDebtLimit(uint256 limit) internal {
        _totalDebt.limit = _convertToU128(limit); // U:[P4-25]
        emit SetTotalDebtLimit(limit); // U:[P4-3,25]
    }

    // --------- //
    // INTERNALS //
    // --------- //

    /// @dev Returns amount of token that should be transferred to receive `amount`
    ///      Pools with fee-on-transfer underlying should override this method
    function _amountWithFee(uint256 amount) internal view virtual returns (uint256) {
        return amount;
    }

    /// @dev Returns amount of token that will be received if `amount` is transferred
    ///      Pools with fee-on-transfer underlying should override this method
    function _amountMinusFee(uint256 amount) internal view virtual returns (uint256) {
        return amount;
    }

    /// @dev Returns amount of token that should be withdrawn so that `amount` is actually sent to the receiver
    function _amountWithWithdrawalFee(uint256 amount) internal view returns (uint256) {
        return amount * PERCENTAGE_FACTOR / (PERCENTAGE_FACTOR - withdrawFee);
    }

    /// @dev Returns amount of token that would actually be sent to the receiver when withdrawing `amount`
    function _amountMinusWithdrawalFee(uint256 amount) internal view returns (uint256) {
        return amount * (PERCENTAGE_FACTOR - withdrawFee) / PERCENTAGE_FACTOR;
    }

    /// @dev Converts `uint128` to `uint256`, preserves maximum value
    function _convertToU256(uint128 limit) internal pure returns (uint256) {
        return (limit == type(uint128).max) ? type(uint256).max : limit;
    }

    /// @dev Converts `uint256` to `uint128`, preserves maximum value
    function _convertToU128(uint256 limit) internal pure returns (uint128) {
        return (limit == type(uint256).max) ? type(uint128).max : limit.toUint128();
    }
}
