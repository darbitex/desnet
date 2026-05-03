# DeSNet Opinion Pool — AMM Design Lock

**Date:** 2026-05-03 (rev 4)
**Status:** Design FULLY locked (curve + collateral + tax + symmetric pool seed at create); implementation pending refactor of v1 scaffold
**Author:** Locked-in via design conversation
**Supersedes:** rev2 (3-option creator_position) and rev3 (literal burn at create — math broken). v1 scaffold (commit `63f9d88`) used APT collateral and is being superseded — see §10
**Revision history:**
- rev1 (commit `8411947`): Mirror-Mint Bootstrap, APT collateral, no creator pre-position
- rev2 (commit `d900e47`): creator-token collateral, 3-option creator_position (NONE/Y/N/BOTH default BOTH)
- rev3 (discarded): literal burn at create — broken (no pool seed compensation path for redemption symmetry)
- rev4 (this commit): symmetric pool seed at create (creator pays initial_mc, mints both sides to pool, gets 0 position, vault locks initial_mc forever)

## 0. Premise

DeSNet's "prediction-market substrate" is **NOT** a Polymarket/Azuro-style market with oracle resolution. It is an **opinion pool**: each claim/post becomes a tokenized opinion that trades on an AMM forever. Price = aggregate belief at any moment. Exit by selling, not by waiting for resolution.

### Out of scope by design
- Oracle integration (Switchboard/Pyth/UMA/AI-settlement)
- Two-phase commit-reveal settle for outcomes (the `handle_fee_vault::request_settle/execute_settle` mechanic in v0.3.3 is for handle-fee buyback-burn, NOT for opinion resolution — keep separate)
- $1/$0 redemption against ground truth
- Expiry timestamps, dispute windows, resolution committees
- Time-decay curve components (Paradigm pm-AMM σ²(T-t) is irrelevant since T=∞)

### Closest prior art
**Conceptual:** Bodhi (Arweave content bonding curves, lifetime trade, no resolution).
**Mechanical:** Pump.fun, Friend.tech, Zora 1155 (content-as-asset).
**Rejected:** Polymarket (off-chain CLOB, oracle settle), Augur (LMSR + oracle), Azuro (sportsbook pool + oracle), Manifold (creator resolution), Paradigm pm-AMM (Gaussian + time decay).

---

## 1. Curve Lock: "x*y=k with symmetric pool seed at create"

**Two rules** (one for create, one for subsequent trader deposits):

**Rule A — Create (creator-only, once per opinion):**
> Creator pays `initial_mc` $creator_token → vault. Mint `initial_mc` Y + `initial_mc` N → BOTH go to pool. Creator receives 0 position. `initial_mc` is locked permanently in vault (no creator-redemption path).

**Rule B — Subsequent deposits (any trader, including creator post-create):**
> Deposit `c` $creator_token → atomically mint `c` Y + `c` N. User keeps `c` of chosen side. The other `c` auto-deposits into the pool. ("Mirror-Mint Bootstrap" semantics — but pool is already active from create, so this is just standard pair-mint-and-pick-side trading.)

**Collateral lock**: vault denominated in **creator's $token** (looked up via `factory::token_metadata_of_owner(author_pid)` at create time, immutable thereafter). NOT APT, NOT DESNET. See §4 for economic-loop justification.

**Pool active from block 0** (k = initial_mc² > 0 always). No phase-1 lockup risk.

The pool maintains pure constant product `Y_reserve × N_reserve = k` (UniV2-style). It bootstraps itself from `(0,0)` without creator seed.

### 1.1 Phase transitions (automatic, no admin)

| State | Condition | Trading? |
|---|---|---|
| `(0, 0)` | empty pool | No (no PID activity yet) |
| `(c, 0)` or `(0, c)` | one-sided after first deposit | **No** — k undefined, trading locked |
| `(>0, >0)` | first opposite-side deposit lands | **Yes** — k = product, CPMM live |

### 1.2 Worked example

Initial: `vault = 0`, `pool = (Y=0, N=0)`

```
[1] Alice deposits 100 APT, picks Y
    → mint 100 Y + 100 N (complete set)
    → Alice keeps 100 Y
    → pool gets 100 N
    State: vault=100, pool=(Y=0, N=100), INACTIVE

[2] Bob deposits 10 APT, picks N    ← phase transition
    → mint 10 Y + 10 N
    → Bob keeps 10 N
    → pool gets 10 Y
    State: vault=110, pool=(Y=10, N=100), k=1000, ACTIVE

[3] Marginal price after [2]:
    dN/dY at (10, 100) = N/Y = 10
    → 1 marginal Y costs ~10 marginal N
    → APT-equivalent (since 1Y + 1N = 1 APT redemption):
        Y_price = 10/(10+1) = 0.909 APT
        N_price = 1/(10+1) = 0.091 APT
        sum = 1.000 APT ✓

[4] Carol deposits 1 APT, picks Y
    → mint 1 Y + 1 N → Carol keeps 1 Y, pool gets 1 N
    State: vault=111, pool=(Y=10, N=101), k=1010
    (Optional) Carol can also synth-buy more Y: keep her N from mint
        and swap it on pool: send 1 N → get y_out where (10−y)(101+1)=1010
        → y_out = 10 − 1010/102 = 0.098 Y, total 1.098 Y for 1 APT.

[5] David exit (holds 5 Y, wants APT)
    Path A — pure swap+redeem:
        Swap some Y to N until balanced (need 5Y+5N for redemption)
        Burn 5Y + 5N via redeem_complete_set → get 5 APT back
    Path B — sell to pool only:
        Swap 5 Y → N. New pool balance updates per CPMM. Holds N now.
        Future: someone redeems on his behalf or he holds N as anti-belief.
```

### 1.3 Conservation invariant

```
vault_APT = (Y_total_supply + N_total_supply) / 2
```

Proof sketch: every APT deposited mints exactly 1 Y + 1 N (sum 2 tokens). `redeem_complete_set` burns exactly 1 Y + 1 N per APT returned. Y_total_supply and N_total_supply both include pool reserves. Invariant holds across all paths.

**Solvency guarantee:** as long as the only mint/burn paths are deposit (mint pair) and redeem_complete_set (burn pair), vault is always sufficient to cover all redemptions if every holder converts back to balanced pairs.

### 1.4 Why this is "x*y=k" not bonding curve

| Aspect | Bonding curve | Mirror-Mint Bootstrap |
|---|---|---|
| Price function | P = f(supply) | P = f(reserve_ratio) |
| Counterparty | Not needed (mint vs burn against curve) | Needed (CPMM swap) |
| Phase 1 (one-sided) | First buyer rides curve immediately | First depositor accumulates only; trading locked |
| Math | Polynomial / exponential / sigmoid | Pure UniV2 `x*y=k` |
| Supply growth | Curve-driven (mint when buy) | Only on APT deposit (mint pair) |
| Inflation control | Curve dictates | Pair-mint conservation |

Pure CPMM constraint preserved.

---

## 2. Properties

1. **Zero creator seed** — pool bootstraps from first two opposite-side traders.
2. **First opposite-side trader sets initial price** — implicit, via the reserve ratio they create.
3. **Skewed reserves = consensus signal** — heavily one-sided pool means the contrarian gets cheap units, self-correcting toward 50:50 if they're right.
4. **Always solvent** — invariant `vault = (Y+N)/2` enforced by atomic mint rule.
5. **k grows monotonically** with mint deposits (this is desired: deeper pool from activity, more depth = less slippage). Differs from UniV2 standard where LP-add scales `k` proportionally without changing per-share value; here every deposit adds to BOTH reserves equally so swap fees still distribute fairly to LPs by share.
6. **Composable with DeSNet primitives** — `press` on opinion-PID could synth-trigger `deposit_pick_side`, etc.

---

## 3. Drawbacks (acknowledged, accepted)

1. **Phase 1 lockup** — single-side holders can't exit until first contrarian arrives. Treated as "skin in the game" feature; alternatives (admin unlock, time-based fallback) rejected for purity.
2. **Capital efficiency 50%** — 1 APT bullish on Y yields 1 Y exposure with 1 N tied up in pool. Same as Polymarket; not worse than standard prediction-market AMMs.
3. **Total consensus = pool dies** — if everyone agrees, no phase 2, no trading. Acceptable: "no dissent → no market" is a clean signal.
4. **k is not a fixed UniV2 invariant** — grows with mint deposits, which differs from standard LP-add semantics. Implementers must be careful with LP share accounting.

---

## 4. Locked decisions (do not revisit without sign-off)

| # | Knob | Decision |
|---|---|---|
| 1 | Token count | **2-token YES/NO pair** (required by Mirror-Mint design) |
| 2 | Curve type | **Pure x*y=k with Mirror-Mint Bootstrap** |
| 3 | Initial liquidity source | **Symmetric pool seed at create** (creator pays initial_mc, mints initial_mc Y + initial_mc N, both → pool, vault locks initial_mc forever) |
| 4 | **Vault collateral** | **Creator's $token** via `factory::token_metadata_of_owner(author_pid)` — NOT APT, NOT DESNET |
| 5 | **Tax token** | **Same $creator_token, BURNED** via `apt_vault::burn_via_vault(factory::vault_addr_of_pid(author_pid), fa)` |
| 6 | **Tax behavior** | **On top** of deposit (user pays c + tax, gets c Y or c N) — NOT skimmed |
| 7 | **Creator position at create** | **Symmetric only** — creator pays `initial_mc` $token, mints `initial_mc` Y + `initial_mc` N, both go to pool, creator gets 0 position. Vault locks initial_mc forever (alias di-burn dari POV creator). Pool active day 1. **`initial_mc` bounds: [1M, 100M] WHOLE $token** (= 0.1%-10% of 1B factory supply). |
| 7b | **Creator post-create rights** | Allowed: deposit_pick_side / swap / redeem (sebagai trader normal, pay tax + collateral). NOT allowed: creator-only privileged add_liquidity_symmetric (creator's only liquidity contribution is at create). "Berhak beropini" — creator boleh ekspresi opini lewat trade, tapi gak bisa inject more liquidity. |
| 8 | **tax_bps scope** | **Per-opinion**, creator-set at create, immutable post-create. Default **10 bps (0.1%)**, max 1000 bps (10%) |
| 9 | **Swap tax** | **Proportional** to `amount_in` converted to $token via factory AMM quote, with flat floor (anti-dust) |
| 10 | Guest restriction | **Only registered handles can create opinions** (required because vault denomination needs $token to exist) |
| 11 | DESNET coupling | **Decoupled** — opinion module independent from DESNET (DESNET keeps utility via handle fees + governance + AMM) |

### 4.7 Symmetric pool seed at create (locked rev4)

**Single mechanic, no options:**

```
create_opinion(author, content_text, initial_mc, tax_bps):
  validate initial_mc ∈ [1M, 100M] WHOLE $creator_token
                       (raw range: [10^14, 10^16] at 8 decimals)
                       (= 0.1% to 10% of 1B factory total supply)
  validate tax_bps ≤ 1000 (10% cap), default 10 bps (0.1%)

  Pull initial_mc $creator_token from author wallet → vault store
  Mint initial_mc Y → pool_y store
  Mint initial_mc N → pool_n store
  Creator wallet: 0 Y, 0 N

  Final state:
    Vault: initial_mc $creator_token (LOCKED forever for creator)
    Pool: (initial_mc, initial_mc), k = initial_mc² > 0 — TRADABLE day 1
    total_y_supply = total_n_supply = initial_mc
    Conservation: vault == total_y == total_n ✓
    $creator_token total_supply: UNCHANGED (no literal burn)
    Circulating ↓ by initial_mc (stranded in vault — only retrievable by traders who burn balanced pairs they earned)
```

**Cost to creator: 1× initial_mc** (NOT 2× — early hybrid drafts of literal-burn-plus-pool-seed had broken math because the burn portion had no Y/N to back it for redemption).

**"Locked = burned from POV creator"**: vault floor = initial_mc forever. Reason: every redeem requires user to burn equal Y+N from their own primary store. Pool reserves can't be self-redeemed (no wallet owns them — they're in pool stores). So pool reserves stay locked, and the initial_mc collateral backing them stays in vault forever. Creator has 0 Y, 0 N, no path to redeem.

**Anti-spam**: spam 1000 opinions × initial_mc = 1000 × initial_mc $token stranded forever. Self-defeating economic burn. Self-governed QC.

### 4.8 Closed economic loop (justification for §4 locks)

```
factory v1.2 spawns 1B $creator_token at handle register
  → 50M to AMM pool seed (immediate liquidity)
  → 50M to reaction_emission reserve
  → 900M to lp_emission reserve (slow drip to creator's locked Position)

Creator earns $creator_token passively via:
  - lp_emission drip (locked Position at PID NFT)
  - LP fees from factory AMM swaps
  - press emission via factory::emit_press_to_presser

Creator USES accumulated $creator_token to:
  - Open opinion markets (initial_mc cost, locked in vault forever — uses own stash, NO market dump)

Engagers acquire $creator_token via factory AMM:
  - Demand pressure on $creator_token price
  - LP fees back to creator's locked Position
  - Engagement burns $creator_token (deflationary)

Result: emission flow has functional sink. Creator does NOT need to dump
$creator_token to bootstrap their own opinion markets. Reputation
self-regulates via $creator_token price.
```

If collateral were DESNET or APT instead, creator would need to swap $creator_token → DESNET/APT to bootstrap their own opinions, creating perverse SELL pressure on their own token. With $creator_token collateral, the loop is closed and self-reinforcing.

### 4.9 Volatility = reputation signal (not bug)

| Scenario | Effect |
|---|---|
| $creator_token pump | Engagement expensive → high-conviction filter → high signal-to-noise |
| $creator_token dump | Engagement cheap → spam permitted but low value → market self-segregates |
| Pump-and-dump attempt | Pump kills opinion engagement → utility lost → token dumps back → self-punishing |
| Bot spam | Bot must hold/burn $creator_token → spam pumps creator → spam becomes expensive |

Pasar self-segregates. Tidak butuh moderator manusia.

---

## 5. Open knobs (still UNLOCKED — sign-off required before code)

| # | Knob | Notes |
|---|---|---|
| A | "Graduation" mechanic | Mirror-Mint already always-on-main-AMM from day-1 (no separate launchpad → main-DEX phase). Likely N/A. Confirm. |
| B | Press / echo / emission interplay | Should `press` trigger auto-deposit? At what amount? Likely keep separate (press = reaction, vote = explicit deposit). Defer pending UX testing. |
| C | Multi-outcome (>2 sides) | Mirror-Mint extends naturally: `c` $creator_token mints `c` of each of N tokens, user keeps c of chosen, rest (n−1) sides auto-deposit. Pool invariant becomes `prod(reserves) = k`. **Defer to v2 as sibling module `desnet::opinion_multi`** (do NOT refactor v1). |

---

## 6. Existing DeSNet primitives reused (~90% leverage)

- `desnet-protocol::mint` → create the PID/claim
- `desnet-factory::create_token` (v1.2 live `0x665f1227`) → tokenize Y and N as factory tokens with deterministic addresses derived from PID
- DeSNet AMM (DESNET/APT pool live `0x5ba92cb1...`) → either reuse curve OR fork for pair-mint semantics (TBD in implementation)
- `lp_emission` staking → conviction-stake = LP-stake the opinion pool
- `press::press_pid` → endorse opinion (already emission-bonus wired via factory v1.2 `emit_press_to_presser`)
- `reaction_emission` → already wired for press flow
- `reference_gate::check` → can compose "must hold N opinion-tokens to interact"

## 7. Net new code (estimated small)

- New module `desnet_opinion::market` implementing Mirror-Mint Bootstrap deposit/swap/redeem
- Y and N as factory tokens at opinion-PID creation (deterministic addresses)
- Atomic helper: `deposit_pick_side(c: u64, side: u8)` — single tx for mint+keep+pool-deposit
- `redeem_complete_set(amount: u64)` — exit path
- Activation guard: trading entries abort if `pool.Y == 0 || pool.N == 0`

## 8. Comparison vs alternatives ruled out

| Pattern | Why rejected |
|---|---|
| Gnosis CTF + UniV2 standard | Needs creator pre-seed (`(k,k)` upfront capital) |
| Pump.fun virtual reserves | Bonding-curve-disguised (user explicitly rejected bonding) |
| Paradigm pm-AMM | Gaussian curve, not x*y=k; has time-decay (rejected on no-settle grounds) |
| Single-token bonding (Bodhi-style) | User prefers x*y=k structure; also no native shorting |

## 10. v1 → v2 refactor (after this rev's lock-in)

The v1 scaffold (commit `63f9d88`) used **APT as collateral** and had `fee_bps` as a hardcoded 0 hook. This was placeholder before the §4 locks landed. Refactor checklist:

- [ ] Replace `APT_FA_ADDR` constant usage with dynamic `factory::token_metadata_of_owner(author_pid)` lookup at create_opinion
- [ ] Add `creator_token: address` field to OpinionMarket struct (cached at create for fast access)
- [ ] Add `tax_bps: u64` arg to `create_opinion` (validate ≤ 1000, default 10)
- [ ] Add `initial_mc: u64` arg (validate ∈ [1M, 100M] whole token = [10^14, 10^16] raw)
- [ ] DROP `creator_position`, `initial_pick_side`, `initial_pick_apt` args (rev2 leftovers)
- [ ] Symmetric pool seed: pull initial_mc $token → vault, mint initial_mc Y + initial_mc N → both to pool, creator gets 0
- [ ] Creator post-create participation: NO hard-ban (creator boleh trade as normal user; pays tax + collateral like anyone)
- [ ] DROP creator-only `add_liquidity_symmetric_creator` (not in v1)
- [ ] Add tax burn flow: pull extra $creator_token from user, call `apt_vault::burn_via_vault(factory::vault_addr_of_pid(author_pid), fa)`
- [ ] Swap tax: convert `amount_in` to $creator_token equivalent via `amm::compute_amount_out` quote, apply `swap_tax_bps`, with flat floor (e.g. 1000 raw units)
- [ ] Add `friend desnet::opinion;` to `apt_vault.move`
- [ ] Update conservation invariant assertion: `vault_$creator_token == total_y_supply == total_n_supply`
- [ ] Tests: setup factory token in test env (or unit-test helpers in isolation, defer integration tests)
- [ ] Update views: `vault_balance` returns $creator_token amount (not APT)

Estimated +250 LOC net.

---

## 9. Cross-references

- Memory: `desnet_opinion_pool.md` (full design summary)
- Earlier survey: Polymarket (CLOB hybrid, off-chain matcher), Aptos (Morpheus pm-AMM, Panana hybrid AMM+parimutuel, Fliq), Sui (PredictPlay AMM, Skepsis, SuiBets), Supra (none native — only X Predict Market via SupraOracles)
- All surveyed projects assume settlement; **Mirror-Mint Bootstrap is genuinely novel** as a no-settle perpetual opinion AMM with auto-bootstrap

---

## Appendix A: Quick reference math

For pool state `(Y_r, N_r)` with `k = Y_r × N_r`:

**Spot price (in APT, since Y+N redeem to 1 APT):**
```
Y_price_APT = N_r / (Y_r + N_r)
N_price_APT = Y_r / (Y_r + N_r)
```

**Swap: send `dn` of N to pool, receive `dy` of Y:**
```
(Y_r − dy) × (N_r + dn) = k
dy = Y_r − k/(N_r + dn)
   = Y_r × dn / (N_r + dn)
```

**Deposit `c` APT picking Y (no fee):**
```
mint c Y, c N
user receives: c Y
pool: (Y_r, N_r) → (Y_r, N_r + c)    if pool was already active
                  → (0, c)            if first ever deposit
```

**Redeem complete set `m` (burn m Y + m N, receive m APT):**
```
require holder has ≥ m of each
burn m Y, m N
vault → vault − m
return m APT to holder
```

Conservation: `vault_APT = (Y_total_supply + N_total_supply) / 2` is invariant across all four operations.
