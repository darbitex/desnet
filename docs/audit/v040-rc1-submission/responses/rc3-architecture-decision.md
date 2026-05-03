# rc3 Architecture Decision — Mint-Integrated Opinion Flag

**Date:** 2026-05-03
**Trigger:** User identified architectural mistake during testnet smoke session
**Decision authority:** User-confirmed locked design

---

## The architectural mistake (rc1/rc2)

Opinion was implemented as a **standalone module** (`desnet::opinion::create_opinion`) parallel to mint. This created an "island" in the social feed:

- Opinion-mints used `VERB_OPINION` in history (different verb from regular mints)
- Reactions on opinion impossible via existing 7-verb palette:
  - ❌ `pulse::spark` (operates on mint)
  - ❌ `voice::reply` (references MintId)
  - ❌ `pulse::echo` (references mint)
  - ❌ `press::press_pid` (mint context, factory v1.2 emit_press_to_presser expects mint)
  - ❌ `mint::create_mint(quote_set=true)` Remix (references MintId)
  - ❌ `link::sync` (different scope)

User caught this during testnet smoke: "harusnya opinion ini dalam mint event bukan terpisah?"

Original spec from very early design session (re-read):
> "create opinion = mint event, isi mint event = Make Aptos Great Again, di event type ada struct opinion=true"

**rc1/rc2 deviated from spec.** Refactor needed.

---

## rc3 architecture (locked)

### Frontend UX flow

```
1. User opens standard mint composer (existing UI):
   - Content text + media + mentions + tags + tickers + tips
   - Reply (Voice mode) / Quote (Remix mode) / Original (Mint mode)

2. Below compose box: toggle "Mint this as opinion?"
   - Helper: "Requires ≥1M of your own $token in wallet"
   - Toggle ON expands: initial_mc slider [1M-100M]
   - tax_bps NOT exposed (hardcoded 10 bps default)

3. Single CLICK "Post" → 1 wallet sig → 1 atomic tx → done
```

### Backend (Move) atomic flow

```move
mint::create_mint(
    author, content_kind, content_text,
    ...media args...,
    ...threading args (parent/quote)...,
    mentions, tags, tickers, tips,
    asset_master_addr, asset_master_set,
    is_opinion: bool,                  // ← NEW (rc3)
    opinion_initial_mc: u64,            // ← NEW (rc3)
)
  ↓
  Step 1: Standard mint creation
    - Validate content + media + threading + tags + tickers
    - Allocate mint_seq from PidMintMeta
    - Build MintEvent with is_opinion flag
    - Append to history (VERB_MINT)
    - Execute tips
  
  Step 2: If is_opinion=true:
    - Internal call: opinion::bootstrap_market_for_mint(
        author_pid, mint_seq, opinion_initial_mc, DEFAULT_TAX_BPS)
    - Validates creator has factory token + ≥ initial_mc balance
    - Creates OpinionMarket at deterministic addr from (author_pid, mint_seq)
    - Mints initial_mc YAY + initial_mc NAY → both to pool
    - vault locks initial_mc forever
    - emits OpinionMintCreated event
    - All atomic — fail any step → revert entire tx
```

### Locked decisions

| # | Decision |
|---|---|
| 1 | `mint::create_mint` adds **2 args**: `is_opinion: bool`, `opinion_initial_mc: u64` |
| 2 | tax_bps **NOT** exposed as arg — hardcoded `DEFAULT_TAX_BPS = 10` internally |
| 3 | initial_mc range stays **[1M, 100M]** whole creator $token |
| 4 | Allow opinion flag on **all 3 mint modes** (Mint/Voice/Remix) — no restriction |
| 5 | DROP `opinion::create_opinion` standalone entry |
| 6 | ADD `opinion::bootstrap_market_for_mint` friend-only fn (called by mint) |
| 7 | ADD `opinion::deposit_balanced` standalone primitive (atomic balanced mint, anyone) |
| 8 | Opinion market addr unified: `(author_pid, mint_seq)` namespace |
| 9 | KEEP `VERB_OPINION` for trade actions (deposit_pick_side / swap / redeem) — not for create |
| 10 | CREATE event uses `VERB_MINT` with `is_opinion: bool = true` flag in MintEvent payload |
| 11 | Add `is_opinion: bool` field to MintEvent struct (BCS-visible to frontend) |
| 12 | Asset namespace conflict-free with opinion (different parent + different seed prefix) |

### Reactions composability (post-rc3)

After integration, opinion-mints ARE regular mints. ALL 7-verb mechanics apply:

- ✅ `pulse::spark` — sentiment reaction
- ✅ `voice::reply` — threaded comments
- ✅ `pulse::echo` — boost to followers
- ✅ `press::press_pid` — endorsement + $token emission
- ✅ `mint::create_mint(quote_set=true)` Remix — quote-tweet with own commentary
- ✅ `link::sync` — follow PID
- ✅ `opinion::deposit_pick_side(YAY/NAY)` — opinion-trading layer (new on top)

Opinion adds extra YAY/NAY trading capability ON TOP of regular mint mechanics. Both work composably.

### Asset namespace coexistence

Verified no conflict:

```
desnet::assets:
  parent = uploader_addr OR asset_master_addr
  seeds: b"asset_master::" + bcs(nonce), b"chunk::" + bcs(idx)

desnet::opinion:
  parent = pid_addr OR market_addr
  seeds: b"opinion_market::" + bcs(seq), b"YAY", b"NAY"
```

`create_named_object(parent, seed)` derives addr via `sha3_256(parent || seed || 0xfd)`. Different parent OR different seed = cryptographically unique addr.

---

## Implementation scope (rc3 refactor)

### Files to modify

1. **`sources/mint.move`** (~+30 LoC):
   - Add 2 args to `create_mint` signature
   - Add `is_opinion: bool` field to MintEvent struct
   - At end of create_mint body: branch on is_opinion → call opinion bootstrap

2. **`sources/opinion.move`** (~-50 LoC net, simpler):
   - DROP `create_opinion` public entry
   - ADD `bootstrap_market_for_mint` friend-only fn
   - ADD `deposit_balanced` standalone entry
   - DROP own seq counter (PidOpinionMeta.next_seq) — use mint's seq
   - KEEP PidOpinionMeta.opinion_count for stats
   - KEEP all trade entries (deposit_pick_side, swap_*, redeem)
   - KEEP history append for trade actions (VERB_OPINION)

3. **`sources/history.move`** — no changes (VERB_OPINION still used by trade ops)

4. **`sources/profile.move`** — no changes (friend opinion still needed)

5. **`sources/apt_vault.move`** — no changes (friend opinion still needed for tax burn)

### Friend grants (after refactor)

- `opinion.move`: ADD `friend desnet::mint;` (mint calls bootstrap_market_for_mint)
- All other friend grants unchanged

### Tests
- Update opinion tests where standalone create was tested
- Add mint integration test (mock + opinion flag flow)
- All 23 existing rc2 tests should still pass

### Re-deploy
- Fresh testnet (current testnet still has rc2 standalone create)
- Smoke test: register handle → create_mint with is_opinion=true → trade flow → verify reactions work

---

## Estimated effort

| Task | Effort |
|---|---|
| mint.move changes | ~30 LoC |
| opinion.move refactor | ~-50 net (drop create + add bootstrap + add deposit_balanced) |
| Tests update + new | ~50 LoC |
| Compile + test cycle | 10 min |
| Fresh testnet deploy | 15 min (3 tx: bootstrap + 2 chunked DesNet) |
| Testnet smoke (mint+opinion flow + reactions) | 20 min |
| Total | ~half day |

---

## Decision sign-off (recorded)

User: "kalau bisa semua bagus benar, silahkan" (re: allow opinion on all 3 mint modes)
User: "save decision dan commit dulu baru refactor"

Status: rc3 architecture LOCKED. Refactor execution pending.
