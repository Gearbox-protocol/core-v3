// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PoolV3} from "../../../pool/PoolV3.sol";
import {HandlerBase} from "./HandlerBase.sol";

contract PoolHandler is HandlerBase {
    PoolV3 public pool;
    ERC20 public underlying;

    address[] _depositors;
    address _depositor;
    address _manager;

    modifier withDepositor(uint256 idx) {
        _depositor = _get(_depositors, idx);
        vm.startPrank(_depositor);
        _;
        vm.stopPrank();
    }

    modifier withManager(uint256 idx) {
        _manager = _get(pool.creditManagers(), idx);
        vm.startPrank(_manager);
        _;
        vm.stopPrank();
    }

    constructor(PoolV3 pool_, uint256 maxTimeDelta) HandlerBase(maxTimeDelta) {
        pool = pool_;
        underlying = ERC20(pool_.underlyingToken());
    }

    function addDepositor(address depositor) external {
        _depositors.push(depositor);
    }

    function getDepositors() external view returns (address[] memory) {
        return _depositors;
    }

    function exchangeRate() external view returns (uint256) {
        uint256 assets = 10 ** underlying.decimals();
        uint256 shares = pool.convertToShares(assets);
        return assets * 1e18 / shares;
    }

    // -------- //
    // ERC-4626 //
    // -------- //

    function deposit(Ctx memory ctx, uint256 depositorIdx, uint256 assets, uint256 receiverIdx)
        external
        applyContext(ctx)
        withDepositor(depositorIdx)
    {
        assets = bound(assets, 0, underlying.balanceOf(_depositor));
        deal(address(underlying), _depositor, assets);

        underlying.approve(address(pool), assets);
        pool.deposit(assets, _get(_depositors, receiverIdx));
    }

    function mint(Ctx memory ctx, uint256 depositorIdx, uint256 shares, uint256 receiverIdx)
        external
        applyContext(ctx)
        withDepositor(depositorIdx)
    {
        shares = bound(shares, 0, pool.previewDeposit(underlying.balanceOf(_depositor)));
        uint256 assets = pool.previewMint(shares);
        deal(address(underlying), _depositor, assets);

        underlying.approve(address(pool), assets);
        assets = pool.mint(shares, _get(_depositors, receiverIdx));
    }

    function withdraw(Ctx memory ctx, uint256 depositorIdx, uint256 assets, uint256 receiverIdx)
        external
        applyContext(ctx)
        withDepositor(depositorIdx)
    {
        assets = bound(assets, 0, pool.maxWithdraw(_depositor));

        pool.withdraw(assets, _get(_depositors, receiverIdx), _depositor);
    }

    function redeem(Ctx memory ctx, uint256 depositorIdx, uint256 shares, uint256 receiverIdx)
        external
        applyContext(ctx)
        withDepositor(depositorIdx)
    {
        shares = bound(shares, 0, pool.maxRedeem(_depositor));

        pool.redeem(shares, _get(_depositors, receiverIdx), _depositor);
    }

    // ----------- //
    // MOCK CREDIT //
    // ----------- //

    function borrow(Ctx memory ctx, uint256 managerIdx, uint256 amount)
        external
        applyContext(ctx)
        withManager(managerIdx)
    {
        uint256 borrowable = pool.creditManagerBorrowable(_manager);
        if (borrowable == 0) return;
        amount = bound(amount, 1, borrowable);

        pool.lendCreditAccount(amount, _manager);
    }

    function repayWithProfit(Ctx memory ctx, uint256 managerIdx, uint256 amount, uint256 profit)
        external
        applyContext(ctx)
        withManager(managerIdx)
    {
        uint256 borrowed = pool.creditManagerBorrowed(_manager);
        if (borrowed == 0) return;
        amount = bound(amount, 0, borrowed);

        // NOTE: profit is bounded to credit manager's "free" balance
        profit = bound(profit, 0, underlying.balanceOf(_manager) - borrowed);

        underlying.transfer(address(pool), amount + profit);
        pool.repayCreditAccount(amount, profit, 0);
    }

    function repayWithLoss(Ctx memory ctx, uint256 managerIdx, uint256 loss)
        external
        applyContext(ctx)
        withManager(managerIdx)
    {
        uint256 amount = pool.creditManagerBorrowed(_manager);
        if (amount == 0) return;

        // NOTE: with no base or quota interest, loss is bounded to the borrowed amount
        loss = bound(loss, 0, amount);

        underlying.transfer(address(pool), amount - loss);
        pool.repayCreditAccount(amount, 0, loss);
    }
}
