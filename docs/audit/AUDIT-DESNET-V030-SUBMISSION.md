# DeSNet v0.3.0 mainnet baseline — External Audit Submission (Round 1)

**Version:** v0.3.0 (mainnet baseline, pre-handle_fee_vault upgrade)
**Date:** 2026-05-02
**Chain:** Aptos mainnet (publish pending audit clearance)
**Audit scope:** 1 monolith package, 17 modules, ~7434 LoC Move, all compile clean
**Tests:** 68/68 unit + integration passing on `aptos move test`
**Source:** `AUDIT-DESNET-V030-SOURCE.md` (companion file, ~280KB concatenated)

**Prior audit:** v0.1.5 audit Round 1 covered 9 modules across 3 packages (`desnet-protocol`, `desnet-factory`, `desnet-governance`). Six prior modules carry over with minor changes; **eight modules are NEW or rewritten** for v0.3.0.

**Testnet deployment (live, fully smoke-verified):**
- v0.3.0 baseline pkg: `0x1725288b62cb6139714c196d7e20c1bea98962aeb828c6c9a9d795005c493f3e`
- 25 sequential smoke tx all GREEN: register_handle atomic + 3 Position kinds + universal fee accumulator + vault settle + PID NFT transfer mid-stake + 7 verbs end-to-end + giveaway lifecycle + reservation guard
- v0.3.1 compat upgrade (handle_fee_vault) also tested on testnet — proves upgrade path. Out of scope for THIS audit (separate Round 2 after baseline mainnet deploy).

**Planned mainnet deploy:** 1/5 multisig at publish, raised to 3/5 after smoke per `feedback_mainnet_deploy_sop.md`. Per-handle reserved claimers fixed in baseline (5 reserved handles bound to 5 different addresses to preserve 1-wallet-1-PID rule).

---

## ⚠ Architecture changes vs v0.1.5

This is **clean-slate Round 1** for v0.3.0 architecture. The original 3-package layout (desnet-protocol + desnet-factory + desnet-governance) was consolidated into a single monolith pkg + key economic primitives rewritten in-house.

**Major changes:**

| Change | Before (v0.1.5 / v0.2.x) | After (v0.3.0) |
|---|---|---|
| Pkg layout | 3 packages | 1 monolith |
| LP repr | darbitex_staking::LpStakePosition (external dep) | `desnet::lp_staking::Position` NFT (in-house V3-style) |
| AMM | darbitex pool (external dep) | `desnet::amm` in-house V3 fork (10 bps, no arb module, flash loans kept) |
| Pool create | post-register_handle, lazy seed | atomic at register_handle (PID + token + pool + locked LP single tx) |
| Locked LP | sealed via custody-transfer to darbitex_lp_locker | `Position` resource at pid_addr, no withdraw fn for unlock_at=u64::MAX |
| Fee model | only staked LP (initial bug) | universal accumulator (denom = total lp_supply, all positions earn) |
| Fee claim | via darbitex_staking::claim_with_governance wrapper | direct `lp_staking::claim` triple-settle (emission + APT fee + TOKEN fee) |
| Recipient resolve | factory::vault_addr_of_pid → object::owner | same pattern, generalized to Position.recipient_pid |
| Voting power | via factory's lp_emission::claim_with_governance wrapper | via lp_staking::claim_internal + governance::derive_pkg_signer + voter_history |
| Allocation | 90/5/5 (creator alloc 5%) | 90/5/5 (creator alloc DROPPED → pool seed inherits 5%) |
| Handle fee | 100/50/20/10/5/1 APT (D denominated) | 100/50/20/10/5/1 APT + 5 APT pool seed (= total 105/55/25/15/10/6 APT) |
| Reserved handles | none | 5 reserved (desnet/darbitex/d/aptos/apt), per-handle claimer addr |
| Frontend URI hardcodes | hardcoded "https://desnet.wal.app/" in factory + press | EMPTY strings (frontend renders) — domain not owned |
| Self-burn | DESNET vault buyback-burn (deferred design) | DESNET buyback-burn DEFERRED to v0.3.1 compat upgrade (out of scope this audit) |

**Carry-over modules (minor edits or unchanged from v0.1.5):**
- `assets`, `history`, `mint`, `pulse`, `press`, `link`, `giveaway`, `reference_gate`, `voter_history`, `governance`, `reaction_emission`

**NEW or full-rewrite modules (focus area for this audit):**
- `amm` — V3-style CPMM, position NFT LP, flash loans, fee accumulator
- `lp_staking` — unified Position struct (3 kinds: locked-creator/free/time-locked), C-variant emission + V3 fee claim
- `factory` — atomic register flow, monolith friend graph, reservation guard
- `apt_vault` — in-house pool buyback (was darbitex_pool::swap)
- `lp_emission` — pull-based (was push-based + cross-pkg wrapper)
- `profile` — pool seed param, handle_fee_vault prep, reservation guard, derive_pkg_signer route via governance friend

---

## 1. What we are asking from you

Please respond in the following format. Don't shorthand — verbose responses help cross-auditor reconciliation.

### Findings

For each finding, include:
- **Title** (one line)
- **Severity:** HIGH / MEDIUM / LOW / INFO
- **Module + line range**
- **Issue description** (what's wrong)
- **Risk** (concrete attack scenario or operational hazard)
- **Suggested fix** (specific code change or design pivot)
- **Confidence** (HIGH if you traced the call path; MEDIUM if pattern-match; LOW if speculative)

### Severity definitions

- **HIGH:** loss of funds, permanent state corruption, locked-out positions, unauthorized minting/burning, governance bypass
- **MEDIUM:** griefing, DoS at module level, unintended state, broken downstream invariant
- **LOW:** edge case, defense-in-depth gap, gas waste, minor UX concern
- **INFO:** observation, naming, doc clarity, style

### Design questions

For each design question (Section 7 below), give an explicit answer:
- **Answer:** Sound / Acceptable trade-off / Concerning / Wrong
- **Reasoning:** 2-4 sentences
- **Alternative if Concerning/Wrong**

### Overall verdict

🟢 GREEN (ship-ready) / 🟡 YELLOW (ship after fixes) / 🔴 RED (do not ship)

Plus 1-paragraph rationale.

---

## 2. Project context

**DeSNet** = Aptos-native decentralized social network protocol. Each registered handle gets:
- A PID (Profile ID) Object NFT — transferable identity
- A factory-spawned `$<handle>` token (1B supply, 8 dec)
- An APT/`$<handle>` AMM pool seeded with 5 APT + 50M tokens
- A locked LP Position at pid_addr (forever-locked, emission rights to current PID NFT owner)
- A vault for press royalties + future revenue

7-verb action palette: mint / spark (like) / voice (reply) / echo (repost) / remix (quote) / press (NFT collectible) / sync (subscribe). All actions logged to per-PID append-only history (BCS encoded, not events).

**Cost to register a handle (per char-tier):**
- 1 char: 100 + 5 = 105 APT
- 2 char: 50 + 5 = 55
- 3 char: 20 + 5 = 25
- 4 char: 10 + 5 = 15
- 5 char: 5 + 5 = 10
- 6+ char: 1 + 5 = 6

**5 reserved handles (per-handle claimer addrs):**
- `desnet` → @origin (= deployer multisig, dynamic)
- `darbitex` → `0xc988d39a...` (Darbitex Final publisher multisig)
- `d` → `0x587c8084...` (D Aptos pkg, sealed → effective burn, intentional)
- `aptos` → `0xdbce8911...` (Darbitex treasury 3/5)
- `apt` → `0xf1b522e...` (dedicated multisig)

---

## 3. Core design principles

### V3-style position NFT LP (universal fee accrual)
LP shares are NOT a fungible token. Each LP unit lives in a `Position` Object (NFT). Fees + emission tracked per-position via accumulator pattern (V3 / MasterChef shape). Allows fee claim WITHOUT burning LP — locked-creator earns continuously while LP stays sealed.

### Atomic register_handle (single tx all-or-nothing)
profile::register_handle → factory::create_token_atomic → mint $TOKEN + spawn pool + lock initial LP into pid_addr Position. Caller pays handle_fee_apt(len) + 5 APT pool seed in same tx. Any abort reverts all.

### Forever-lock structural enforcement
Locked-creator Position has `unlock_at_secs = u64::MAX`. `lp_staking::remove_liquidity` aborts with `E_LOCKED_FOREVER` BEFORE calling `amm::remove_liquidity_internal`. amm pool reserves never returned for forever-locked shares. LP shares contribute to lp_supply forever, accruing yields to current PID owner.

### Auto-resolved recipient (PID NFT owner at claim time)
Position.recipient_pid is non-zero for locked-creator positions. At claim time, recipient = `object::owner(pid_obj)`. PID NFT transfer instantly flips emission rights to new owner. No reconfiguration needed.

### Cross-module signer-addr authentication for voting power
`voter_history::record_reward_received(authority, voter, amount)` asserts `signer::address_of(authority) == @desnet`. Only `lp_staking::claim_internal` calls this, after deriving pkg_signer via `governance::derive_pkg_signer()`. Single source of voting power generation.

### Friend graph (no cycles)
Verified friend relationships:
```
governance → friend factory, profile, amm, lp_staking
profile → friend mint, link, pulse, press, giveaway, history, factory
factory → friend profile (create_token_atomic)
amm → friend factory, lp_staking, apt_vault
lp_staking → friend factory
apt_vault → friend factory
lp_emission → friend factory, lp_staking
```
Cycle prevention: `lp_staking` does NOT use `desnet::profile`. Profile derives pid_signer locally and passes through factory → lp_staking as `&signer` param.

### Append-only history with cached counters
Per-PID `HistoryLog` + `HistoryChunk` sequence (30KB chunks, rotate-and-seal). Each verb call appends a BCS-encoded entry + bumps cached counter (`count_verb`). Replaces event::emit for the 7-verb palette. Move-readable for gating logic.

### Permissionless economic primitives
All revenue/buyback flows are permissionless poke triggers (anyone can call `apt_vault::settle`, `lp_staking::claim`). No keeper service required. Minimum threshold (0.1 APT) + dust protection.

### No indexer dependency for gating
`reference_gate` queries amm + lp_staking + factory views directly. No subgraph / TheGraph / off-chain indexer needed for permission checks.

### Per-handle reserved claimer (fixes 1-wallet-1-PID conflict)
Each reserved handle bound to a specific authorized claimer address. Different per handle so each gets unique PID slot. Public users derive PID from wallet (1-1 rule preserved); reserved handles bypass guarded by addr check.

---

## 4. Security model and trust assumptions

### Trusted parties
- **Multisig signers** (1/5 at publish, 3/5 post-smoke). Can: trigger compat upgrades via `governance::multisig_upgrade`, register reserved `desnet` handle (= @origin = @desnet_claimer).
- **DAO voters** (post-DAO transition). Can: propose + vote + ratify + execute upgrades (35% quorum, 70% approval, 30d timelock).
- **Aptos Labs** for framework primitives (FA, Object, primary_fungible_store, code).

### Untrusted parties
- **Anyone calling public entries**: register_handle, swap, add/remove_liquidity, claim, settle, mint, spark, etc. Inputs validated, slippage protected, threshold-gated.
- **PID NFT secondary owners**: receive emission/fee/vault disburse via auto-resolve, but cannot retroactively claim past accruals (those go to addr-at-claim-time, frozen for prior owner).
- **Position transferees**: NFT semantics — new owner inherits unstake rights + future yield.
- **Flash loan borrowers**: hot-potato FlashReceipt enforces strict repay equality.

### Threat model we care about
- **Squat front-running** of reserved handles (mitigated by per-handle claimer guard)
- **Pool drain** via swap math overflow / division mismatch (mitigated by u128 widening + unit tests)
- **Reentrancy** during flash loan window (mitigated by `pool.locked` flag, gates all swap/LP/flash entries — fee extraction also gated per self-audit M1 fix)
- **Locked LP extraction** by any path (structurally impossible — `unstake` aborts E_LOCKED_FOREVER; LP FA never leaves Position resource at pid_addr)
- **Voting power inflation** outside lp_staking::claim path (mitigated by addr-based auth at @desnet)
- **PID hijack** via duplicate registration (mitigated by E_HANDLE_TAKEN + factory registry uniqueness + FA addr collision)
- **Buyback math drift** (V3 truncation precision drift — bounded dust, accepted as standard V3 behavior)

### Threat model we do NOT care about
- **MEV / mempool ordering**: Aptos has no public mempool, sequenced by validators
- **Oracle manipulation**: no external oracle, pool reserves are the sole price source (documented in WARNING)
- **Standard Aptos framework bugs**: presumed sound (Aptos Labs maintained, validator-governed)
- **User-side key loss**: standard wallet hygiene, no recovery mechanism
- **Front-end XSS via SVG content**: documented as frontend responsibility (img-tag-sandbox per `feedback_decentralized_web_hosting`)

---

## 4a. Dependencies

### External (Aptos mainnet, presumed-sound)
- `0x1::aptos_framework` (object, fungible_asset, primary_fungible_store, coin, aptos_coin, account, code, resource_account, event, timestamp)
- `0x1::aptos_std` (smart_table, math128)
- `0x4::aptos_token_objects` (token, collection, royalty)

### External addresses referenced (NOT trusted, just identified)
- darbitex Final publisher multisig: `0xc988d39a...` (= `darbitex_claimer` for handle reservation)
- D Aptos pkg (sealed): `0x587c8084...` (= `d_claimer`, no signer derivable)
- Darbitex treasury multisig: `0xdbce8911...` (= `aptos_claimer`)
- Dedicated multisig: `0xf1b522e...` (= `apt_claimer`)
- APT FA metadata: `@0xa` (Aptos paired-coin standard)

### Inter-module dependencies (intra-pkg)
See friend graph in Section 3. All within @desnet pkg (monolith). Compat upgrade target = same pkg.

---

## 5. Module map (17 modules)

### Orchestration (3)
- `governance` (489 LoC) — DAO proposal lifecycle + multisig fallback + pkg signer custodian
- `factory` (450 LoC) — atomic spawn orchestrator (token + vault + reserves + AMM pool + locked stake)
- `profile` (799 LoC) — PID NFT primitive + register_handle + admin entries + reservation guard

### AMM + staking (NEW for v0.3.0) (2)
- `amm` (922 LoC) — V3-style CPMM (10 bps fee, position NFT LP, flash loans, universal accumulator)
- `lp_staking` (672 LoC) — unified Position struct, 3 kinds (locked/free/time-locked), triple-settle claim

### 7-verb palette (4)
- `mint` (605 LoC) — Mint/Voice (reply)/Remix (quote) — single MintEvent semantic via parent_set/quote_set flags
- `pulse` (261 LoC) — Spark + Echo
- `press` (471 LoC) — Press NFT collectible (vinyl-press metaphor) + reaction emission bonus
- `link` (214 LoC) — Sync action + PidSyncSet

### Storage primitives (2)
- `history` (454 LoC) — per-PID append-only BCS log, 30KB chunk rotate, cached counters
- `assets` (527 LoC) — fractal-tree on-chain media (>8KB), MIME PNG/JPEG/WebP/GIF/SVG, sealed-after-finalize

### Economics (3)
- `apt_vault` (205 LoC) — APT receiver, 50/50 buyback-burn / disburse to current PID owner via in-house amm
- `lp_emission` (192 LoC) — 90% supply reserve, pull-based for lp_staking::claim
- `reaction_emission` (244 LoC) — 5% supply reserve, anti-FOMO press emission curve

### Social/gating (3)
- `reference_gate` (177 LoC) — gate primitive (sync + balance + LP-stake), pure fn
- `giveaway` (521 LoC) — FA + NFT giveaway escrow with 3-gate eligibility (follower / nft / lp_stake)
- `voter_history` (231 LoC) — per-voter cumulative LP staking rewards = sole voting power source

---

## 6. Locked-in constants (per-module)

### `amm`
- `FEE_BPS = 10` (swap fee, 100% to LP)
- `FLASH_FEE_BPS = 10` (= LP swap fee, uniform)
- `FEE_DENOM = 10000`
- `MIN_INITIAL_LP = 1000` (anti-zero-share griefing on first mint)
- `FEE_ACC_SCALE = 1e18` (V3-style scaled accumulator)
- `APT_FA_ADDR = @0xa`
- `SEED_POOL = b"desnet::amm::pool::"` (deterministic pool addr seed)

### `lp_staking`
- `DEFAULT_RATE_PER_SEC = 1_000_000_000` (= 10 $TOKEN/sec at 8 dec; 900M reserve / rate ≈ 2.85 yr depletion)
- `ACC_SCALE = 1e18` (emission accumulator scale)
- `UNLOCK_FOREVER = u64::MAX` (locked-creator marker)
- `SEED_STAKING_POOL = b"desnet::lp_staking::pool::"`

### `factory`
- `TOTAL_SUPPLY = 100_000_000_000_000_000` (1B at 8 dec)
- `TOKEN_DECIMALS = 8`
- `POOL_SEED_TOKEN_AMOUNT = 5_000_000_000_000_000` (50M, 5%)
- `REACTION_RESERVE_AMOUNT = 5_000_000_000_000_000` (50M, 5%)
- `LP_EMISSION_AMOUNT = 90_000_000_000_000_000` (900M, 90%)
- `POOL_SEED_APT_AMOUNT = 500_000_000` (5 APT)
- `HANDLE_MIN_LEN = 1`, `HANDLE_MAX_LEN = 64`

### `profile`
- `PRICE_1_CHAR_APT = 100 APT`, `PRICE_2_CHAR_APT = 50`, ..., `PRICE_6PLUS_CHAR_APT = 1`
- `AVATAR_MAX_BYTES = 8192` (inline base64)
- `BIO_MAX_BYTES = 333`
- `APT_FA_METADATA = @0xa`

### `apt_vault`
- `APT_SETTLE_THRESHOLD = 10_000_000` (0.1 APT, anti-dust settle)

### `lp_emission`
- (no constants beyond seeds)

### `history`
- `MAX_PAYLOAD_BYTES = 12000` (per-entry ceiling)
- `CHUNK_ROTATE_THRESHOLD = 30000` (chunk size before rotate)
- 7 verb constants (MINT=0, SPARK=1, VOICE=2, ECHO=3, REMIX=4, PRESS=5, SYNC=6)

### `assets`
- 5 MIME constants (PNG=1, JPEG=2, GIF=3, WebP=4, SVG=5)
- `CHUNK_SIZE_MAX = 30000`
- `MAX_TOTAL_SIZE = 5_000_000` (5MB total per Master)

### `reaction_emission`
- `REACTION_BASE_VALUE = 100_000_000` (1 token per press order)
- (anti-FOMO curve constants)

### `governance`
- `PROPOSAL_THRESHOLD_BPS = 500` (5% of 30d emission)
- `QUORUM_BPS = 3500` (35%)
- `APPROVAL_THRESHOLD_BPS = 7000` (70%)
- `VOTING_PERIOD_SECS = 7 days`
- `TIMELOCK_SECS = 30 days`

### `voter_history`
- `VOTING_WINDOW_SECS = 30 days` (rolling window for voting power)

---

## 7. Specific review questions (prioritized — focus on NEW v0.3.0 paths)

### Q1 — `amm::create_pool_atomic` friend-only invariants
Friend list: factory, lp_staking, apt_vault. Only factory should be the legitimate caller during register_handle. lp_staking + apt_vault are friends because they call other amm fns (extract_fees_for_claim, swap_exact_apt_in). Question: does the friend graph allow accidental pool creation by a different friend? Trace the call paths. Risk: any unauthorized pool create lets attacker spawn a fake pool, hijack LP supply or fee accumulator.

### Q2 — Universal fee accumulator denominator semantics
`amm::swap_exact_apt_in` advances `fee_per_lp_apt += (fee × ACC_SCALE) / lp_supply`. Denominator = TOTAL lp_supply (locked-creator + free + time-locked all share). Each Position claims via `(acc - last_acc) × shares / ACC_SCALE`. Question: is the truncation always pool-favorable (no over-pay)? Walk through scenario where many small claims accumulate. Verify sum of per-position claims ≤ accumulated fee bucket (no underflow possible in `extract_fees_for_claim`).

### Q3 — Locked-creator forever-lock structural enforcement
`lp_staking::remove_liquidity` auth: `position_owner == caller` AND `unlock_at_secs != UNLOCK_FOREVER` (E_LOCKED_FOREVER) AND `now >= unlock_at`. For locked-creator: `unlock_at = u64::MAX`, recipient_pid = pid (non-zero). LP FA held inside Position.locked_lp_store (child FungibleStore owned by Position addr). Position created via `move_to(&pid_signer, ...)` at pid_addr. **Question:** can ANY code path extract Position.locked_lp_store contents OTHER than `unstake`? Check pid_signer access (profile::derive_pid_signer can re-derive — does it grant store access to pid_addr's child stores?). Map the signer access tree.

### Q4 — Recipient auto-resolution at claim time
`lp_staking::resolve_recipient`: if `recipient_pid == @0x0` → `object::owner(position_obj)` else → `object::owner(pid_obj)`. Used in `claim_internal` for triple-settle disbursement. Question: race between PID transfer + claim within same block — does Aptos sequencing guarantee atomicity? Could a frontrun PID transfer steal an in-flight claim? (Test scenario: alice pokes claim, bob frontruns by transferring PID NFT from current_owner → bob_addr, alice's claim disburses to bob.)

### Q5 — Reservation guard PID derivation correctness
`profile::register_handle`: if `is_reserved_handle(handle)` → `wallet_addr == required_claimer` (E_RESERVED_HANDLE). PID derived from wallet_addr only (`derive_pid_address(wallet_addr)`). Each reserved handle has DIFFERENT claimer addr → 5 reserved handles get 5 different PIDs (no collision). Question: any way to bypass via custom Move script that changes wallet_addr semantics? Or via cross-module re-entry? Verify the guard is comprehensive.

### Q6 — Atomic register_handle abort safety
profile.move::register_handle sequence: validate → fee → pid mint → registry insert → factory::create_token_atomic. Factory does: token spawn + 3 reserves + vault + amm pool + locked Position. Any abort reverts whole tx (Move atomicity). Question: are there ANY non-revertible operations? E.g. event emit doesn't revert. Off-chain side effect via dispatchable FA hook (we don't use, but verify). Custom token/asset standards we depend on?

### Q7 — Handle string validation completeness
`factory::validate_handle` accepts a-z, 0-9, '-' (lowercase + digits + hyphen). Length 1-64. Question: does this prevent ALL homoglyph attacks (Cyrillic 'а' that looks like Latin 'a')? Bytes are UTF-8 encoded — Cyrillic = 2-byte sequence, would fail char check. Verify. Also: is the handle vector compared as bytes-only or normalized? Does `b"alice"` ever conflict with `b"Alice"` (it shouldn't since uppercase blocked)?

### Q8 — Flash loan reentrancy comprehensive coverage
`Pool.locked: bool` set true in flash_borrow, false in flash_repay. Gates: add_liquidity_internal, remove_liquidity_internal, swap_exact_apt_in, swap_exact_token_in, flash_borrow, extract_fees_for_claim (M1 self-audit fix). Question: any missed entry? Test case: during flash window, can attacker call any amm fn that mutates state? Verify exhaustive coverage.

### Q9 — Voting power source authentication
`voter_history::record_reward_received`: asserts `signer.addr == @desnet`. Called from `lp_staking::claim_internal` via `governance::derive_pkg_signer()` (pkg_signer at @desnet). Question: is this the SOLE call site? Audit grep. Question: can pkg_signer be obtained via any other path (besides governance friend access by amm/lp_staking/factory/profile)? Verify the friend graph closure.

### Q10 — Anything else
Free-form. Especially: anything you'd want to ask the dev team that the 9 questions above didn't cover. Architecture concerns. Scaling concerns. UX concerns. Mainnet deploy concerns. Anything that gives you "this is suspicious" feeling but you can't articulate as a specific finding.

---

## 8. Reference materials (in companion source file)

- `AUDIT-DESNET-V030-SOURCE.md` — full 17-module source (~280KB)
- `docs/v0.3.0-design-lock.md` — original design lock document (in repo)
- `docs/v0.3.0-self-audit.md` — internal self-audit doc (8-dim SOP)

---

## 9. Self-audit summary (pre-submission)

We ran an internal 8-dim self-audit per `feedback_satellite_self_audit.md`:

**Dimensions covered:**
1. **ABI** — all public fns enumerated, friend graph verified, single non-composable surface = `create_pool_atomic`
2. **Args** — range/length/addr checks on all entries
3. **Math** — u128 widening for mul, no /0, fee accumulator overflow-safe (~1e22 yr tolerance), constants verified
4. **Reentrancy** — flash lock 7 sites (all swap/LP/flash + extract_fees), no dispatchable FA hooks, sealed forever-lock structural
5. **Edges** — zero amounts, empty reserves, dust, duplicate, forever-lock, time-lock all guarded
6. **Cross-module** — atomic register_handle, triple-settle claim chain, vault settle chain, voter_history pathway preserved
7. **Errors** — amm 15 codes / lp_staking 10 codes — all used, no dead
8. **Events** — every state change emits, indexer-grade

**Findings: 0 HIGH / 1 MED applied / 1 MED docs-only / 3 LOW accepted**

| ID | Severity | Item | Status |
|---|---|---|---|
| M1 | MED | extract_fees_for_claim not gated by flash lock | ✅ FIXED (1-line `assert!(!pool.locked)`) |
| M2 | MED | Position NFT transferability docs only | docs-only, frontend disclosure |
| L1 | LOW | Dust flash loans 0-fee | documented in WARNING |
| L2 | LOW | Fee bucket precision drift | accepted V3 standard |
| L3 | LOW | 44 doc-comment placement warnings | cosmetic, non-blocking |

External multi-LLM audit YOU ARE READING NOW = darbitex SOP standard verification.

---

## 10. Mainnet deploy plan (post-audit)

1. Apply HIGH/MED fixes from this audit (target ≤1 week iteration)
2. Final compile + test re-run + git tag v0.3.0-mainnet-baseline-final
3. Multi-LLM Round 2 verification (smaller, focused on fixes only)
4. Mainnet publish via 1/5 multisig per `feedback_mainnet_deploy_sop.md`
5. Reserved handle claims (4 controllable, 47 APT total)
6. Compat upgrade to v0.3.1 (handle_fee_vault) — separate audit Round 3 if material
7. Frontend deploy on Walrus (decentralized hosting)

**Audit completion target:** 1 week from receipt. Verbose responses preferred — cross-auditor reconciliation matrix needs detail.

Thank you for your time. Looking forward to your findings.

— Rera (DeSNet protocol author + Claude Opus 4.7 (1M context) co-author)
