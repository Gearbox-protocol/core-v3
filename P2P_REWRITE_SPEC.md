# P2P Matching Rewrite Spec (core-v3)

## Goals

- Replace the pool-based lending model with P2P credit lines established by matching offchain lender/borrower orders.
- Each credit account is tied to a single lender and has fixed loan duration with unilateral early close (penalty).
- Loan terms (interest rate model, collateral set, per-collateral LT, duration bounds) are per-loan, while adapters/oracles remain global.
- Keep the existing leverage/multicall/adapters/liquidation framework and all core math logic intact wherever possible.
- Interest accrual and repayment computations must mirror the prior pool-based implementation, but applied per account.

## Non-goals

- Preserve ERC-4626 pool shares or pool-level liquidity mechanics.
- Maintain quota/quoted-token limits (replaced by per-loan collateral set).

## High-level Architecture

### New Core Contract

**`MatchingEngine` (new)**  
Owns order validation and credit-line creation. A matcher role submits pairs of signed orders (lender, borrower). The engine validates terms, funds the credit account, and assigns per-loan parameters to the credit account.

Key roles:

- **Matcher**: authorized to submit order pairs onchain.
- **Lender**: signs loan offer.
- **Borrower**: signs loan request.
- **DAO/Admin**: configures protocol-wide settings (fees, matcher role, etc.).

### Existing Components Retained (with changes)

- **CreditManager/CreditFacade**: retain account lifecycle, collateral checks, adapters, liquidations; updated for per-loan terms.
- **PriceOracleV3**, **BotListV3**, **AccountFactory**: remain global.
- **Adapters**: remain configured per credit manager.

### Components Removed or Replaced

Pool-based contracts and quota mechanics are removed or replaced. See “Contract Changes” below.

## Data Model Changes

### New Per-loan State (stored per credit account)

- `lender`: address
- `principal`: amount borrowed
- `interestRateModel`: address (per-loan IRM)
- `rateParams`: model-specific params (e.g., fixed rate, reference + spread)
- `startTimestamp`: uint40
- `maturityTimestamp`: uint40
- `minDuration`/`maxDuration`: stored only in order; onchain stores `maturity`
- `collateralConfigHash`: hash of collateral list + LTs (or store mapping directly)
- `earlyClosePenalty`: basis points or fixed formula parameters
- `orderIds`: lender/borrower order ids or hashes (for auditability)
- `interestIndexLastUpdate`: timestamp of last interest index update (per account)

### MatchingEngine Order State

- `alreadyFilled`: per-order filled principal tracking for partial fills
- `cancelled`: per-order cancellation flags

### New Order Types (EIP-712 signed)

**LenderOrder**

- `lender`
- `asset` (underlying)
- `interestRateModel`
- `rateParams` (model-specific; includes fixed rate or ref + spread)
- `minDuration`, `maxDuration`
- `maxPrincipal` (or `principal`)
- `permittedCollaterals`: list of tokens
- `collateralLTs`: list of LTs aligned with tokens
- `maxLTV` or per-token LT-only policy
- `fundingVault` (optional ERC-4626 vault that wraps underlying)
- `nonce`, `expiry`
- `validationStrategy` (optional)

**BorrowerOrder**

- `borrower`
- `asset`
- `rateParams` (model-specific params for desired rate)
- `minDuration`, `maxDuration`
- `principal`
- `permittedCollaterals` (exact match required with lender for most strategies)
- `collateralLTs` (exact match required with lender)
- `nonce`, `expiry`
- `openingCalls` (optional multicall executed immediately on open)
- `validationStrategy` (optional)

**Matching constraints**

- `asset` must match
- duration intersection must be non-empty
- `interestRateModel` must match
- `interestRateModel.compare(lender.rateParams, borrower.rateParams)` must pass
- `principal` within lender limits
- collateral list compatibility: exact match between orders
- per-collateral LT compatibility: exact match between orders and each LT < underlying LT
- only lender orders can be partially filled; borrower orders are always fully filled

## Core Flows

### 1) Open Credit Line (via MatchingEngine)

1. Matcher submits `lenderOrder`, `borrowerOrder`, signatures, and desired `principal`, `duration`, `rateParams`, `collateralSet`.
2. MatchingEngine validates:
   - signatures and nonces
   - order expiries
   - parameter compatibility (rate, duration, collateral constraints)
   - `validationStrategy` hooks if present (only at open)
3. MatchingEngine calls CreditManager/CreditFacade to:

- create credit account for borrower with per-loan terms and collateral config set atomically during opening

4. Funds are pulled from lender via allowance to MatchingEngine. If `fundingVault` is specified, MatchingEngine
   pulls vault shares and unwraps to underlying during matching.
5. If `openingCalls` are present, execute them atomically during account opening.
6. Emit `CreditLineOpened` (new) with lender/borrower/terms.

### 2) Borrower Actions

Borrower uses existing multicall/adapters to manage positions, with collateral checks based on per-account LT config. Debt accrues per the per-loan interest rate model.

### 3) Repayment / Close at Maturity

Borrower repays outstanding debt + interest; assets flow to lender (and protocol fees as configured). Credit account is closed. There is no forced closure at maturity unless one side initiates it.

### 4) Unilateral Early Close (Penalty)

Either side can trigger close before maturity:

- **Borrower-initiated**: repay principal + accrued interest + penalty to lender.
- **Lender-initiated**: lender issues a margin-call style notice; borrower has a grace period to close and receive penalty.
  If borrower fails to close in grace period, liquidation can proceed without penalty.
  Penalty is paid by the initiating party to the counterparty.
  For partial debt decreases, penalty is applied only on the decreased amount.

### 5) Liquidation

Liquidation logic and core math remain unchanged; repayments are routed to lender instead of a pool. Loss handling feeds into loss policy and protocol fee accounting.

## Contract Changes (by file)

### New Contracts

- `contracts/core/MatchingEngine.sol`
  - Validates EIP-712 orders, handles nonces/cancellation, matching, per-account interest indexes, and creating credit lines.
- `contracts/interfaces/IMatchingEngine.sol`
  - Public functions and events for matching and order management.

### Pool Removal / Replacement

Likely removed or replaced entirely:

- `contracts/pool/PoolV3.sol`
- `contracts/pool/PoolV3_USDT.sol`
- `contracts/pool/LinearInterestRateModelV3.sol`
- `contracts/pool/PoolQuotaKeeperV3.sol`
- `contracts/pool/GaugeV3.sol`
- `contracts/pool/TumblerV3.sol`
- Interfaces: `IPoolV3`, `IPoolQuotaKeeperV3`, `ILinearInterestRateModelV3`

### Credit Manager

`contracts/credit/CreditManagerV3.sol`

- Replace `pool` dependency with `matchingEngine` (or `loanController`).
- Replace pool debt/index usage with per-loan debt + rate parameters while keeping all math routines unchanged.
- Extend `CreditAccountInfo` to include lender, rate, maturity, penalty params.
- Remove quota tracking (`cumulativeQuotaInterest`, `quotaFees`, `updateQuota`).
- Update `calcDebtAndCollateral` to use per-account LT list, capped by underlying LT.
- Enforce `maxEnabledTokens` cap on per-loan collateral list.
- Update liquidation payouts to route to lender and protocol treasury.
- Store per-account interest index timestamp and use it for interest index computation exactly as before, but per account.

`contracts/interfaces/ICreditManagerV3.sol`

- Update `CreditAccountInfo` fields.
- Remove quota-related functions and data.
- Ensure per-account loan terms and collateral configuration are set during account opening (no external setters).

### Credit Facade

`contracts/credit/CreditFacadeV3.sol`

- Add entrypoint for MatchingEngine to open credit accounts with explicit terms.
- Remove quota-related flows and debt limit logic that assumes pool-wide constraints.
- Add lender/borrower early-close paths with penalties.
- Update events and interface to include lender when opening accounts.
- Replace DegenNFT checks with `validationStrategy` hook in order matching.

`contracts/interfaces/ICreditFacadeV3.sol`

- Update `openCreditAccount` signature for matching-engine usage.
- Remove quota-related constants and references.

### Credit Configurator

`contracts/credit/CreditConfiguratorV3.sol`

- Remove quota requirements (token must be quoted in quota keeper).
- Keep adapter/oracle configuration as global settings per credit manager.
- Add optional configuration for allowed matcher roles or whitelist matching engine.

### Libraries

- `contracts/libraries/CreditLogic.sol`
  - Preserve existing math for interest and repayment; only remove quota components where required.
- `contracts/libraries/CollateralLogic.sol`
  - Preserve existing math for collateral valuation; only replace quota+LT packing with per-account LT list and remove quota constraints.
- `contracts/libraries/QuotasLogic.sol`
  - Remove if quotas eliminated.

### Interfaces & Traits

- Add per-loan interest rate model support (fixed or reference + spread) and update `IInterestRateModel` as needed.
- `IInterestRateModel` must expose a comparator for lender/borrower `rateParams`.
- Add `IMatchingEngine` and EIP-712 domain definitions.

## Access Control & Governance

- Add `MATCHER_ROLE` (or similar) in ACL.
- MatchingEngine controlled by DAO; CreditManager only accepts calls from MatchingEngine for loan creation.
- Emergency pause should halt matching and optionally allow only closes/liquidations.

## Events

Add new events:

- `OrderMatched(lender, borrower, creditAccount, principal, rate, maturity)`
- `OrderCancelled(user, nonce)`
- `CreditLineOpened(creditAccount, lender, borrower, principal, rate, maturity)`
- `CreditLineClosed(creditAccount, reason, penaltyPaid)`
- `EarlyCloseRequested(creditAccount, by, penalty)`
- `ValidationStrategySet(orderHash, strategy)`

## Interface Sketches (new/updated)

The following sketches are non-final and describe intent and responsibilities.

### `IMatchingEngine`

**Types**

- `struct LenderOrder { ... }`  
  Lender-signed order with `interestRateModel`, `rateParams`, optional `fundingVault`, collateral list + LTs, durations.
- `struct BorrowerOrder { ... }`  
  Borrower-signed order with `rateParams`, collateral list + LTs, durations, optional `openingCalls`.
- `struct MatchParams { uint256 principal; uint256 duration; bytes lenderRateParams; bytes borrowerRateParams; }`

**Read methods**

- `function getOrderHash(LenderOrder order) external view returns (bytes32)`  
  Actions: compute EIP-712 hash for lender order.  
  Reverts: none.
- `function getOrderHash(BorrowerOrder order) external view returns (bytes32)`  
  Actions: compute EIP-712 hash for borrower order.  
  Reverts: none.
- `function alreadyFilled(bytes32 orderHash) external view returns (uint256)`  
  Actions: return filled principal for a lender order.  
  Reverts: none.
- `function isCancelled(bytes32 orderHash) external view returns (bool)`  
   Actions: return cancellation flag.  
   Reverts: none.
  **State-changing methods**

- `function matchOrders(LenderOrder lender, BorrowerOrder borrower, bytes lenderSig, bytes borrowerSig, MatchParams params) external returns (address creditAccount)`  
  Actions: verify signatures and nonces; check expiries; ensure same `asset` and `interestRateModel`; validate `compare(lender.rateParams, borrower.rateParams)`; check duration intersection and `principal` bounds; ensure collateral lists/LTs match and each LT < underlying LT; enforce borrower full fill and update lender `alreadyFilled`; validate `validationStrategy` hooks; create credit account; set per-loan terms; set collateral config; pull funds from lender or `fundingVault` and unwrap; initialize per-account interest index state (matching prior pool logic, but per account); execute `openingCalls`; emit `OrderMatched`/`CreditLineOpened`.  
  Reverts: invalid signature; order expired; cancelled order; borrower principal not fully matched; lender order over-filled; asset/IRM mismatch; `compare` fails; duration out of bounds; collateral mismatch; LT >= underlying LT; `openingCalls` provided but collateral check fails; insufficient allowance/balance; `validationStrategy` fails; credit account creation fails.
- `function cancelOrder(bytes32 orderHash) external`  
  Actions: mark order as cancelled.  
  Reverts: not order owner; already cancelled.
- `function incrementNonce(uint256 newNonce) external`  
  Actions: set signer nonce to `newNonce` to invalidate prior orders.  
  Reverts: `newNonce` <= current nonce.
- `function requestEarlyClose(address creditAccount) external`  
  Actions: record lender-initiated close request; set grace-period deadline.  
  Reverts: caller not lender; credit account closed; request already active.
- `function clearEarlyCloseRequest(address creditAccount) external`  
   Actions: clear close request on borrower repayment or lender cancel.  
   Reverts: caller not lender or borrower; no active request.
  Interest accrual is performed in the same places and with the same formulas as in the prior pool-based implementation, but per account (no manual accrual entrypoints in MatchingEngine).

### `IInterestRateModel` (updated)

- `function compare(bytes lenderRateParams, bytes borrowerRateParams) external view returns (bool)`  
  Actions: compare two param sets for compatibility.  
  Reverts: params malformed or unsupported.
- `function getBorrowRate(bytes rateParams) external view returns (uint256)`  
  Actions: compute current borrow rate from `rateParams` (fixed or reference + spread).  
  Reverts: params malformed or reference rate unavailable.
- `function calcInterestIndex(uint256 indexLU, uint256 timestampLU, bytes rateParams) external view returns (uint256 newIndex)`  
  Actions: compute updated interest index given last index and timestamp.  
  Reverts: params malformed; invalid timestamp ordering.

### `ICreditManagerV3` (new/changed)

- `function openCreditAccountFor(address borrower, address lender) external returns (address)`  
  Actions: create credit account; set borrower/lender; register account.  
  Reverts: caller not MatchingEngine; borrower already has account (if disallowed); factory failure.
- `function setCreditAccountTerms(address creditAccount, address interestRateModel, bytes rateParams, uint40 maturity, uint16 earlyClosePenalty) external`  
  Actions: store IRM, rate params, maturity, penalty; initialize index/timestamps.  
  Reverts: caller not MatchingEngine; zero address IRM; invalid maturity; invalid penalty.
- `function setCreditAccountCollateralConfig(address creditAccount, address[] calldata tokens, uint16[] calldata lts) external`  
  Actions: store per-loan collateral list and LTs; set enabled masks; enforce `maxEnabledTokens`.  
  Reverts: caller not MatchingEngine; array length mismatch; too many tokens; LT >= underlying LT.
- `function setInterestIndex(address creditAccount, uint256 newIndex, uint40 timestamp) external`  
  Actions: update stored index and last update time.  
  Reverts: caller not MatchingEngine; timestamp not increasing.

### `ICreditFacadeV3` (new/changed)

- `function openMatchedCreditAccount(address borrower, address lender, address interestRateModel, bytes rateParams, uint40 maturity, uint16 earlyClosePenalty, address[] calldata tokens, uint16[] calldata lts, MultiCall[] calldata openingCalls) external returns (address)`  
  Actions: create account; set terms/collateral; transfer initial funds; execute `openingCalls`; run collateral check; emit open event.  
  Reverts: caller not MatchingEngine; invalid params; collateral check fails; multicall fails.
- `function closeCreditAccountByBorrower(address creditAccount, uint256 repayAmount, MultiCall[] calldata calls) external`  
  Actions: execute optional calls; repay debt; apply penalty on repaid amount if before maturity; route funds to lender/treasury; close account if fully repaid.  
  Reverts: caller not borrower; account not active; collateral check fails after calls; insufficient repay.
- `function closeCreditAccountByLender(address creditAccount, uint256 repayAmount, MultiCall[] calldata calls) external`  
  Actions: ensure grace period elapsed; execute optional calls; repay debt; apply penalty on repaid amount; close account if fully repaid.  
  Reverts: caller not lender; no active request or grace not elapsed; account not active.
- `function recordEarlyCloseRequest(address creditAccount) external`  
  Actions: set grace period deadline for lender-initiated close.  
  Reverts: caller not lender; request already active.

## Storage Migration / Backward Compatibility

- This is a breaking rewrite; do not attempt in-place upgrades.
- New deployment of contracts with new storage layout.
- If preserving analytics, export mappings from old pool contracts to offchain indexers.
- Referrals remain supported as-is in account opening events.

## Testing Plan

- Unit tests for order matching with valid/invalid parameter intersections and exact collateral/ LT matching.
- Tests for per-account collateral LT enforcement.
- Interest accrual tests for fixed and reference-rate models.
- Early close penalty scenarios (borrower/lender initiated).
- Lender-initiated close grace-period and liquidation after expiry.
- Liquidation scenarios: full repay, partial repay, loss.
- Access control tests for matcher role and config changes.

## Major TODOs

- Implement the account opening flow (who is the initiator?)
- Implement logic for early closure penalties
- Clean up Credit Facade
- Clean up Credit Configurator
- Implement basic interest rate models (fixed and reference rate)
- Minor TODOs
- Make it all compile (interface cleanup, etc)
- Early exit penalty as CM parameter and applied on liquidation
- remove token masks enttirely (keep getTokenMaskOrRevert for backward compat)
- Account selling and buying

## Open questions

- Price feed validation on account opening
