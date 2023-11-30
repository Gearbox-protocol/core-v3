// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PoolService} from "@gearbox-protocol/core-v2/contracts/pool/PoolService.sol";

import {LinearInterestRateModelV3} from "../../../pool/LinearInterestRateModelV3.sol";
import {PoolV3} from "../../../pool/PoolV3.sol";

import {AddressProviderV3ACLMock} from "../../mocks/core/AddressProviderV3ACLMock.sol";
import {Tokens, TokensTestSuite} from "../../suites/TokensTestSuite.sol";

/// @title Pool equivalence test
/// @notice U:[PET]: Tests that ensure that `PoolV3` without quotas behaves identically to `PoolService`
contract PoolEquivalenceTest is Test {
    bool v3;

    PoolV3 poolV3;
    PoolService poolService;

    address underlying;
    LinearInterestRateModelV3 irm;
    AddressProviderV3ACLMock addressProvider;
    address treasury;

    address configurator;
    address creditManager;
    address creditAccount;
    address liquidityProvider;

    TokensTestSuite tokens;

    uint256 constant INITIAL_DEPOSIT = 1_000_000 ether;
    uint256 constant INITIAL_DEBT = 500_000 ether;
    uint256 constant INITIAL_PROFIT = 10_000 ether;

    function setUp() public {
        configurator = makeAddr("CONFIGURATOR");
        creditManager = makeAddr("CREDIT_MANAGER");
        creditAccount = makeAddr("CREDIT_ACCOUNT");
        liquidityProvider = makeAddr("LIQUIDITY_PROVIDER");

        tokens = new TokensTestSuite();
        underlying = tokens.addressOf(Tokens.DAI);

        irm = new LinearInterestRateModelV3({
            U_1: 80_00,
            U_2: 90_00,
            R_base: 0,
            R_slope1: 4_00,
            R_slope2: 40_00,
            R_slope3: 75_00,
            _isBorrowingMoreU2Forbidden: false
        });

        vm.startPrank(configurator);
        addressProvider = new AddressProviderV3ACLMock();
        addressProvider.addCreditManager(creditManager);
        treasury = addressProvider.getTreasuryContract();

        poolV3 = new PoolV3({
            underlyingToken_: underlying,
            addressProvider_: address(addressProvider),
            interestRateModel_: address(irm),
            totalDebtLimit_: type(uint256).max,
            name_: "Test V3 Pool",
            symbol_: "dTest"
        });
        poolService = new PoolService({
            _addressProvider: address(addressProvider),
            _underlyingToken: underlying,
            _interestRateModelAddress: address(irm),
            _expectedLiquidityLimit: type(uint256).max
        });

        vm.mockCall(creditManager, abi.encodeWithSignature("pool()"), abi.encode(poolV3));
        poolV3.setCreditManagerDebtLimit({creditManager: creditManager, newLimit: type(uint256).max});

        vm.mockCall(creditManager, abi.encodeWithSignature("poolService()"), abi.encode(poolService));
        poolService.connectCreditManager({_creditManager: creditManager});
        vm.stopPrank();
    }

    // ----- //
    // TESTS //
    // ----- //

    /// @notice U:[PET-1]: `PoolV3.deposit` is equivalent to `PoolService.addLiquidity`
    function test_U_PET_01_deposit_is_equivalent(uint256 amount) public compareState("deposit") {
        // without expected liquidity limits, deposit amount can be arbitrarily large sane number
        uint256 amountBounded = bound(amount, 1, 10 * INITIAL_DEPOSIT);
        tokens.mint(underlying, liquidityProvider, amountBounded);

        _deposit(liquidityProvider, amountBounded);
    }

    /// @notice U:[PET-2]: `PoolV3.redeem` is equivalent to `PoolService.removeLiquidity`
    function test_U_PET_02_redeem_is_equivalent(uint256 amount) public compareState("redeem") {
        // can't redeem more than shares corresponding to available liquidity in the pool
        uint256 amountBounded = bound(amount, 1, (INITIAL_DEPOSIT - INITIAL_DEBT + INITIAL_PROFIT) * 9 / 10);

        _redeem(liquidityProvider, amountBounded);
    }

    /// @notice U:[PET-3]: `PoolV3.lendCreditAccount` is equivalent to `PoolService.lendCreditAccount`
    function test_U_PET_03_borrow_is_equivalent(uint256 amount) public compareState("borrow") {
        // can't borrow more than available liquidity in the pool
        uint256 amountBounded = bound(amount, 1, INITIAL_DEPOSIT - INITIAL_DEBT + INITIAL_PROFIT);

        _borrow(amountBounded);
    }

    /// @notice U:[PET-4]: `PoolV3.repayCreditAccount` is equivalent to `PoolService.repayCreditAccount`
    function test_U_PET_04_repay_is_equivalent(uint256 amount, int256 profit) public compareState("repay") {
        vm.assume(profit > type(int256).min);

        // can't repay more than borrowed
        uint256 amountBounded = bound(amount, 1, INITIAL_DEBT);
        // let's limit profit and loss to be of roughly the same order as initial profit
        int256 profitBounded = bound(profit, -2 * int256(INITIAL_PROFIT), 2 * int256(INITIAL_PROFIT));

        _repay(
            amountBounded,
            profitBounded > 0 ? uint256(profitBounded) : 0,
            profitBounded < 0 ? uint256(-profitBounded) : 0
        );
    }

    // --------- //
    // SNAPSHOTS //
    // --------- //

    struct StateSnapshot {
        uint256 dieselSupply;
        uint256 expectedLiquidity;
        uint256 availableLiquidity;
        uint256 baseInterestRate;
        uint256 baseInterestIndex;
        uint256 treasuryBalance;
        uint256 liquidityProviderBalance;
    }

    modifier compareState(string memory caseName) {
        uint256 snapshot = vm.snapshot();
        v3 = true;
        _setupState();
        _;
        StateSnapshot memory snapshotPoolV3 = _makeSnapshot();

        vm.revertTo(snapshot);
        v3 = false;
        _setupState();
        _;
        StateSnapshot memory snapshotPoolService = _makeSnapshot();

        _compareSnapshots(snapshotPoolV3, snapshotPoolService, caseName);
    }

    function _setupState() public {
        // deposit funds into the pool
        tokens.mint(underlying, liquidityProvider, INITIAL_DEPOSIT);
        _deposit(liquidityProvider, INITIAL_DEPOSIT);

        // borrow funds from the pool to update interest rate
        _borrow(3 * INITIAL_DEBT / 2);

        // repay some funds to the pool with profits so that treasury has some diesel tokens
        tokens.mint(underlying, v3 ? address(poolV3) : address(poolService), INITIAL_DEBT / 2 + INITIAL_PROFIT);
        _repay(INITIAL_DEBT / 2, INITIAL_PROFIT, 0);

        // wait for some time for interest to compound
        vm.warp(block.timestamp + 365 days);
    }

    function _makeSnapshot() internal view returns (StateSnapshot memory snapshot) {
        snapshot.dieselSupply = _dieselSupply();
        snapshot.expectedLiquidity = _expectedLiquidity();
        snapshot.availableLiquidity = _availableLiquidity();
        snapshot.baseInterestRate = _baseInterestRate();
        snapshot.baseInterestIndex = _baseInterestIndex();
        snapshot.treasuryBalance = _dieselBalance(treasury);
        snapshot.liquidityProviderBalance = _dieselBalance(liquidityProvider);
    }

    function _compareSnapshots(StateSnapshot memory snapshot1, StateSnapshot memory snapshot2, string memory caseName)
        internal
    {
        // NOTE: small deviations are allowed because PoolService calculations always run with higher precision
        uint256 maxDelta = 1;

        assertApproxEqAbs(
            snapshot1.dieselSupply,
            snapshot2.dieselSupply,
            maxDelta,
            string.concat("dieselSupply values are different, case: ", caseName)
        );
        assertApproxEqAbs(
            snapshot1.expectedLiquidity,
            snapshot2.expectedLiquidity,
            maxDelta,
            string.concat("expectedLiquidity values are different, case: ", caseName)
        );
        assertApproxEqAbs(
            snapshot1.availableLiquidity,
            snapshot2.availableLiquidity,
            maxDelta,
            string.concat("availableLiquidity values are different, case: ", caseName)
        );
        assertApproxEqAbs(
            snapshot1.baseInterestRate,
            snapshot2.baseInterestRate,
            maxDelta,
            string.concat("baseInterestRate values are different, case: ", caseName)
        );
        assertApproxEqAbs(
            snapshot1.baseInterestIndex,
            snapshot2.baseInterestIndex,
            maxDelta,
            string.concat("baseInterestIndex values are different, case: ", caseName)
        );
        assertApproxEqAbs(
            snapshot1.treasuryBalance,
            snapshot2.treasuryBalance,
            maxDelta,
            string.concat("treasuryBalance values are different, case: ", caseName)
        );
        assertApproxEqAbs(
            snapshot1.liquidityProviderBalance,
            snapshot2.liquidityProviderBalance,
            maxDelta,
            string.concat("liquidityProviderBalance values are different, case: ", caseName)
        );
    }

    // ---------- //
    // POOL STATE //
    // ---------- //

    function _dieselSupply() internal view returns (uint256) {
        return v3 ? poolV3.totalSupply() : IERC20(poolService.dieselToken()).totalSupply();
    }

    function _dieselBalance(address account) internal view returns (uint256) {
        return v3 ? poolV3.balanceOf(account) : IERC20(poolService.dieselToken()).balanceOf(account);
    }

    function _expectedLiquidity() internal view returns (uint256) {
        return v3 ? poolV3.expectedLiquidity() : poolService.expectedLiquidity();
    }

    function _availableLiquidity() internal view returns (uint256) {
        return v3 ? poolV3.availableLiquidity() : poolService.availableLiquidity();
    }

    function _baseInterestRate() internal view returns (uint256) {
        return v3 ? poolV3.baseInterestRate() : poolService.borrowAPY_RAY();
    }

    function _baseInterestIndex() internal view returns (uint256) {
        return v3 ? poolV3.baseInterestIndex() : poolService.calcLinearCumulative_RAY();
    }

    // ------------ //
    // POOL ACTIONS //
    // ------------ //

    function _deposit(address lp, uint256 assets) internal {
        tokens.approve(underlying, lp, v3 ? address(poolV3) : address(poolService));
        vm.prank(lp);
        if (v3) {
            poolV3.depositWithReferral({assets: assets, receiver: lp, referralCode: 123});
        } else {
            poolService.addLiquidity({amount: assets, onBehalfOf: lp, referralCode: 123});
        }
    }

    function _redeem(address lp, uint256 shares) internal {
        vm.prank(lp);
        if (v3) {
            poolV3.redeem({shares: shares, receiver: lp, owner: lp});
        } else {
            poolService.removeLiquidity({amount: shares, to: lp});
        }
    }

    function _borrow(uint256 amount) internal {
        vm.prank(creditManager);
        if (v3) {
            poolV3.lendCreditAccount({borrowedAmount: amount, creditAccount: creditAccount});
        } else {
            poolService.lendCreditAccount({borrowedAmount: amount, creditAccount: creditAccount});
        }
    }

    function _repay(uint256 amount, uint256 profit, uint256 loss) internal {
        vm.prank(creditManager);
        if (v3) {
            poolV3.repayCreditAccount({repaidAmount: amount, profit: profit, loss: loss});
        } else {
            poolService.repayCreditAccount({borrowedAmount: amount, profit: profit, loss: loss});
        }
    }
}
