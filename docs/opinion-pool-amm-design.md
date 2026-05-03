# DeSNet Opinion Pool — AMM Design Lock

**Date:** 2026-05-03
**Status:** Design locked (curve only); implementation pending
**Author:** Locked-in via design conversation
**Supersedes:** none (greenfield substrate)

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

## 1. Curve Lock: "Mirror-Mint Bootstrap"

**Single rule (applies to every deposit, from block 0):**

> Deposit `c` APT → atomically mint `c` Y + `c` N. User keeps `c` of chosen side. The other `c` auto-deposits into the pool.

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
| 3 | Initial liquidity source | **Zero-seed; first 2 traders bootstrap automatically** |

---

## 5. Open knobs (still UNLOCKED — sign-off required before code)

| # | Knob | Notes |
|---|---|---|
| 4 | "Graduation" mechanic | Mirror-Mint already always-on-main-AMM from day-1 (no separate launchpad → main-DEX phase). Likely N/A. Confirm. |
| 5 | Press / echo / emission interplay | Should `press` trigger auto-deposit? At what amount? Funded by whom (presser, PID owner, protocol)? Could compose with existing `reaction_emission`. |
| 6 | Fee structure | Bps on swap? Routed to LPs only? Or split with `apt_vault` for DESNET buyback-burn (mirror existing handle-fee mechanic)? |
| 7 | Multi-outcome (>2 sides) | Mirror-Mint extends naturally: `c` APT mints `c` of each of N tokens, user keeps c of chosen, rest (n−1) sides auto-deposit. Pool invariant becomes `prod(reserves) = k`. Defer to v2. |

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
