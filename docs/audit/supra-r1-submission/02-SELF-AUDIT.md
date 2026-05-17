# 02-SELF-AUDIT — Findings + status

Self-audit pass 2026-05-17. Five findings, two HIGH/MED fixed, three
LOW accepted.

---

## Y-1 [MED → FIXED `e357fdd`] Allocation cap drift via NFT transfer + refund

### Surface
`ipo::burn_for_refund` decrements `ipo.depositor_totals[pos.depositor]`
by `pos.supra_deposited` on refund. Subdomain Profile NFTs are freely
transferable (`primary_fungible_store`-style ungated transfer). The
combination created a wash-trade cycle:

1. Alice deposits to 10% cap (`depositor_totals[Alice] = 10%`).
2. Alice transfers subdomain NFT to Bob (proxy or sale).
3. Bob (now `object::owner`) calls `burn_for_refund` →
   `depositor_totals[Alice]` decremented to 0.
4. Alice can deposit another 10%. Repeat indefinitely.

### Impact
Not a whaling exploit per se — Alice never holds >10% locked at any
instant. But the cycle allows **wash deposit/refund** for:
- Faked TVL ramp (front-loading the IPO total_supra_raised to attract
  real depositors).
- MEV setup: pre-positioning AMM state via repeated proportional
  deposits/withdraws.
- Sybil-style market manipulation at near-zero net cost (only AMM
  slippage on the round-trip).

Severity MED: doesn't break the cap invariant but enables a strategy
the cap was supposed to prevent.

### Fix
Conditional decrement — only when caller is the **original depositor**:

```move
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

Honest self-refund (caller==depositor==current_owner) frees the cap.
NFT-transferred-then-refund leaves Alice's cap consumed — she paid
the economic price of transferring during the launch window.

### Reviewer scrutiny
See `03-REVIEWER-CHECKLIST.md` Q1. Specifically: are there scenarios
where the original depositor legitimately wants to refund a Position
they no longer own? Are there edge cases where the cap stays consumed
forever due to a lost-key NFT transfer?

---

## Y-2 [MED → FIXED `e357fdd`] Zero-slippage on burn_for_refund

### Surface
Pre-fix:
```move
amm::remove_liquidity_internal(handle, lp_amount, 0, 0);
```

The refunder accepted whatever the pool gave at the current moment.
Under Supra's parallel-execution model, a concurrent `participate_ipo`
in the same block could dilute the pool reserves between when the
refunder signed and when their tx executed. Result: refunder gets less
SUPRA back than expected (and more token going back to IPO reserve
than expected).

### Impact
Not catastrophic (refund still happens) but allows MEV-style dilution
attacks where a large incoming deposit pushes the refunder out at a
worse exchange. Severity MED.

### Fix
Caller-supplied slippage bounds:
```move
public entry fun burn_for_refund(
    caller: &signer,
    handle: vector<u8>,
    position_addr: address,
    min_supra_out: u64,
    min_token_out: u64,
) acquires IPOPool, Position, SubdomainRegistry { ... }
```

Caller passes `(0, 0)` for legacy no-slippage behavior. Practical
callers should pass min values derived from a pre-tx pool quote.

### Reviewer scrutiny
`min_token_out` is exposed but the token goes back to the IPO reserve
(not the caller). Is this a meaningful param for the caller? Argument
for keeping it: lets the caller refuse a refund if reserves drifted
"too far," which could correlate with adversarial state. Argument for
dropping: caller has no economic stake in the token-side amount.

---

## Y-3 [LOW → ACCEPTED, doc-only] Subdomain front-running griefing

### Surface
`participate_ipo` reserves subdomain names first-come-first-served.
Anyone can deposit min-allowable SUPRA at a desired name (e.g.
"official", "team", "support") to block legit projects from using
that subdomain.

If the griefer refunds:
- The subdomain registry entry is released.
- BUT the Profile NFT for that subdomain remains orphan.
- `create_subdomain_profile` aborts `E_PID_ALREADY_EXISTS` if anyone
  tries to re-register the same name.
- So the name is permanently dead for the remainder of the IPO.

If the griefer holds (doesn't refund):
- They own the subdomain through IPO completion.
- After completion, the LP locks in. Griefer can hold or sell on
  secondary market.

### Cost to griefer
- Hold path: `(1% of target_tvl)` SUPRA locked permanently.
- Refund path: 1% deposit minus AMM slippage on round-trip ≈ small fee.

### Impact
Mostly a UX nuisance. Acceptable per design (matches DNS-style "first
come gets the name"). Recommended mitigation is frontend-side:

1. Encourage creators to use `register_handle_with_creator_seed` at
   IPO genesis to lock desired subdomains atomically.
2. Surface a warning in the UI: "subdomain names are first-come; reserve
   anything brand-critical immediately."

### Reviewer scrutiny
Q5 — would any kind of timelock or reservation mechanism help here, or
is the design's first-come-first-served intentional?

---

## Y-4 [HIGH → FIXED `3a30ba2`] Dispatchable FA brick via notify_reward

### Surface
Both `reaction_emission::notify_reward` and `lp_emission::notify_reward`
are permissionless entries that accept any `Object<Metadata>` (FA).
supra-framework includes `dispatchable_fungible_asset` which lets an
FA register custom withdraw/deposit hooks that run arbitrary Move code
on every transfer.

### Attack
1. Attacker creates a dispatchable FA. Withdraw hook reads a flag from
   the attacker's module and aborts if set.
2. Attacker calls `notify_reward(attacker, victim_handle_or_pid,
   malicious_fa, 1)` — small amount. The notify path:
   - `primary_fungible_store::withdraw(attacker, malicious_fa, 1)` —
     hook runs in attacker's store, returns OK (flag clear).
   - `primary_fungible_store::deposit(pool_addr, fa)` — auto-creates
     the pool's primary store, hook runs again, returns OK.
   - Token registered in pool's `reward_tokens` smart table.
3. Attacker flips the flag in their module.
4. Subsequent `distribute_to_presser` or `withdraw_reward` reaches the
   per-token block, calls `primary_fungible_store::withdraw(&pool_signer,
   malicious_fa, payout)`, hook aborts.
5. **For reaction_emission**: entire `press::press` tx reverts (NFT
   mint and emission distribution share a tx). The author can never
   receive new press mints — economic primitive bricked for them.
6. **For lp_emission**: `claim_lp_rewards` aborts. Worse,
   `ipo::burn_for_refund` calls `claim_lp_rewards_internal` BEFORE
   destroying Position — so the refund path also aborts. Position
   permanently stranded; NFT economic value trapped.

### Severity rationale
- Permanent denial of a core primitive (press, refund).
- Cost to attacker: gas to create the dispatchable FA + 1 unit of FA
  to deposit. ≈ free.
- Affects: any author whose reaction gauge has been notified (open
  set), any IPO participant whose lp_emission gauge has been notified
  (open set).

HIGH.

### Fix
Pre-validate the FA at notify time. Both modules now check:
```move
let depositor_addr = signer::address_of(depositor);
let depositor_store = primary_fungible_store::ensure_primary_store_exists(
    depositor_addr, reward_token_meta,
);
assert!(
    std::option::is_none(&fungible_asset::deposit_dispatch_function(depositor_store))
        && std::option::is_none(&fungible_asset::withdraw_dispatch_function(depositor_store)),
    E_DISPATCHABLE_FA_REJECTED,
);
```

`fungible_asset::deposit_dispatch_function(store)` reads
`DispatchFunctionStore` at the FA metadata address. Returns `Option<FunctionInfo>`
which is `Some` iff a hook was registered at FA creation.

`register_dispatch_functions` requires `ConstructorRef` (creation-time
only). A plain FA passing the check at notify time is guaranteed to
remain plain forever — there is no upgrade path from non-dispatchable
to dispatchable.

### Reviewer scrutiny
Q6 — is the check comprehensive? Edge case: FA with `DispatchFunctionStore`
resource but both hooks set to `option::none()`. Reading source
(`dispatchable_fungible_asset::withdraw`): if `func_opt = option::none()`,
falls through to `fungible_asset::withdraw` (no hook execution). So
the check correctly accepts hook-less-but-dispatchable-registered FAs.

### Test coverage
Positive path covered by 5/5 reaction tests in `tests/supra_port_v04.move`.
Negative path (notify a dispatchable FA → abort) is TODO — requires
setting up `function_info::new_function_info` scaffold. Property is
structural (check is a direct read of framework state) so test gap is
low-risk.

---

## Y-5 [LOW → ACCEPTED] Reward-token slot squat via dust

### Surface
Both `reaction_emission` and `lp_emission` cap registered reward tokens
at `MAX_REWARD_TOKENS = 32`. A spammer can fill 32 slots with dust FAs
(post-Y-4 fix: 32 non-dispatchable dust FAs), locking out legit funders.

### Cost
32 transactions of 1-unit notify each. ≈ trivial.

### Impact
- Slot list saturated.
- Legit subsequent funder gets `E_TOO_MANY_REWARD_TOKENS`.
- Existing claims still work; new tokens cannot be added.

### Why accepted
- For most pools, the first reasonable funders take the slots organically.
- An admin remove-slot operation would add governance attack surface.
- The 32-slot cap is per-pool, not global — griefer must pay 32× the
  per-pool spam cost per victim pool.
- Acceptable design trade-off.

### Reviewer scrutiny
Q7 — is 32 the right cap? Should it be lower (16) to reduce per-press
gas, or higher (64) to make dust-squatting less effective? Trade-off
analysis welcomed.

---

## Other surfaces self-reviewed [no finding]

- **Borrow ordering in burn_for_refund**: `pos = borrow_global<Position>`
  active through field reads; `move_from<Position>` at function end
  after all uses. Move's NLL releases the borrow before move_from.
  Compiler verifies.

- **claim_lp_rewards_internal pre-burn**: called before destroying
  Position. Rewards flow to current NFT owner (`caller_addr`). Original
  depositor has no claim on post-transfer rewards — that's the
  locked-LP-on-subdomain design intent.

- **Permissionless complete_ipo**: now target-gated (`a72ac9e`).
  Pre-fix would have allowed griefing after first deposit; post-fix
  the IPO completes only at or above target_tvl.

- **`register_handle_with_creator_seed` atomicity**: 3 sequential calls
  in 1 tx. All-or-nothing per Move semantics. `factory::create_token_atomic`
  is friend-only on `registration` — no third party can race the handle.

- **Subdomain seed collision**: subdomain seed is `SEED_SUBPID ||
  bcs::to_bytes(&handle) || bcs::to_bytes(&subdomain)`. BCS string
  encoding includes length prefix, so `("alice", "bob")` cannot
  collide with `("alic", "ebob")`.

- **lp_emission ACC_SCALE**: lowered from 1e18 → 1e12. At extreme
  bounds (shares ≈ 1e15 raw, cumulative acc ≈ 1e23), the
  `shares × acc_per_share` product approaches 1e38 < u128_max (3.4e38).
  Sub-unit notifies on small pools may quantize to 0; permissionless
  top-ups of small amounts should batch. Rationale comment inline in
  `lp_emission.move`.

- **Per-PID reaction seed collision**: pool seed is
  `SEED_REACTION_REWARDS || bcs::to_bytes(&author_pid)`. Address bytes
  are 32 bytes fixed-length; distinct addresses → distinct seeds → distinct
  pool addresses. Property covered by
  `test_per_pid_reaction_pools_are_isolated` in `tests/supra_port_v04.move`.

- **distribute_to_presser friend boundary**: `public(friend)`. Only
  `desnet::press` is in the friend list. `author_pid` reaches it only
  after `assert!(exists<PidPressStorage>(author_pid))` which is set by
  `enable_press` which requires `assert_authorized`. So `author_pid`
  cannot be spoofed.

- **MAX_REWARD_TOKENS bound on distribute_to_presser gas**: 32-token
  cap × per-token block (~50 gas ops). Bounded gas, no DOS via list
  growth.

- **Self-press emission suppression**: `presser_pid == author_pid → 0`.
  NFT mint still happens (author can collect own work) but emission is
  suppressed — author can't drain their own pool via single self-press.

- **Cross-PID drain via per-actor uniqueness**: per-PID registry tracks
  pressed_by, so each PID can press a given mint exactly once. Cross-PID
  drain requires N distinct PIDs, each paying handle_fee. Bounded.
