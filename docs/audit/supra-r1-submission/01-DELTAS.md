# 01-DELTAS — Supra-specific surfaces vs Aptos v0.3.3

This document walks through the code surfaces that differ from the audited
Aptos v0.3.3 branch. Aptos-side review (R1-R6) covers governance, amm,
lp_staking, voter_history, factory, profile (base handle), supra_fee_vault
(= ported handle_fee_vault), and the verb modules at their v0.3 form. The
Supra port reuses all of those with framework substitutions (`aptos_framework`
→ `supra_framework`, native FA = SUPRA) but adds the surfaces below.

---

## D-1 — IPO module (`sources/ipo.move`)

**New module, 0 prior audit.** Replaces the v0.3 "atomic spawn" launch flow.

### Lifecycle

1. `factory::create_token_atomic` (friend-only, called by `registration`):
   mints 100% of `TOTAL_SUPPLY` into an IPO pool's `token_store` and calls
   `ipo::create_ipo(handle, ..., creator_wallet)`. No creator-locked LP at
   this point — handle = identity only.

2. Anyone calls `ipo::deposit_supra(caller, handle, amount, subdomain)`:
   - Cap check: `caller_addr == ipo.creator_wallet` ⇒ 10% cap, else 1%.
   - SUPRA in, proportional `$TOKEN` out via fixed `entry_price_x / y`.
   - First deposit: `amm::create_pool_atomic(handle, supra_fa, token_fa,
     ipo_addr, /* swaps_enabled */ false)` — pool exists but locked.
   - Subsequent deposits: `amm::add_liquidity_internal` — proportional LP
     mint at current reserves.
   - Reward debts snapshot taken against `lp_emission` gauge for every
     registered reward token.
   - `lp_emission::on_share_increase(handle, lp_minted)` — push the new
     share into the gauge's `total_share` *before* storing Position so
     concurrent reads see the deposit counted.
   - **Position stored AT subdomain PID's deterministic addr** (not as a
     separate Object). `move_to(&pos_signer, Position { ... })` where
     `pos_signer = profile::derive_pid_signer(subdomain_pid_addr)`.
     Transferring the Profile NFT implicitly carries the Position.

3. `ipo::burn_for_refund(caller, handle, position_addr, min_supra_out,
   min_token_out)`:
   - Pre-completion only (`!ipo.completed`).
   - Auth: `object::owner(profile::Profile @ position_addr) == caller`.
   - Settle pending gauge rewards into caller first
     (`claim_lp_rewards_internal`).
   - `amm::remove_liquidity_internal(handle, shares, min_supra_out,
     min_token_out)`.
   - SUPRA back to caller; token goes back to IPO reserve.
   - **Y-1 anti-wash**: `depositor_totals[pos.depositor]` decremented
     **only if** `caller_addr == pos.depositor`. If the NFT has been
     transferred, the original depositor's cap stays consumed.
   - **Y-2 slippage**: caller-supplied `min_supra_out` + `min_token_out`.
   - Subdomain registry entry released.
   - `lp_emission::on_share_decrease(handle, lp_amount)`.
   - Position resource destroyed via `move_from<Position>`. **Profile
     NFT remains orphan** (refund is pre-completion only — accepted
     limitation; re-registration of same subdomain name aborts at
     `create_subdomain_profile` because Profile already exists).

4. `ipo::complete_ipo(_caller, handle)` — permissionless.
   - Guard: `total_supra_raised >= target_tvl` (added in `a72ac9e`
     after a self-audit caught that `> 0` permitted permissionless
     completion after the first deposit, voiding the refund promise).
   - Flips `ipo.completed = true`.
   - Calls `amm::enable_swaps(handle)` — pool unlocks, swaps allowed.
   - `supra_vault::set_pool_addr_of_handle` wires buyback target.

5. `ipo::claim_lp_rewards(_caller, handle, position_addr)` —
   permissionless poke.
   - Resolves recipient via `object::owner(profile::Profile @
     position_addr)` — auto-follows NFT transfer.
   - For each registered reward token: pending = `(acc_per_share -
     reward_debt) × shares / ACC_SCALE`, withdraw + deposit to
     recipient, update `reward_debt`.
   - DESNET claims also call
     `voter_history::record_reward_received_for_token`.

### Y-1 anti-wash in burn_for_refund

```move
// Y-1: anti-wash. Only free the depositor's allocation cap if the
// refund is initiated by the ORIGINAL depositor (NFT never moved).
// If the subdomain NFT has been transferred to a different owner,
// the original depositor's cap stays consumed - closes the
// deposit -> transfer -> refund -> re-deposit cycling exploit that
// would otherwise let a single wallet rotate its 10% slot
// indefinitely for market-manipulation purposes.
if (caller_addr == pos.depositor) {
    let original_depositor = pos.depositor;
    let remaining = *smart_table::borrow(&ipo.depositor_totals, original_depositor) - pos.supra_deposited;
    if (remaining == 0) {
        smart_table::remove(&mut ipo.depositor_totals, original_depositor);
    } else {
        *smart_table::borrow_mut(&mut ipo.depositor_totals, original_depositor) = remaining;
    };
};
```

**Reviewer please scrutinize**: does the conditional miss any legitimate
honest-user path? See `03-REVIEWER-CHECKLIST.md` Q1.

### Y-2 slippage on burn

`amm::remove_liquidity_internal(handle, lp_amount, min_supra_out, min_token_out)`
— caller-supplied bounds. Caller passes `(0, 0)` for legacy no-slippage
behavior.

---

## D-2 — Atomic creator registration (`sources/registration.move`)

**New module.** Breaks the dep cycle profile→factory→ipo→profile by lifting
orchestration out of profile.

Two entries:

```move
public entry fun register_handle(...)
public entry fun register_handle_with_creator_seed(
    wallet: &signer,
    handle: vector<u8>,
    controller_addr: address,
    avatar_b64, bio,
    token_name, token_symbol, token_icon_uri, token_project_uri,
    ipo_target_tvl: u64,
    ipo_entry_price_x: u64,
    ipo_entry_price_y: u64,
    creator_subdomain: vector<u8>,
    creator_supra_amount: u64,
)
```

The `_with_creator_seed` variant is one transaction containing three
sequential calls (atomic):

1. `profile::register_handle` — creates main PID NFT.
2. `factory::create_token_atomic(handle, pid_addr, wallet_addr, ...,
   creator_wallet=wallet_addr)` — mints 100% supply into IPO,
   `creator_wallet` frozen.
3. `ipo::deposit_supra(wallet, handle, creator_supra_amount,
   creator_subdomain)` — creator self-deposits, qualifies for 10% cap
   because `caller == creator_wallet`. LP locks onto creator's chosen
   subdomain PID.

Atomicity: any sub-call abort reverts the whole tx (Move tx semantics).
factory is friend-only on registration; no third-party can race the handle.

**Reviewer please scrutinize**: front-running surface, partial-failure
analysis. See `03-REVIEWER-CHECKLIST.md` Q2.

---

## D-3 — Subdomain PID as first-class citizen (`sources/profile.move`)

**Modified.** Original Aptos branch only supported main-handle PIDs;
verbs derived `pid_addr = profile::derive_pid_address(signer::address_of(caller))`.
Subdomain holders couldn't use any verb.

Two changes:

1. `profile::create_subdomain_profile(protocol_signer, handle, subdomain,
   controller, pre_ipo_cohort)`:
   - Public function (signer-gated via `protocol_signer` which only
     `governance::derive_pkg_signer` produces — `public(friend)` chain
     enforces).
   - Derives addr from `SEED_SUBPID || bcs::to_bytes(&handle) ||
     bcs::to_bytes(&subdomain)` — distinct from main PID seed.
   - `validate_subdomain` enforces `[a-z0-9-]{1..32}` — same rule as
     `validate_handle` but separate fn (lower bound 1 instead of 3).

2. `profile::assert_authorized(caller, pid_addr)` — `public(friend)`,
   passes if `signer_addr == object::owner(pid_obj) || signer_addr ==
   Profile.controller`.

13 verb entries gained explicit `pid_addr` arg:

- `mint::create_mint(author, author_pid, ...)`
- `mint::create_opinion_mint(author, author_pid, ...)`
- `mint::attach_mint_gate(author, author_pid, ...)`
- `pulse::spark/unspark/echo/unecho(actor, actor_pid, ...)`
- `link::sync/unsync(syncer, syncer_pid, ...)`
- `press::enable_press(author, author_pid, ...)`
- `press::press(presser, presser_pid, author_pid, ...)`
- `giveaway::create_fa_giveaway/create_nft_giveaway(sponsor, sponsor_pid, ...)`
- `giveaway::claim_giveaway(claimer, claimer_pid, ...)`

All call `profile::assert_authorized(caller, pid)` as the auth check.

**Frontend implication**: ALL verb calls must now pass the explicit
`pid_addr`. Frontend resolves which PID the user is acting "as" — main
or one of their subdomains.

---

## D-4 — Locked-LP-on-subdomain (`sources/ipo.move::Position`)

**New design pattern.** Replaces the v0.3 LP-staking-NFT pattern (where
LP was its own Object NFT).

Position is **a resource stored AT the subdomain PID's deterministic
address**, not a separate Object. Schema:

```move
struct Position has key {
    ipo_addr: address,
    depositor: address,            // original depositor wallet (for Y-1 anti-wash)
    supra_deposited: u64,
    shares: u128,                  // LP shares in AMM pool
    fee_debt_supra: u128,          // MasterChef fee debts (matches amm::fee_per_lp)
    fee_debt_token: u128,
    reward_debts: SmartTable<address, u128>,   // per-FA debt against lp_emission gauge
    subdomain: String,
}
```

`position_addr == subdomain_pid_addr`. Transferring the Profile NFT
moves ownership of both the identity and the locked LP. Auth on all
claim/burn paths resolves via `object::owner(profile::Profile @
position_addr) == caller_addr`.

**Accepted limitation**: `burn_for_refund` does `move_from<Position>`
but **does not delete the Profile NFT** (no `object::delete`). The
Profile remains orphan; subdomain name effectively dead (cannot be
re-registered while orphan Profile exists). Refund is pre-completion
only.

**Reviewer please scrutinize**: NFT transfer race with reward claim;
position destruction borrow ordering. See `03-REVIEWER-CHECKLIST.md` Q3.

---

## D-5 — Multi-FA permissionless gauges (`lp_emission.move` + `reaction_emission.move`)

**New module pair.** Replaces the v0.3 sealed-`$TOKEN`-reserve emission.

### lp_emission — MasterChef-style multi-FA gauge

- Per-handle pool, lazy-init on first `notify_reward`.
- `notify_reward(depositor, handle, reward_token_meta, amount)` —
  permissionless entry. Allocates a slot in `reward_tokens: SmartTable<addr,
  RewardAccumulator>` (cap `MAX_REWARD_TOKENS=32`) and advances
  `acc_per_share += (amount × ACC_SCALE) / total_share`.
- **Y-4 fix**: rejects FAs with dispatchable hooks
  (`deposit_dispatch_function` or `withdraw_dispatch_function`).
- `total_share` is **push-driven** via friend fns
  `on_share_increase(handle, shares)` / `on_share_decrease(handle, shares)`
  called by `ipo::deposit_supra` / `ipo::burn_for_refund`. Keeps the dep
  direction one-way (ipo → lp_emission, no callback).
- `withdraw_reward` friend fn for `ipo::claim_lp_rewards` path.
- ACC_SCALE = `1e12` (MasterChef standard, lowered from `1e18` to keep
  `shares × acc` clear of `u128_max`).
- **DESNET-token notifies ALSO feed `governance::record_emission_for_window`**
  for DAO 30d threshold tracking.

### reaction_emission — BPS-of-pool gauge per author PID

- **Keyed by author PID address** (not handle string). Fix for the
  handle-collision hazard between main "alice" and subdomain "alice@bob"
  which `profile::handle_of()` both return as "alice".
- Lazy-init on first `notify_reward`.
- `notify_reward(depositor, author_pid, reward_token_meta, amount)` —
  permissionless entry. **Y-4 fix**: same dispatchable-FA rejection.
- `distribute_to_presser(author_pid, presser): u64` — `public(friend)`,
  called from `press::press`. For each registered reward token: payout =
  `balance × BPS_PER_PRESS (25) / 10000`. Pool decays multiplicatively;
  never zero.
- Self-press blocks emission: `presser_pid == author_pid → 0`.

**Reviewer please scrutinize**: gas-cost iteration cap (32 tokens),
slot-squat surface, decay-floor math. See `03-REVIEWER-CHECKLIST.md` Q4.

---

## D-6 — Y-4 dispatchable-FA rejection (defensive)

**Self-audit catch, 2026-05-17.** Discussed in `02-SELF-AUDIT.md` under Y-4.
Both `lp_emission::notify_reward` and `reaction_emission::notify_reward`
now require the FA to have `option::none()` for both
`fungible_asset::deposit_dispatch_function(store)` and
`fungible_asset::withdraw_dispatch_function(store)`. Check is on the
depositor's existing primary store (must exist for the subsequent
withdraw to succeed).

Why this matters: supra-framework ships
`dispatchable_fungible_asset`. A hook-bearing FA can run arbitrary code
on every `primary_fungible_store::withdraw` / `deposit`. Without the
check, an attacker registers a hook FA into a pool, then triggers an
abort condition. `distribute_to_presser` / `withdraw_reward` revert.

For reaction_emission: bricks `press::press` (NFT mint and emission
share a tx — abort reverts both). For lp_emission: bricks
`burn_for_refund` (which calls `claim_lp_rewards_internal` first) —
Position stranded, NFT economic value trapped.

`register_dispatch_functions` requires `ConstructorRef` (creation-time
only). So a plain FA passing the check at notify time is guaranteed
to remain plain forever — no upgrade-to-dispatchable path.

---

## D-7 — Native FA wrapping (`sources/supra_fee_vault.move`)

**New module.** Replaces Aptos `handle_fee_vault`. Routes handle-registration
fees: 10% to deployer beneficiary (`@origin`), 90% to DESNET buyback-burn
via the in-house AMM.

Two-phase commit-reveal settle (carried over from Aptos R6 G3 fix):

- `request_settle(_caller)` — snapshots vault balance + min_out at 5%
  slippage tolerance vs current pool quote.
- 60-second delay.
- `execute_settle(_caller)` — consumes the snapshot. Aborts if pool
  moved adversely > 5% since request.
- `cancel_pending_settle(_caller)` — permissionless cleanup of stale
  requests after grace window.

Native FA: SUPRA via `governance::native_fa_metadata()` = `@0xa` (Supra's
canonical coin-v1-to-FA wrapper).

**Aptos R6 audit covers the two-phase settle design.** The Supra port
swaps `apt_coin` references for `supra_coin` / SUPRA FA metadata
but the control-flow is byte-for-byte identical.

---

## D-8 — Opinion module port (`sources/opinion.move`)

**Carry-over from Aptos v0.4** (not yet audited externally — Aptos v0.4
review pending). Per-PID prediction markets with `creator_token` swap-in,
tax-burn, redeem flow.

Supra-specific changes vs Aptos v0.4:

- `apt_vault` → `supra_vault` (wherever opinion calls vault).
- `aptos_framework` → `supra_framework` namespaces.
- `MIN_INITIAL_MC` lowered from `1e15` (1M whole token) to `1e13`
  (100K whole token) — per-user design override for tighter launch
  capital. Test `test_initial_mc_bounds` updated.
- `mint::create_opinion_mint` atomic entry added at mint module
  (factory pattern extraction). Opinion creation now goes through
  the same mint-seq allocation as standard mints.

**Reviewer please scrutinize**: tax-base correctness (D-M1 rc2 fix —
tax computed on $token-equivalent of swap-in, not raw YAY/NAY).
Conservation invariant (`vault == total_yay_supply == total_nay_supply`)
holds across all swap/redeem paths.

---

## D-9 — Assets Tier-2 + Tier-3 port (`sources/assets.move`)

**Carry-over from Aptos v0.4.** Multi-MIME, large-asset chunked upload
(Tier-2 script-callable, Tier-3 deterministic-addr master pattern). No
Supra-specific changes other than namespace substitution. Logic identical
to Aptos v0.4.

---

## D-10 — IPO Position auto-stake (no separate stake NFT)

In Aptos v0.3 mode, LP holders had a separate `lp_staking::Position` NFT
that earned emission. In Supra mode, the `ipo::Position` IS the stake
NFT — it earns reward gauge yield directly via `reward_debts`. No
separate stake/unstake operation needed.

Implication: legacy `lp_staking::Position` lifecycle still exists in code
(for the swap-fee-only path that the v0.3 audit covered), but new Supra
IPO participants use `ipo::Position` exclusively. Both paths can coexist
on the same pool (different position types).

---

## D-11 — `complete_ipo` permissionless target guard

```move
public entry fun complete_ipo(_caller: &signer, handle: vector<u8>) acquires IPOPool {
    let ipo_addr = ipo_address_of_handle(handle);
    let ipo = borrow_global_mut<IPOPool>(ipo_addr);
    assert!(!ipo.completed, E_ALREADY_COMPLETED);
    assert!(ipo.total_supra_raised >= ipo.target_tvl, E_BELOW_TARGET);  // <- self-audit fix
    // ... flip completed + enable_swaps + wire supra_vault pool_addr
}
```

Pre-fix used `assert!(total_supra_raised > 0)` which let any depositor
permissionlessly complete the IPO after the first deposit, voiding the
"100% refund pre-target" promise. Fixed in `a72ac9e`.

---

## D-12 — Bootstrap dep (`/home/rera/desnet-bootstrap-supra/sources/publisher.move`)

External to this repo. Chunked-publish helper for the resource-account
deploy ceremony. Multisig at `@origin` stages chunks and finalizes
publish to `@desnet`. Same pattern as Aptos R6's `desnet-bootstrap`.

Compiles with the main package via local-dep entry in Move.toml.
Hardcoded placeholder addresses (`origin=0xA0E1`, `desnet=0xDADE`)
for dev; production deploy overrides via `--named-addresses`.

---

## Out-of-scope (preserved verbatim from Aptos v0.3.3)

- `amm.move` — V3 LP shares + swap fees + flash borrow.
- `lp_staking.move` — free / time-locked / forever Position kinds.
- `governance.move` — multisig + DAO modes + voter_history.
- `voter_history.move` — F7 per-token voting power.
- `supra_vault.move` — port of `apt_vault`, same two-phase settle.
- `mint.move` — base verb, plus opinion-mint atomic entry.
- `pulse.move` — spark/echo/remix.
- `link.move` — sync/unsync.
- `press.move` — except for the reaction_emission call which now passes
  `author_pid` (not handle).
- `giveaway.move` — 3-gates pattern.
- `history.move` — append + chunk rotation.
- `factory.move` — except for `create_token_atomic` signature gaining
  `creator_wallet: address` param.

For any of those, R6 findings apply unchanged.
