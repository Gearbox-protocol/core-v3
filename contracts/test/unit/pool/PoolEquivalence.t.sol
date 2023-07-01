// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2023
pragma solidity ^0.8.17;

import {PoolService} from "@gearbox-protocol/core-v2/contracts/pool/PoolService.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LinearInterestRateModelV3} from "../../../pool/LinearInterestRateModelV3.sol";
import {PoolV3} from "../../../pool/PoolV3.sol";

import {TestHelper} from "../../lib/helper.sol";
import {
    AP_TREASURY, AddressProviderV3ACLMock, NO_VERSION_CONTROL
} from "../../mocks/core/AddressProviderV3ACLMock.sol";
import {Tokens, TokensTestSuite} from "../../suites/TokensTestSuite.sol";

/// @title Pool equivalence test
/// @notice [PET]: Tests that ensure that `PoolV3` without quotas behaves identically to `PoolService`
contract PoolEquivalenceTest is TestHelper {
    bool v3;

    PoolV3 poolV3;
    PoolService poolService;

    LinearInterestRateModelV3 irm;
    AddressProviderV3ACLMock addressProvider;
    address treasury;

    address configurator;
    address creditManager;
    address creditAccount;
    address liquidityProvider;

    TokensTestSuite tokens;

    function setUp() public {
        configurator = makeAddr("CONFIGURATOR");
        creditManager = makeAddr("CREDIT_MANAGER");
        creditAccount = makeAddr("CREDIT_ACCOUNT");
        liquidityProvider = makeAddr("LIQUIDITY_PROVIDER");

        tokens = new TokensTestSuite();

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
        treasury = addressProvider.getAddressOrRevert(AP_TREASURY, NO_VERSION_CONTROL);

        poolV3 = new PoolV3({
            underlyingToken_: tokens.addressOf(Tokens.DAI),
            addressProvider_: address(addressProvider),
            interestRateModel_: address(irm),
            totalDebtLimit_: type(uint256).max,
            supportsQuotas_: false,
            namePrefix_: "d",
            symbolPrefix_: "diesel "
        });
        poolService = new PoolService({
            _addressProvider: address(addressProvider),
            _underlyingToken: tokens.addressOf(Tokens.DAI),
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

    /// @notice [PET-1]: `PoolV3.deposit` is equivalent to `PoolService.addLiquidity`
    /// forge-config: default.fuzz.runs = 1000
    function test_PET_01_deposit_is_equivalent(uint256 amount) public compareState("deposit") {
        vm.assume(amount > 1 && amount < 500_000 ether);
        tokens.mint(Tokens.DAI, liquidityProvider, amount);
        _deposit(liquidityProvider, amount);
    }

    /// @notice [PET-2]: `PoolV3.redeem` is equivalent to `PoolService.removeLiquidity`
    /// forge-config: default.fuzz.runs = 1000
    function test_PET_02_redeem_is_equivalent(uint256 amount) public compareState("redeem") {
        vm.assume(amount > 1 && amount < 500_000 ether);
        _redeem(liquidityProvider, amount);
    }

    /// @notice [PET-3]: `PoolV3.lendCreditAccount` is equivalent to `PoolService.lendCreditAccount`
    /// forge-config: default.fuzz.runs = 1000
    function test_PET_03_borrow_is_equivalent(uint256 amount) public compareState("borrow") {
        vm.assume(amount > 1 && amount < 500_000 ether);
        _borrow(amount);
    }

    /// @notice [PET-3]: `PoolV3.repayCreditAccount` is equivalent to `PoolService.repayCreditAccount`
    /// forge-config: default.fuzz.runs = 1000
    function test_PET_04_repay_is_equivalent(uint256 amount, int256 profit) public compareState("repay") {
        vm.assume(amount > 1 && amount < 500_000 ether);
        vm.assume(profit < 20_000 ether && profit > -20_000 ether);
        _repay(amount, profit > 0 ? uint256(profit) : 0, profit < 0 ? uint256(-profit) : 0);
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
        tokens.mint(Tokens.DAI, liquidityProvider, 1_000_000 ether);
        _deposit(liquidityProvider, 1_000_000 ether);

        _borrow(600_000 ether);

        tokens.mint(Tokens.DAI, v3 ? address(poolV3) : address(poolService), 110_000 ether);
        _repay(100_000 ether, 10_000 ether, 0);

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
        assertEq(
            snapshot1.dieselSupply,
            snapshot2.dieselSupply,
            string.concat("dieselSupply values are different, case: ", caseName)
        );
        assertEq(
            snapshot1.expectedLiquidity,
            snapshot2.expectedLiquidity,
            string.concat("expectedLiquidity values are different, case: ", caseName)
        );
        assertEq(
            snapshot1.availableLiquidity,
            snapshot2.availableLiquidity,
            string.concat("availableLiquidity values are different, case: ", caseName)
        );
        assertEq(
            snapshot1.baseInterestRate,
            snapshot2.baseInterestRate,
            string.concat("baseInterestRate values are different, case: ", caseName)
        );
        assertEq(
            snapshot1.baseInterestIndex,
            snapshot2.baseInterestIndex,
            string.concat("baseInterestIndex values are different, case: ", caseName)
        );
        assertEq(
            snapshot1.treasuryBalance,
            snapshot2.treasuryBalance,
            string.concat("treasuryBalance values are different, case: ", caseName)
        );
        assertEq(
            snapshot1.liquidityProviderBalance,
            snapshot2.liquidityProviderBalance,
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
        tokens.approve(Tokens.DAI, lp, v3 ? address(poolV3) : address(poolService));
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
