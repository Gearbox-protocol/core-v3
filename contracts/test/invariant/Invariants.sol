// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {Test} from "forge-std/Test.sol";

import {CreditManagerV3} from "../../credit/CreditManagerV3.sol";
import {GaugeV3} from "../../governance/GaugeV3.sol";
import {GearStakingV3} from "../../governance/GearStakingV3.sol";
import {CollateralCalcTask, CollateralDebtData} from "../../interfaces/ICreditManagerV3.sol";
import {PoolV3} from "../../pool/PoolV3.sol";

import {CreditHandler} from "./handlers/CreditHandler.sol";
import {PoolHandler} from "./handlers/PoolHandler.sol";
import {VotingHandler} from "./handlers/VotingHandler.sol";

contract Invariants is Test {
    // ------ //
    // VOTING //
    // ------ //

    /// @dev INV:[V-1]: All users' total stake is equal to staking contract's GEAR balance,
    ///      assuming no direct transfers
    function _assert_voting_invariant_01(VotingHandler votingHandler) internal {
        GearStakingV3 gearStaking = votingHandler.gearStaking();
        address[] memory stakers = votingHandler.getStakers();
        uint256 totalStaked;
        for (uint256 i; i < stakers.length; ++i) {
            totalStaked += gearStaking.balanceOf(stakers[i]);
        }
        assertEq(
            totalStaked,
            votingHandler.gear().balanceOf(address(gearStaking)),
            "INV:[V-1]: Total stake does not equal GEAR balance"
        );
    }

    /// @dev INV:[V-2]: Each user's total stake is consistently split between available stake,
    ///      withdrawable amounts and casted votes
    function _assert_voting_invariant_02(VotingHandler votingHandler) internal {
        GearStakingV3 gearStaking = votingHandler.gearStaking();
        address[] memory stakers = votingHandler.getStakers();
        for (uint256 i; i < stakers.length; ++i) {
            uint256 available = gearStaking.availableBalance(stakers[i]);

            (uint256 withdrawable, uint256[4] memory scheduled) = gearStaking.getWithdrawableAmounts(stakers[i]);
            withdrawable += scheduled[0] + scheduled[1] + scheduled[2] + scheduled[3];

            uint256 casted = votingHandler.getVotesCastedBy(stakers[i]);

            assertEq(
                gearStaking.balanceOf(stakers[i]),
                available + withdrawable + casted,
                "INV:[V-2]: Inconsistent user's total stake"
            );
        }
    }

    /// @dev INV:[V-3]: Votes casted for each gauge are consistently split between all tokens
    function _assert_voting_invariant_03(VotingHandler votingHandler) internal {
        address[] memory gauges = votingHandler.getVotingContracts();
        for (uint256 i; i < gauges.length; ++i) {
            uint256 totalVotes;
            address[] memory tokens = votingHandler.getGaugeTokens(gauges[i]);
            for (uint256 j; j < tokens.length; ++j) {
                (,, uint256 totalVotesLpSide, uint256 totalVotesCaSide) = GaugeV3(gauges[i]).quotaRateParams(tokens[j]);
                totalVotes += totalVotesCaSide + totalVotesLpSide;
            }
            assertEq(totalVotes, votingHandler.getVotesCastedFor(gauges[i]), "INV:[V-3]: Inconsistent votes for gauge");
        }
    }

    /// @dev INV:[V-4]: Total and per-user votes for all tokens are consistent for each gauge
    function _assert_voting_invariant_04(VotingHandler votingHandler) internal {
        address[] memory gauges = votingHandler.getVotingContracts();
        for (uint256 i; i < gauges.length; ++i) {
            address[] memory tokens = votingHandler.getGaugeTokens(gauges[i]);
            for (uint256 j; j < tokens.length; ++j) {
                uint256 totalVotesLP;
                uint256 totalVotesCA;
                address[] memory stakers = votingHandler.getStakers();
                for (uint256 k; k < stakers.length; ++k) {
                    (uint256 votesLP, uint256 votesCA) = GaugeV3(gauges[i]).userTokenVotes(stakers[k], tokens[j]);
                    totalVotesLP += votesLP;
                    totalVotesCA += votesCA;
                }
                (,, uint96 totalVotesLpSide, uint96 totalVotesCaSide) = GaugeV3(gauges[i]).quotaRateParams(tokens[j]);
                assertEq(totalVotesLpSide, totalVotesLP, "INV:[V-4]: Inconsistent LP side votes for token");
                assertEq(totalVotesCaSide, totalVotesCA, "INV:[V-4]: Inconsistent CA side votes for token");
            }
        }
    }

    // ---- //
    // POOL //
    // ---- //

    /// @dev INV:[P-1]: Total and per-manager debt limits are respected, assuming no configuration changes
    function _assert_pool_invariant_01(PoolHandler poolHandler) internal {
        PoolV3 pool = poolHandler.pool();
        assertLe(pool.totalBorrowed(), pool.totalDebtLimit(), "INV:[P-1]: Total debt exceeds limit");
        address[] memory creditManagers = pool.creditManagers();
        for (uint256 i; i < creditManagers.length; ++i) {
            assertLe(
                pool.creditManagerBorrowed(creditManagers[i]),
                pool.creditManagerDebtLimit(creditManagers[i]),
                "INV:[P-1]: Credit manager debt exceeds limit"
            );
        }
    }

    /// @dev INV:[P-2]: Total and per-manager debt amounts are consistent
    function _assert_pool_invariant_02(PoolHandler poolHandler) internal {
        PoolV3 pool = poolHandler.pool();
        uint256 totalBorrowed;
        address[] memory creditManagers = pool.creditManagers();
        for (uint256 j; j < creditManagers.length; ++j) {
            totalBorrowed += pool.creditManagerBorrowed(creditManagers[j]);
        }
        assertEq(
            pool.totalBorrowed(),
            totalBorrowed,
            "INV:[P-2]: Total debt is inconsistent with per-manager borrowed amounts"
        );
    }

    /// @dev INV:[P-3]: Pool is solvent when there's no outstanding debt
    function _assert_pool_invariant_03(PoolHandler poolHandler) internal {
        PoolV3 pool = poolHandler.pool();
        uint256 borrowed = pool.totalBorrowed();
        if (borrowed == 0) {
            assertGe(pool.availableLiquidity(), pool.expectedLiquidity(), "INV:[P-3]: Pool is insolvent");
        }
    }

    /// @dev INV:[P-4]: Pool expects profit when there is outstanding debt
    function _assert_pool_invariant_04(PoolHandler poolHandler) internal {
        PoolV3 pool = poolHandler.pool();
        uint256 borrowed = pool.totalBorrowed();
        if (borrowed != 0) {
            // TODO: might need to add some buffer on the left since managers transfer a bit more than needed
            assertGe(pool.expectedLiquidity(), pool.availableLiquidity() + borrowed, "INV:[P-4]: Pool is unprofitable");
        }
    }

    /// @dev INV:[P-5]: Exchange rate growth in time is bounded
    function _assert_pool_invariant_05(PoolHandler poolHandler) internal {
        assertLe(
            poolHandler.exchangeRate(),
            1e18 + 1e18 * (block.timestamp - poolHandler.initialTimestamp()) / 365 days,
            "INV:[P-5]: Inadequate exchange rate growth"
        );
    }

    // ------ //
    // CREDIT //
    // ------ //

    /// @dev INV:[C-1]: Credit manager's debt in the pool must be consistently split across all credit accounts
    function _assert_credit_invariant_01(CreditHandler creditHandler) internal {
        CreditManagerV3 creditManager = creditHandler.creditManager();
        uint256 creditManagerDebt;
        address[] memory creditAccounts = creditManager.creditAccounts();
        for (uint256 i; i < creditAccounts.length; ++i) {
            creditManagerDebt += creditHandler.getDebt(creditAccounts[i]);
        }
        assertEq(
            creditManagerDebt,
            PoolV3(creditManager.pool()).creditManagerBorrowed(address(creditManager)),
            "INV:[C-1]: Inconsistent debt between pool and credit manager"
        );
    }

    /// @dev INV:[C-2]: Credit accounts with zero debt principal have no accrued interest, fees or enabled quoted tokens
    function _assert_credit_invariant_02(CreditHandler creditHandler) internal {
        CreditManagerV3 creditManager = creditHandler.creditManager();
        address[] memory creditAccounts = creditManager.creditAccounts();
        for (uint256 i; i < creditAccounts.length; ++i) {
            CollateralDebtData memory cdd =
                creditManager.calcDebtAndCollateral(creditAccounts[i], CollateralCalcTask.DEBT_ONLY);
            if (cdd.debt == 0) {
                assertEq(cdd.totalDebtUSD, 0, "INV:[C-2]: Non-zero accrued interest or fees");
                assertEq(cdd.enabledTokensMask & cdd.quotedTokensMask, 0, "INV:[C-2]: Enabled quoted tokens");
            }
        }
    }

    /// @dev INV:[C-3]: Credit accounts with non-zero debt principal have the latter within allowed limits,
    ///      assuming no configuration changes
    function _assert_credit_invariant_03(CreditHandler creditHandler) internal {
        CreditManagerV3 creditManager = creditHandler.creditManager();
        address[] memory creditAccounts = creditManager.creditAccounts();
        for (uint256 i; i < creditAccounts.length; ++i) {
            uint256 debt = creditHandler.getDebt(creditAccounts[i]);
            if (debt != 0) {
                assertGe(debt, creditHandler.minDebt(), "INV:[C-3]: Debt principal below limit");
                assertLe(debt, creditHandler.maxDebt(), "INV:[C-3]: Debt principal above limit");
            }
        }
    }

    /// @dev INV:[C-4]: Credit account has quoted token enabled if and only if the quota is greater than 0
    function _assert_credit_invariant_04(CreditHandler creditHandler) internal {
        CreditManagerV3 creditManager = creditHandler.creditManager();
        address[] memory creditAccounts = creditManager.creditAccounts();
        uint256 quotedTokensMask = creditManager.quotedTokensMask();
        while (quotedTokensMask != 0) {
            uint256 tokenMask = quotedTokensMask & uint256(-int256(quotedTokensMask));
            address token = creditManager.getTokenByMask(tokenMask);
            for (uint256 i; i < creditAccounts.length; ++i) {
                uint256 enabledTokensMask = creditManager.enabledTokensMaskOf(creditAccounts[i]);
                (uint256 quota,) = creditHandler.poolQuotaKeeper().getQuota(creditAccounts[i], token);
                if (quota == 0) {
                    assertEq(enabledTokensMask & tokenMask, 0, "INV:[C-4]: Enabled quoted token with zero quota");
                } else {
                    assertGt(enabledTokensMask & tokenMask, 0, "INV:[C-4]: Disabled quoted token with non-zero quota");
                }
            }
            quotedTokensMask ^= tokenMask;
        }
    }

    /// @dev INV:[C-5]: Number of enabled tokens on the credit account doesn't exceed the maximum allowed,
    ///      assuming no configuration changes
    function _assert_credit_invariant_05(CreditHandler creditHandler) internal {
        CreditManagerV3 creditManager = creditHandler.creditManager();
        address[] memory creditAccounts = creditManager.creditAccounts();
        for (uint256 i; i < creditAccounts.length; ++i) {
            uint256 numEnabledTokens;
            // NOTE: exclude underlying token
            uint256 enabledTokensMask = creditManager.enabledTokensMaskOf(creditAccounts[i]) & ~uint256(1);
            while (enabledTokensMask > 0) {
                enabledTokensMask &= enabledTokensMask - 1;
                ++numEnabledTokens;
            }
            assertLe(numEnabledTokens, creditManager.maxEnabledTokens(), "INV:[C-5]: More enabled tokens than allowed");
        }
    }

    // ------ //
    // GLOBAL //
    // ------ //

    /// @dev INV:[G-1]: Interest accrued by all credit accounts approximately equals pool's expected revenue
    function _assert_global_invariant_01(PoolHandler poolHandler, CreditHandler creditHandler) internal {
        PoolV3 pool = poolHandler.pool();
        CreditManagerV3 creditManager = creditHandler.creditManager();
        require(creditManager.pool() == address(pool), "Invariants: Credit manager connected to wrong pool");

        uint256 accruedInterest;
        address[] memory creditAccounts = creditManager.creditAccounts();
        for (uint256 j; j < creditAccounts.length; ++j) {
            CollateralDebtData memory cdd =
                creditManager.calcDebtAndCollateral(creditAccounts[j], CollateralCalcTask.DEBT_ONLY);
            accruedInterest += cdd.accruedInterest;
        }

        assertApproxEqRel(
            pool.expectedLiquidity(),
            pool.availableLiquidity() + pool.totalBorrowed() + accruedInterest,
            1e14, // 0.01%
            "INV:[G-1]: Accrued interest is inconsistent with expected revenue"
        );
    }
}
