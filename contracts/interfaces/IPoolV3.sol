// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2023
pragma solidity ^0.8.17;
pragma abicoder v1;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {IVersion} from "./IVersion.sol";

/// @title Pool base interface
/// @notice Functions shared accross newer and older versions
interface IPoolBase is IVersion {
    function addressProvider() external view returns (address);
    function underlyingToken() external view returns (address);
    function calcLinearCumulative_RAY() external view returns (uint256);
    function lendCreditAccount(uint256 borrowedAmount, address creditAccount) external;
    function repayCreditAccount(uint256 borrowedAmount, uint256 profit, uint256 loss) external;
}

interface IPoolV3Events {
    /// @notice Emitted when depositing liquidity with referral code
    event Refer(address indexed onBehalfOf, uint256 indexed referralCode, uint256 amount);

    /// @notice Emitted when credit account borrows funds from the pool
    event Borrow(address indexed creditManager, address indexed creditAccount, uint256 amount);

    /// @notice Emitted when credit account's debt is repaid to the pool
    event Repay(address indexed creditManager, uint256 borrowedAmount, uint256 profit, uint256 loss);

    /// @notice Emitted when incurred loss can't be fully covered by burning treasury's shares
    event IncurUncoveredLoss(address indexed creditManager, uint256 loss);

    /// @notice Emitted when new interest rate model contract is set
    event SetInterestRateModel(address indexed newInterestRateModel);

    /// @notice Emitted when new pool quota keeper contract is set
    event SetPoolQuotaKeeper(address indexed newPoolQuotaKeeper);

    /// @notice Emitted when new total debt limit is set
    event SetTotalDebtLimit(uint256 limit);

    /// @notice Emitted when new credit manager is connected to the pool
    event AddCreditManager(address indexed creditManager);

    /// @notice Emitted when new debt limit is set for a credit manager
    event SetCreditManagerDebtLimit(address indexed creditManager, uint256 newLimit);

    /// @notice Emitted when new withdrawal fee is set
    event SetWithdrawFee(uint256 fee);
}

/// @title Pool V3 interface
interface IPoolV3 is IPoolV3Events, IPoolBase, IERC4626 {
    /// @notice Address provider contract address
    function addressProvider() external view override returns (address);

    /// @notice Underlying token address
    function underlyingToken() external view override returns (address);

    /// @notice Protocol treasury address
    function treasury() external view returns (address);

    /// @notice Withdrawal fee in bps
    function withdrawFee() external view returns (uint16);

    /// @notice Addresses of all connected credit managers
    function creditManagers() external view returns (address[] memory);

    /// @notice Annual interest rate in ray that liquidity providers receive per unit of deposited capital,
    ///         consists of base interest and quota revenue
    function supplyRate() external view returns (uint256);

    /// @notice Available liquidity in the pool
    function availableLiquidity() external view returns (uint256);

    /// @notice Amount of underlying that would be in the pool if debt principal, base interest
    ///         and quota revenue were fully repaid
    function expectedLiquidity() external view returns (uint256);

    /// @notice Expected liquidity stored as of last update
    function expectedLiquidityLU() external view returns (uint256);

    // ---------------- //
    // ERC-4626 LENDING //
    // ---------------- //

    /// @notice Total amount of underlying tokens managed by the pool, same as `expectedLiquidity`
    /// @dev Since `totalAssets` doesn't depend on underlying balance, pools are not vulnerable to the inflation attack
    function totalAssets() external view override returns (uint256);

    /// @notice Deposits given amount of underlying tokens to the pool in exchange for pool shares
    /// @param assets Amount of underlying to deposit
    /// @param receiver Account to mint pool shares to
    /// @return shares Number of shares minted
    function deposit(uint256 assets, address receiver) external override returns (uint256 shares);

    /// @dev Same as `deposit`, but allows to specify the referral code
    function depositWithReferral(uint256 assets, address receiver, uint16 referralCode)
        external
        returns (uint256 shares);

    /// @notice Deposits underlying tokens to the pool in exhcange for given number of pool shares
    /// @param shares Number of shares to mint
    /// @param receiver Account to mint pool shares to
    /// @return assets Amount of underlying transferred from caller
    function mint(uint256 shares, address receiver) external override returns (uint256 assets);

    /// @notice Withdraws pool shares for given amount of underlying tokens
    /// @param assets Amount of underlying to withdraw
    /// @param receiver Account to send underlying to
    /// @param owner Account to burn pool shares from
    /// @return shares Number of pool shares burned
    function withdraw(uint256 assets, address receiver, address owner) external override returns (uint256 shares);

    /// @notice Redeems given number of pool shares for underlying tokens
    /// @param shares Number of pool shares to redeem
    /// @param receiver Account to send underlying to
    /// @param owner Account to burn pool shares from
    /// @return assets Amount of underlying withdrawn
    function redeem(uint256 shares, address receiver, address owner) external override returns (uint256 assets);

    /// @notice Number of pool shares that would be minted on depositing `assets`
    function previewDeposit(uint256 assets) external view override returns (uint256 shares);

    /// @notice Amount of underlying that would be spent to mint `shares`
    function previewMint(uint256 shares) external view override returns (uint256 assets);

    /// @notice Number of pool shares that would be burned on withdrawing `assets`
    function previewWithdraw(uint256 assets) external view override returns (uint256 shares);

    /// @notice Amount of underlying that would be received after redeeming `shares`
    function previewRedeem(uint256 shares) external view override returns (uint256 assets);

    /// @notice Maximum amount of underlying that can be deposited to the pool, 0 if pool is on pause
    function maxDeposit(address) external view override returns (uint256 maxAssets);

    /// @notice Maximum number of pool shares that can be minted, 0 if pool is on pause
    function maxMint(address) external view override returns (uint256 maxShares);

    /// @notice Maximum amount of underlying that can be withdrawn from the pool by `owner`, 0 if pool is on pause
    function maxWithdraw(address owner) external view override returns (uint256 maxAssets);

    /// @notice Maximum number of shares that can be redeemed for underlying by `owner`, 0 if pool is on pause
    function maxRedeem(address owner) external view override returns (uint256 maxShares);

    // --------- //
    // BORROWING //
    // --------- //

    /// @notice Total borrowed amount (principal only)
    function totalBorrowed() external view returns (uint256);

    /// @notice Total debt limit, `type(uint256).max` means no limit
    function totalDebtLimit() external view returns (uint256);

    /// @notice Amount borrowed by a given credit manager
    function creditManagerBorrowed(address creditManager) external view returns (uint256);

    /// @notice Debt limit for a given credit manager, `type(uint256).max` means no limit
    function creditManagerDebtLimit(address creditManager) external view returns (uint256);

    /// @notice Amount available to borrow for a given credit manager
    function creditManagerBorrowable(address creditManager) external view returns (uint256 borrowable);

    /// @notice Lends funds to a credit account, can only be called by credit managers
    /// @param borrowedAmount Amount to borrow
    /// @param creditAccount Credit account to send the funds to
    function lendCreditAccount(uint256 borrowedAmount, address creditAccount) external override;

    /// @notice Updates pool state to indicate debt repayment, can only be called by credit managers
    ///         after transferring underlying from a credit account to the pool.
    ///         - If transferred amount exceeds debt principal + base interest + quota interest,
    ///           the difference is deemed protocol's profit and the respective number of shares
    ///           is minted to the treasury.
    ///         - If, however, transferred amount is insufficient to repay debt and interest,
    ///           which may only happen during liquidation, treasury's shares are burned to
    ///           cover as much of the loss as possible.
    /// @param repaidAmount Amount of debt principal repaid
    /// @param profit Pool's profit in underlying after repaying
    /// @param loss Pool's loss in underlying after repaying
    /// @custom:expects Credit manager transfers underlying from a credit account to the pool before calling this function
    /// @custom:expects Profit/loss computed in the credit manager are cosistent with pool's implicit calculations
    function repayCreditAccount(uint256 repaidAmount, uint256 profit, uint256 loss) external override;

    // ------------- //
    // INTEREST RATE //
    // ------------- //

    /// @notice Interest rate model contract address
    function interestRateModel() external view returns (address);

    /// @notice Annual interest rate in ray that credit account owners pay per unit of borrowed capital
    function baseInterestRate() external view returns (uint256);

    /// @notice Current cumulative base interest index in ray
    function baseInterestIndex() external view returns (uint256);

    /// @dev Same as `baseInterestIndex`, kept for backward compatibility
    function calcLinearCumulative_RAY() external view override returns (uint256);

    /// @notice Cumulative base interest index stored as of last update in ray
    function baseInterestIndexLU() external view returns (uint256);

    /// @notice Timestamp of the last base interest rate and index update
    function lastBaseInterestUpdate() external view returns (uint40);

    // ------ //
    // QUOTAS //
    // ------ //

    /// @notice Whether pool supports quotas
    function supportsQuotas() external view returns (bool);

    /// @notice Pool quota keeper contract address
    function poolQuotaKeeper() external view returns (address);

    /// @notice Current annual quota revenue in underlying tokens
    function quotaRevenue() external view returns (uint256);

    /// @notice Timestamp of the last quota revenue update
    function lastQuotaRevenueUpdate() external view returns (uint40);

    /// @notice Updates quota revenue value by given delta
    /// @param quotaRevenueDelta Quota revenue delta
    function updateQuotaRevenue(int256 quotaRevenueDelta) external;

    /// @notice Sets new quota revenue value
    /// @param newQuotaRevenue New quota revenue value
    function setQuotaRevenue(uint256 newQuotaRevenue) external;

    // ------------- //
    // CONFIGURATION //
    // ------------- //

    /// @notice Sets new interest rate model, can only be called by configurator
    /// @param newInterestRateModel Address of the new interest rate model contract
    function setInterestRateModel(address newInterestRateModel) external;

    /// @notice Sets new pool quota keeper, can only be called by configurator
    /// @param newPoolQuotaKeeper Address of the new pool quota keeper contract
    function setPoolQuotaKeeper(address newPoolQuotaKeeper) external;

    /// @notice Sets new total debt limit, can only be called by controller
    /// @param newLimit New debt limit, `type(uint256).max` for no limit
    function setTotalDebtLimit(uint256 newLimit) external;

    /// @notice Sets new debt limit for a given credit manager, can only be called by controller
    ///         Adds credit manager to the list of connected managers when called for the first time
    /// @param creditManager Credit manager to set the limit for
    /// @param newLimit New debt limit, `type(uint256).max` for no limit (has smaller priority than total debt limit)
    function setCreditManagerDebtLimit(address creditManager, uint256 newLimit) external;

    /// @notice Sets new withdrawal fee, can only be called by controller
    /// @param newWithdrawFee New withdrawal fee in bps
    function setWithdrawFee(uint256 newWithdrawFee) external;
}
