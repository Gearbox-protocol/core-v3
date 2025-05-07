// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MultiCall} from "@gearbox-protocol/core-v2/contracts/libraries/MultiCall.sol";
import {CreditConfiguratorV3} from "../../../credit/CreditConfiguratorV3.sol";
import {CreditFacadeV3} from "../../../credit/CreditFacadeV3.sol";
import {CreditManagerV3} from "../../../credit/CreditManagerV3.sol";
import {ICreditFacadeV3Multicall} from "../../../interfaces/ICreditFacadeV3Multicall.sol";
import {PoolQuotaKeeperV3} from "../../../pool/PoolQuotaKeeperV3.sol";
import {HandlerBase} from "./HandlerBase.sol";

contract CreditHandler is HandlerBase {
    CreditManagerV3 public creditManager;
    CreditFacadeV3 public creditFacade;
    CreditConfiguratorV3 public creditConfigurator;
    ERC20 public underlying;

    address _creditAccount;
    address _owner;

    modifier withCreditAccount(uint256 idx) {
        _creditAccount = _get(creditManager.creditAccounts(), idx);
        _owner = creditManager.getBorrowerOrRevert(_creditAccount);
        vm.startPrank(_owner);
        _;
        vm.stopPrank();
    }

    constructor(CreditManagerV3 creditManager_, uint256 maxTimeDelta) HandlerBase(maxTimeDelta) {
        creditManager = creditManager_;
        creditFacade = CreditFacadeV3(creditManager_.creditFacade());
        creditConfigurator = CreditConfiguratorV3(creditManager_.creditConfigurator());
        underlying = ERC20(creditManager_.underlying());
    }

    // ------- //
    // GETTERS //
    // ------- //

    function minDebt() public view returns (uint256 min) {
        (min,) = creditFacade.debtLimits();
    }

    function maxDebt() public view returns (uint256 max) {
        (, max) = creditFacade.debtLimits();
    }

    function getDebt(address creditAccount) public view returns (uint256 debt) {
        (debt,,,,,,,) = creditManager.creditAccountInfo(creditAccount);
    }

    function poolQuotaKeeper() public view returns (PoolQuotaKeeperV3) {
        return PoolQuotaKeeperV3(creditManager.poolQuotaKeeper());
    }

    // -------------- //
    // FUZZ FUNCTIONS //
    // -------------- //

    function addCollateral(Ctx memory ctx, uint256 creditAccountIdx, uint256 tokenIdx, uint256 amount)
        external
        applyContext(ctx)
        withCreditAccount(creditAccountIdx)
    {
        ERC20 token = _getToken(tokenIdx);
        amount = bound(amount, 0, token.balanceOf(_owner));
        if (amount == 0) return;

        token.approve(address(creditManager), amount);
        _multicall(
            address(creditFacade), abi.encodeCall(ICreditFacadeV3Multicall.addCollateral, (address(token), amount))
        );
    }

    function withdrawCollateral(Ctx memory ctx, uint256 creditAccountIdx, uint256 tokenIdx, uint256 amount)
        external
        applyContext(ctx)
        withCreditAccount(creditAccountIdx)
    {
        ERC20 token = _getToken(tokenIdx);
        amount = bound(amount, 0, token.balanceOf(_creditAccount));
        if (amount == 0) return;

        _multicall(
            address(creditFacade),
            abi.encodeCall(ICreditFacadeV3Multicall.withdrawCollateral, (address(token), amount, _owner))
        );
    }

    function increaseDebt(Ctx memory ctx, uint256 creditAccountIdx, uint256 amount)
        external
        applyContext(ctx)
        withCreditAccount(creditAccountIdx)
    {
        amount = bound(amount, 0, maxDebt() - getDebt(_creditAccount));
        if (amount == 0) return;

        vm.roll(block.number + 1);
        _multicall(address(creditFacade), abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (amount)));
    }

    function decreaseDebt(Ctx memory ctx, uint256 creditAccountIdx, uint256 amount)
        external
        applyContext(ctx)
        withCreditAccount(creditAccountIdx)
    {
        amount = bound(amount, 0, underlying.balanceOf(_creditAccount));

        vm.roll(block.number + 1);
        _multicall(address(creditFacade), abi.encodeCall(ICreditFacadeV3Multicall.decreaseDebt, (amount)));
    }

    function borrowAndWithdraw(Ctx memory ctx, uint256 creditAccountIdx, uint256 amount)
        external
        applyContext(ctx)
        withCreditAccount(creditAccountIdx)
    {
        amount = bound(amount, 0, maxDebt() - getDebt(_creditAccount));
        if (amount == 0) return;

        vm.roll(block.number + 1);
        _multicall(
            address(creditFacade),
            abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (amount)),
            address(creditFacade),
            abi.encodeCall(ICreditFacadeV3Multicall.withdrawCollateral, (address(underlying), amount, _owner))
        );
    }

    function addAndRepay(Ctx memory ctx, uint256 creditAccountIdx, uint256 amount)
        external
        applyContext(ctx)
        withCreditAccount(creditAccountIdx)
    {
        amount = bound(amount, 0, underlying.balanceOf(_owner));
        if (amount == 0) return;

        vm.roll(block.number + 1);
        underlying.approve(address(creditManager), amount);
        _multicall(
            address(creditFacade),
            abi.encodeCall(ICreditFacadeV3Multicall.addCollateral, (address(underlying), amount)),
            address(creditFacade),
            abi.encodeCall(ICreditFacadeV3Multicall.decreaseDebt, (amount))
        );
    }

    function increaseQuota(Ctx memory ctx, uint256 creditAccountIdx, uint256 tokenIdx, uint256 amount)
        external
        applyContext(ctx)
        withCreditAccount(creditAccountIdx)
    {
        ERC20 token = _getToken(tokenIdx);
        if (creditManager.quotedTokensMask() & creditManager.getTokenMaskOrRevert(address(token)) == 0) return;
        (uint256 quota,) = poolQuotaKeeper().getQuotaAndOutstandingInterest(_creditAccount, address(token));
        amount = bound(amount, 0, 2 * maxDebt() - quota);
        if (amount == 0) return;

        _multicall(
            address(creditFacade),
            abi.encodeCall(ICreditFacadeV3Multicall.updateQuota, (address(token), int96(uint96(amount)), 0))
        );
    }

    function decreaseQuota(Ctx memory ctx, uint256 creditAccountIdx, uint256 tokenIdx, uint256 amount)
        external
        applyContext(ctx)
        withCreditAccount(creditAccountIdx)
    {
        ERC20 token = _getToken(tokenIdx);
        if (creditManager.quotedTokensMask() & creditManager.getTokenMaskOrRevert(address(token)) == 0) return;
        (uint256 quota,) = poolQuotaKeeper().getQuotaAndOutstandingInterest(_creditAccount, address(token));
        amount = bound(amount, 0, quota);
        if (amount == 0) return;

        _multicall(
            address(creditFacade),
            abi.encodeCall(ICreditFacadeV3Multicall.updateQuota, (address(token), -int96(uint96(amount)), 0))
        );
    }

    function swapCollateral(
        Ctx memory ctx,
        uint256 creditAccountIdx,
        uint256 token1Idx,
        uint256 amount1,
        uint256 token2Idx,
        uint256 amount2
    ) external applyContext(ctx) withCreditAccount(creditAccountIdx) {
        ERC20 token1 = _getToken(token1Idx);
        ERC20 token2 = _getToken(token2Idx);
        if (address(token1) == address(token2)) return;
        amount1 = bound(amount1, 0, token1.balanceOf(_creditAccount));
        amount2 = bound(amount2, 0, token2.balanceOf(_owner));
        if (amount1 == 0 || amount2 == 0) return;

        token2.approve(address(creditManager), amount2);
        _multicall(
            address(creditFacade),
            abi.encodeCall(ICreditFacadeV3Multicall.withdrawCollateral, (address(token1), amount1, _owner)),
            address(creditFacade),
            abi.encodeCall(ICreditFacadeV3Multicall.addCollateral, (address(token2), amount2))
        );
    }

    // --------- //
    // INTERNALS //
    // --------- //

    function _getToken(uint256 idx) internal view returns (ERC20) {
        idx = bound(idx, 0, creditManager.collateralTokensCount() - 1);
        return ERC20(creditManager.getTokenByMask(1 << idx));
    }

    function _multicall(address target0, bytes memory data0) internal {
        MultiCall[] memory calls = new MultiCall[](1);
        calls[0] = MultiCall(target0, data0);
        creditFacade.multicall(_creditAccount, calls);
    }

    function _multicall(address target0, bytes memory data0, address target1, bytes memory data1) internal {
        MultiCall[] memory calls = new MultiCall[](2);
        calls[0] = MultiCall(target0, data0);
        calls[1] = MultiCall(target1, data1);
        creditFacade.multicall(_creditAccount, calls);
    }

    function _multicall(
        address target0,
        bytes memory data0,
        address target1,
        bytes memory data1,
        address target2,
        bytes memory data2
    ) internal {
        MultiCall[] memory calls = new MultiCall[](3);
        calls[0] = MultiCall(target0, data0);
        calls[1] = MultiCall(target1, data1);
        calls[2] = MultiCall(target2, data2);
        creditFacade.multicall(_creditAccount, calls);
    }

    function _multicall(
        address target0,
        bytes memory data0,
        address target1,
        bytes memory data1,
        address target2,
        bytes memory data2,
        address target3,
        bytes memory data3
    ) internal {
        MultiCall[] memory calls = new MultiCall[](4);
        calls[0] = MultiCall(target0, data0);
        calls[1] = MultiCall(target1, data1);
        calls[2] = MultiCall(target2, data2);
        calls[3] = MultiCall(target3, data3);
        creditFacade.multicall(_creditAccount, calls);
    }
}
