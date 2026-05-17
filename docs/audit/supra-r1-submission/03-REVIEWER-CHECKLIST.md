# 03-REVIEWER-CHECKLIST — Focused scrutiny questions

Targeted prompts to anchor each reviewer's attention. Not exhaustive
— reviewers are expected to find additional issues. These are the
items where the design space is most contentious or the diff from
Aptos v0.3.3 is largest.

---

## Q1 — Y-1 anti-wash: is the conditional correct?

**File**: `sources/ipo.move::burn_for_refund` around the
`if (caller_addr == pos.depositor)` block.

### Specific scenarios to verify

(a) **Honest self-refund**: Alice deposits to S1, never transfers, calls
burn herself. caller==depositor==current_owner. Cap freed correctly. ✓

(b) **Transfer then own-refund**: Alice deposits to S1, transfers to
Bob, Bob calls burn. caller=Bob, pos.depositor=Alice, current_owner=Bob.
Cap stays consumed for Alice. Refund SUPRA goes to Bob (current owner).
This is the intended behavior (Bob bought the NFT, gets the refund;
Alice paid the economic price of transferring during launch).
Is this fair?

(c) **Alice has multiple positions**: Alice deposits to S1 (5%) and S2
(5%) → depositor_totals[Alice] = 10%. Transfers S1 to Bob. Bob refunds
S1. depositor_totals[Alice] stays at 10%. Alice burns S2 herself.
caller==Alice==depositor. Decrement depositor_totals[Alice] by 5%.
Final: depositor_totals[Alice] = 5%. **Wait — is this right? Alice
has zero positions left but cap shows 5% used.** Original-depositor
"cap-consumed" applies per-position basis. After S2 burn, S2's
contribution is freed. S1's is still locked because S1 was refunded
by non-original-depositor. Is this the desired semantics, or should
S1's contribution also free up when Alice has lost ownership of S1
entirely?

(d) **Lost-key NFT**: Alice deposits to S1, transfers to Bob (or sends
to dead address). NFT now inaccessible. Alice's cap stays consumed
forever. Alice cannot deposit more in this IPO. **Is this acceptable?**

(e) **NFT-to-self transfer cycle**: Alice deposits to S1, transfers to
her own secondary wallet Alice', Alice' refunds. caller=Alice' !=
pos.depositor=Alice. Cap stays consumed. This blocks the wash-trade
exploit. ✓

### Open question
Is there a cleaner invariant we could express? E.g. "depositor_totals
tracks the cumulative wallet-credit-USED across the entire IPO, never
restored unless the same wallet refunds its own un-transferred Position"
— that's what the current code does. Reviewer thoughts welcome.

---

## Q2 — register_handle_with_creator_seed atomicity

**File**: `sources/registration.move`.

### Atomicity claim
Three sequential calls in one tx. If any sub-call aborts, Move tx
semantics revert the whole tx. So either all three succeed or none.

### Specific scenarios
(a) `profile::register_handle` succeeds but `factory::create_token_atomic`
aborts (e.g. invalid name): whole tx reverts. Handle remains unregistered.
✓

(b) `create_token_atomic` succeeds but `ipo::deposit_supra` aborts
(e.g. creator_supra_amount > 10% cap): whole tx reverts. Token uncreated,
handle unregistered.
✓

(c) **Front-running**: A non-creator-seed actor tries to race the same
handle. `factory::create_token_atomic` is `public(friend)` with only
`desnet::registration` in the friend list. Cannot be called from
outside. ✓

(d) **Gas-loss UX**: creator picks `creator_supra_amount > 10% of
target_tvl`. The first two steps execute (gas paid), step 3 aborts,
whole tx reverts (gas refunded except for L1 base?). Should we
pre-validate the cap at registration entry to fail-fast?

### Open question
Should `creator_supra_amount` be capped at the entry level (cheap
abort) rather than at `ipo::deposit_supra` (expensive abort after two
prior successful calls)?

---

## Q3 — Locked-LP-on-subdomain semantics

**File**: `sources/ipo.move::Position`, stored at `subdomain_pid_addr`.

### Specific scenarios
(a) **Reward claim during NFT transfer race**: Alice owns subdomain S,
transfers NFT to Bob in tx T1, Carol calls `claim_lp_rewards(handle,
S)` in tx T2 immediately after. T2 reads `object::owner` = Bob.
Rewards flow to Bob. ✓ Is there any same-block race window where
claim could see a stale owner?

(b) **Burn auth + reward settlement order**: `burn_for_refund` calls
`claim_lp_rewards_internal(handle, position_addr, caller_addr)` BEFORE
destroying Position. caller_addr == current owner (auth-checked).
Rewards flow to current owner. Then Position destroyed. ✓

(c) **Position resource borrow + move_from**: `pos = borrow_global<Position>`
is used through field reads up to the conditional Y-1 block, then
`move_from<Position>` at the bottom. Move's NLL should release the
borrow at the last field read. **Reviewer please verify the borrow
doesn't span the move_from call.** The compiler accepts it; semantic
correctness needs eyes.

(d) **Profile NFT orphan after refund**: `move_from<Position>` destroys
the Position resource but the Profile NFT object survives. Same
subdomain name cannot be re-registered. Is "permanent dead slot" the
right design, or should refund also delete the Profile NFT? Note:
deleting the Profile NFT would require `object::delete_with_transfer_ref`
which needs the TransferRef stored in Profile.

---

## Q4 — Reaction gauge math

**File**: `sources/reaction_emission.move::distribute_to_presser`.

### Per-press payout formula
```
payout = balance × BPS_PER_PRESS / BPS_DENOM
       = balance × 25 / 10000
       = 0.25% of pool balance
```

### Specific properties
(a) **Multiplicative decay floor**: balance × 25 / 10000 quantizes to 0
when balance < 40. So a pool with ≤39 raw units pays nothing per press
(payout=0, no withdraw, no event). Pool effectively dust-locked at that
point.
- Question: should there be a minimum-payout floor (e.g. 1 raw unit
  per token per press) to extract dust pool over time? Counter-arg:
  current behavior is mathematically consistent with the BPS rate.

(b) **Gas cost per press**: O(32) token iterations × ~3 borrow/withdraw
ops each. Roughly bounded by ~100 ops total. Press is a moderately-priced
verb; this scaling is acceptable but worth confirming.

(c) **Cross-PID per-actor uniqueness**: presser_pid uniqueness is
checked at press.move, not reaction_emission. So distribute is called
exactly once per (mint, presser_pid) pair. Author owning 1000 PIDs
could press their own mint 1000 times, claiming 0.25% × 1000 = 22%
of pool. But: self-press is blocked at press.move (presser_pid ==
author_pid → 0). To bypass, attacker needs N distinct PIDs not owned
by the author. Each PID costs handle_fee (1+ SUPRA at minimum 6-char
tier). Bounded.

### Open question
The pool funded by a fan can be drained by N coordinated pressers
(legit or sybil). Is this OK? The "decay floor" is a feature: it
sustains the pool over time, but it also means once funded, the pool
inexorably empties over enough presses.

---

## Q5 — Subdomain front-running mitigation

See Y-3 in `02-SELF-AUDIT.md`. Open design question.

Possible mitigations the reviewer could weigh:
- (a) Status quo: first-come-first-served, frontend warns creators.
- (b) Non-refundable subdomain reservation fee.
- (c) Creator-only reservation window for the first N seconds of IPO.
- (d) Force registration to be permanent (no refund of subdomain slot).
  Refund SUPRA but keep the subdomain assigned to original depositor.
- (e) Allow re-registration of orphan-Profile subdomains
  (`create_subdomain_profile` becomes idempotent).

---

## Q6 — Y-4 dispatchable-FA check completeness

**File**: `sources/reaction_emission.move::notify_reward`,
`sources/lp_emission.move::notify_reward`.

### Check
```move
assert!(
    std::option::is_none(&fungible_asset::deposit_dispatch_function(depositor_store))
        && std::option::is_none(&fungible_asset::withdraw_dispatch_function(depositor_store)),
    E_DISPATCHABLE_FA_REJECTED,
);
```

### Specific scrutiny
(a) Both `deposit` and `withdraw` hooks checked. ✓

(b) `derived_balance_function` (third hook in register_dispatch_functions)
NOT checked. **Is this an oversight?** Reading source: the derived
balance hook is read by `fungible_asset::balance`, but our pools use
`primary_fungible_store::balance` which DOES NOT go through the
dispatchable path (only `dispatchable_fungible_asset::withdraw`/`deposit`
do). So derived_balance can't be used to brick the gauge. **Reviewer
please verify** this reading.

(c) The check is on the depositor's primary store. Does the result
correctly reflect the FA's metadata-level dispatch registration?
`fungible_asset::deposit_dispatch_function(store)` calls
`store_metadata(store)` and reads `DispatchFunctionStore` at that
metadata's address. So the result is metadata-keyed, not store-keyed.
Any store of that FA would yield the same answer. ✓

(d) **Upgrade path**: `register_dispatch_functions` takes
`ConstructorRef`, which is creation-time-only. So a non-dispatchable
FA at notify time CANNOT later be upgraded to dispatchable. The check
is sticky. ✓

### Open question
Should there be a corresponding check elsewhere (e.g. in `amm.move`
swap paths, in `supra_fee_vault.move`)? For AMM: pools are
factory-created with hardcoded host tokens; the host token type is
not user-supplied at swap time, so the same attack doesn't apply. For
supra_fee_vault: only SUPRA (native) is ingested; same reasoning. The
Y-4 fix appears scoped to the two permissionless-multi-FA-intake
modules.

---

## Q7 — MAX_REWARD_TOKENS = 32 cap

See Y-5 in `02-SELF-AUDIT.md`.

Trade-off:
- Lower (e.g. 16): cheaper per-press gas, but easier to dust-squat.
- Higher (e.g. 64): less squat-prone, but `distribute_to_presser` gas
  doubles in worst case.

Is 32 right? Worth considering: how many distinct reward tokens does
a typical author/handle realistically need? In practice: 1-3 (host
$TOKEN + maybe SUPRA + maybe USDC-equivalent). 32 has huge headroom
but also leaves lots of squat space.

---

## Q8 — Borrow ordering across friend calls

**File**: `sources/ipo.move::burn_for_refund` — the section between
`let pos = borrow_global<Position>` and `move_from<Position>`.

The function calls `lp_emission::on_share_decrease(handle, lp_amount)`
between the borrow and the move_from. `on_share_decrease` does NOT
acquire Position, so no borrow conflict.

The function also calls `claim_lp_rewards_internal` BEFORE the
`borrow_global<Position>`. claim_lp_rewards_internal does its own
`borrow_global_mut<Position>(position_addr)` internally (to update
reward_debts). It must release that borrow before returning.
Subsequent `borrow_global<Position>` in burn_for_refund is fresh. ✓

**Reviewer please verify** by reading the actual function body.

---

## Q9 — Permissionless `complete_ipo` target guard

**File**: `sources/ipo.move::complete_ipo`.

```move
public entry fun complete_ipo(_caller: &signer, handle: vector<u8>) acquires IPOPool {
    let ipo = borrow_global_mut<IPOPool>(ipo_addr);
    assert!(!ipo.completed, E_ALREADY_COMPLETED);
    assert!(ipo.total_supra_raised >= ipo.target_tvl, E_BELOW_TARGET);
    // ... flip + enable_swaps + wire vault
}
```

Pre-fix: `assert!(total_supra_raised > 0)`. Post-fix:
`total_supra_raised >= target_tvl`.

### Scenarios
(a) IPO never reaches target: `complete_ipo` can never succeed.
Depositors hold their Positions; refund-during-IPO is the only exit.
**Is this acceptable**, or should there be a "force-complete after T
seconds at any raised amount" escape valve?

(b) IPO over-fills before completion: `total_supra_raised <= target_tvl`
is enforced in `deposit_supra` (E_OVER_TARGET). So over-fill is
impossible by construction. ✓

(c) `complete_ipo` is permissionless — anyone can call. Any harm in
allowing non-stakeholders to flip the bit? No: flip is a pure transition
function once the precondition holds. ✓

---

## Q10 — Subdomain seed collision proof

**File**: `sources/profile.move::derive_subdomain_pid_address`.

```move
let seed = vector::empty<u8>();
vector::append(&mut seed, SEED_SUBPID);
vector::append(&mut seed, bcs::to_bytes(&handle));
vector::append(&mut seed, bcs::to_bytes(&subdomain));
object::create_object_address(&@desnet, seed)
```

BCS `to_bytes` for `String` produces `<varint length><utf8 bytes>`.
So `("alice", "bob")` → `5 "alice" 3 "bob"` (with proper varints).
`("alic", "ebob")` → `4 "alic" 4 "ebob"`. Distinct serializations,
distinct seeds, distinct object addresses. ✓

**Edge case**: `("", "alicebob")` vs `("alicebob", "")` — both empty
on one side. But `validate_subdomain` requires length ≥ 1 so empty
subdomain rejected. `validate_handle` requires length ≥ 3. So
ambiguity ruled out at validation layer.

Reviewer please confirm BCS encoding properties hold.

---

## Q11 — Main vs subdomain handle collision

A user registers main handle "alice". Another user registers a
subdomain "alice@bob" under handle "bob" (subdomain="alice", parent="bob").

Both have a Profile NFT with `Profile.handle = "alice"`:
- Main: stored at `derive_pid_address(wallet_alice)` (seed includes
  SEED_PID + wallet bytes).
- Subdomain: stored at `derive_subdomain_pid_address("bob", "alice")`
  (seed includes SEED_SUBPID + handle + subdomain).

Different PID addresses. Different reaction gauges (per-PID rekey).
Different opinion-mint counters (per-PID PidOpinionMeta).

But `profile::handle_of(pid)` returns "alice" for both. Frontend
displays "alice" for main and "alice@bob" for subdomain.

**Is there any other surface keyed by `handle_of()` that could
collide?**
- AMM pool keyed by handle (the host token handle, not PID handle).
  Main handle "alice" has an AMM pool; subdomain "alice@bob"
  does NOT. AMM uses the parent handle's pool.
- lp_emission keyed by handle (same as AMM).
- supra_fee_vault keyed by `@desnet` singleton.
- reaction_emission keyed by author_pid (post-Y-rekey).

**Reviewer please confirm** all other handle-keyed surfaces are
correctly scoped to the host-token handle (parent), not to the bare
subdomain string. The risk would be if a verb routed `handle_of()`
into a host-pool surface that should have been parent-handle-scoped.

---

## Q12 — Aptos R6 carry-over checklist

The following Aptos R6 fixes should be preserved in the Supra port:

- ✓ F7 G1: per-user voter_history fallback (`voter_history.move`,
  `governance.move::voting_power`).
- ✓ F8 G2: DaoUpgradeStaging separate from multisig staging
  (`governance.move`).
- ✓ F9 G3: two-phase commit-reveal settle on supra_fee_vault
  (preserved from handle_fee_vault).
- ✓ S1: G3 swap_amount + min_out paired from same snapshot.
- ✓ G4: drop manual field read in `effective_30d_emission`.
- ✓ G5: `multisig_publish_chunked_upgrade_with_digest` companion
  added.
- ✓ G6: `vault_addr` + `vault_exists` have `#[view]`.
- ✓ Q-M1: distinct error code `E_VAULT_SHRUNK_BELOW_SNAPSHOT` from
  E_BELOW_THRESHOLD.

Reviewer please spot-check `governance.move`, `voter_history.move`,
`supra_fee_vault.move` against the R6 acceptance state.

---

## Verdict format

Please conclude your review with:

```
VERDICT: GREEN | YELLOW | RED

GREEN — no HIGH, no unfixed MED, design sound.
YELLOW — MED/LOW findings; design acceptable with caveats noted.
RED — HIGH unfixed or design flaw.

Findings:
- [HIGH|MED|LOW|INFO] [CONV-suspected] Title. Module. Description. Suggested fix.
- ...

Carry-over from Aptos R6: preserved correctly | drift detected at <module>.
Net Supra-specific finding count: N HIGH / M MED / K LOW.
```
