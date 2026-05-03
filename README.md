# DeSNet

A decentralized social network protocol on Aptos. Every profile is an Object NFT, every profile spawns its own fungible token, and every social action — posts, likes, replies, quotes, presses, syncs, **opinions** — is an on-chain primitive.

No centralized backend. No off-chain database. No oracle. No expiry. No protocol fees on swaps.

**Status:** v0.4 live on Aptos mainnet (`@desnet = 0x7ba7ee5a...`). 19 Move modules, ~10.6k LoC. Audited across seven external review rounds (R1 → R7) and four parallel pre-deploy paranoid agents.

**License:** [The Unlicense](LICENSE) — public domain.

---

## What it is

A profile (PID) on DeSNet is a transferable Object NFT with a deterministic address derived from its owner wallet. Registering a handle (`alice`, `bob`, `desnet`, …) atomically:

1. Mints the PID Object NFT to the registrant
2. Spawns a per-profile fungible token `$ALICE` (1B supply, 8 decimals)
3. Creates an APT/`$ALICE` AMM pool seeded with 5 APT + 50M tokens (FDV ≈ 100 APT)
4. Locks the creator's LP position permanently into the staking pool
5. Splits the handle fee 10% to the deployer / 90% into APT → DESNET buyback-burn

Handle pricing scales by length: 1-char = 100 APT, 6+ chars = 1 APT. One-time, immutable, no renewal.

The PID is the unit of identity, the token is the unit of speech-economy, the AMM pool is the price discovery surface, and — as of v0.4 — **every mint can carry an always-open belief market** denominated in its author's own token. All bound together at registration in a single transaction.

## What's new in v0.4

Two strictly compat-additive feature lines, deployed via 3/5 multisig chunked upgrade:

- **Opinion pool** (`desnet::opinion`, 1.7k LoC) — perpetual no-settle prediction-market substrate attached to mints. Belief expressed as price, never resolved, always tradable.
- **Assets multi-tier** (`desnet::assets` Tier-2 / Tier-3) — fractal-tree on-chain media uploads with deterministic-address chunks for parallel JS-pre-computed deploys.
- **`mint::create_opinion_mint`** — single new entry, one user click, one tx: regular mint plus atomic opinion-market bootstrap.

Compat: `mint::create_mint` signature byte-identical, `MintEvent` BCS layout unchanged, all friend grants framework-direction-locked. The v0.3.3 bytecode upgraded in place via `governance::multisig_publish_chunked_upgrade_with_digest` (R5 G5 hardening: source digest pinned off-chain, mismatch aborts before any bytecode lands).

## The eight verbs

Every social action on DeSNet is one of eight on-chain primitives:

| Verb     | Module    | Meaning                                                            |
|----------|-----------|--------------------------------------------------------------------|
| Mint     | `mint`    | Original post (text ≤333 B + media), optionally with opinion market|
| Spark    | `pulse`   | Like / positive reaction                                           |
| Voice    | `mint`    | Reply (parent set)                                                 |
| Echo     | `pulse`   | Repost / amplify                                                   |
| Remix    | `mint`    | Quote-post (quote set)                                             |
| Press    | `press`   | Mint a Mint as a collectible NFT                                   |
| Sync     | `link`    | Subscribe to a PID's mints                                         |
| Opinion  | `opinion` | Trade YAY/NAY belief on an opinion-mint (deposit / swap / redeem)  |

Posts can carry tags (ownerless folksonomy, lowercase `[a-z0-9-]`), tickers (factory-spawned `$X` only — every ticker resolves to a PID), mentions (any Aptos address), and tips (any FA-standard token). Pressing a Mint distributes a linear-curve emission from that token's reaction reserve to the presser. Trading on an opinion-mint moves price within a `x*y=k` curve denominated in the author's own creator-token, with a 0.1% tax burned from that same token on every interaction.

## Architecture

```
                          governance (DAO + chunked upgrade infra + digest pin)
                                       │
       ┌──────────┬─────────┬──────────┼───────────┬────────────┬──────────┐
       │          │         │          │           │            │          │
   profile     factory     amm    lp_staking   apt_vault   handle_fee   voter_history
   (PID NFT)  (atomic     (APT/$T  (LP NFT     (50/50      _vault       (DESNET-only
              spawn)       10bps)   positions   buyback-    (10/90       voting power
                                    + emission) burn)       deployer/    + fallback)
                                                            buyback-
                                                            burn)
       │
       ├── reference_gate (sync + balance + LP-stake gating)
       ├── link / pulse / mint / press   (verb modules — friend-only writers)
       ├── opinion       (per-mint YAY/NAY market, x*y=k, $creator_token-denominated)  ← NEW v0.4
       ├── history       (per-PID BCS append-only log, 30 KB chunks rotate)
       ├── assets        (fractal-tree on-chain media ≤ 5 MB, Tier 1/2/3 orchestrator) ← Tier 2/3 NEW v0.4
       ├── giveaway      (FA / NFT giveaways with 3 gates)
       ├── lp_emission / reaction_emission (sealed reserves: 90% LP, 5% reactions)
       └── apt_vault     (per-token APT vault with embedded BurnRef)
```

**Nineteen modules total.** Friend visibility enforces the graph: verb modules write `history` only via the friend interface, factory is the only creator of new `$TOKEN`s, `apt_vault::burn_via_vault` is direction-locked by the FA framework (you cannot burn DESNET from a creator-token vault — wrong-metadata abort), and `opinion::bootstrap_market_for_mint` is friend-only callable from `mint`.

---

## The opinion market — what makes it elegant

Most on-chain prediction markets need an **oracle**, an **expiry**, and a **resolution event**. The opinion pool needs none of them. It is built around a single observation:

> If the price of a YAY share is the market's confidence in a claim, then the price *is* the resolution. Resolving forecloses; not resolving keeps belief liquid forever.

The mechanism is the simplest CPMM you can write — `x * y = k` — applied to four design choices that compound into something useful:

### 1. Mirror-Mint Bootstrap

At creation, the author commits `initial_mc` of their own factory token. The contract atomically:

```
vault          ← initial_mc $creator_token   (locked, escrowed)
mint                initial_mc YAY           (newly issued FA)
mint                initial_mc NAY           (newly issued FA)
pool_yay       ← initial_mc YAY              (both sides go to the pool)
pool_nay       ← initial_mc NAY              (creator keeps zero position)

invariant: vault_balance == total_yay_supply == total_nay_supply
```

The pool is **active on block zero**, symmetric, and the creator holds neither side. There is no founder advantage, no first-mover skim, no warmup curve. Anyone — including the creator, paying like everyone else — can take a position immediately.

### 2. Creator-token denomination

Collateral and tax are both denominated in `$creator_token`, never APT, never USD, never DESNET. This binds the market's economics to the author's own social token, and produces several useful properties at once:

- **Skin in the game.** The author had to bring `initial_mc` of their own token to start the market. Their token's price reflects directly on the market's depth.
- **Spam is self-defeating.** Bad opinion markets consume their issuer's own token supply via the burn tax. Frivolous markets are penalized in the issuer's own currency, not borrowed liquidity.
- **No USD correlation.** A volatile or thin DESNET market does not destabilize an opinion-mint denominated in `$alice`. The market lives in the author's economy.
- **Trade volume is deflationary for the author.** Every swap, every deposit, every redeem burns 0.1% of the spot-equivalent `$creator_token`. A successful market actively reduces the author's supply — a positive feedback for engagement.

### 3. Conservation as the only invariant

There is no protocol-level reserve, no LP fee growth, no virtual reserve adjustment. The single invariant is asserted by the contract at every mutation:

```move
fungible_asset::balance(vault_token)
    == fungible_asset::supply(yay_metadata)
    == fungible_asset::supply(nay_metadata)
```

Any code path that breaks this aborts. Pool reserves can swing arbitrarily as traders take YAY or NAY positions; total YAY supply equals total NAY supply equals collateral always. **Always-exit** is mathematical, not contractual: anyone holding `(N YAY, N NAY)` can `redeem_complete_set(N)` for `N $creator_token` (minus tax skim), as long as conservation holds — which is enforced for as long as the market exists.

### 4. Compat-safe detection (Pattern B)

Opinion-mints emit the same `MintEvent` as any other mint, into the same per-PID history stream, with the same `VERB_MINT`. There is no `is_opinion: bool` field on the event. Indexers and clients distinguish opinion-mints by calling a pure view:

```move
opinion::market_exists(author_pid: address, seq: u64): bool
```

The market resource lives at a deterministic address derived from `(author_pid, seq)`. Existence at that address means it is an opinion-mint; non-existence means it is a regular mint. **The entire opinion feature was added without a single byte changing in `MintEvent`'s on-chain layout** — the v0.3.3 indexers continue to work unchanged, and v0.4-aware indexers add one extra view call per mint to classify them.

This compat property is what allowed the v0.4 upgrade to land on the existing v0.3.3 mainnet bytecode in place, with no migration, no event-stream rewrite, and no indexer ecosystem coordination.

### 5. Composability

Because opinion-mints **are** mints, every other DeSNet primitive applies to them natively. You can:

- Press an opinion-mint into a collectible NFT
- Sync to a PID and receive opinion-mints in your feed
- Voice (reply) on an opinion-mint with text or with another opinion-mint
- Remix (quote-post) an opinion-mint
- Spark / Echo it
- Tip the author in any FA-standard token

The opinion AMM is not a new app. It is an extra dimension of one feature: belief-as-price, layered onto the existing post primitive.

### 6. Trade verbs

| Verb                   | Pool effect       | Vault effect | User effect                                     |
|------------------------|-------------------|--------------|-------------------------------------------------|
| `deposit_pick_side(YAY, n)` | `+n NAY`     | `+n collateral` | User receives `n YAY`                       |
| `deposit_pick_side(NAY, n)` | `+n YAY`     | `+n collateral` | User receives `n NAY`                       |
| `deposit_balanced(n)`       | unchanged    | `+n collateral` | User receives `n YAY + n NAY` (atomic pair)|
| `swap_yay_for_nay(n_in)`    | `+n_in YAY, –amount_out NAY` | unchanged    | User trades YAY for NAY at curve price |
| `swap_nay_for_yay(n_in)`    | `+n_in NAY, –amount_out YAY` | unchanged    | User trades NAY for YAY at curve price |
| `redeem_complete_set(n)`    | unchanged    | `–n collateral` | User burns `n YAY + n NAY`, receives `n` collateral |

Every mutating verb burns `0.1%` of the spot-equivalent collateral as tax. The conservation invariant holds across every combination.

### 7. What the design refuses

- **No oracle.** No Switchboard, Pyth, or UMA dependency. Truth is expressed as price and reprices continuously.
- **No expiry.** The market exists as long as the resource exists. There is no settlement, no maturity, no rollover.
- **No resolution committee.** No multisig discretion to declare a winner. Disputes happen as trades.
- **No virtual reserves, no curve adjustments, no time-decay.** Pure `x*y=k` from block zero forever.
- **No LP shares.** The creator's `initial_mc` is escrowed into the vault permanently as a "always-redeemable-by-pair-holders" reserve. There is no LP NFT to mint, transfer, or claim fees from. The "fee" is the tax burn; recipients are all `$creator_token` holders, by deflation.

The result is a market that is **maximally liquid in expressing belief and maximally illiquid as a financial instrument** — exactly the tradeoff a social network wants when prediction markets become first-class posts.

---

## Assets multi-tier — three doors, frontend chooses

Mint events embed media via `MintMedia { kind, mime, ref_blob_id, … }`. For media >8 KB (the inline-payload cap in the mint event itself), the asset module stores binary blobs as a fractal tree of 30 KB chunks, up to 5 MB total, with `MIME ∈ {PNG, JPEG, GIF, WebP, SVG}` and sealed-after-finalize immutability.

The orchestrator (`assets::orchestrator_tier()` returns `3` on mainnet) exposes three address-allocation strategies. Frontends choose the tier based on use case:

| Tier | Entry suffix     | Address allocation                                                      | Best for |
|------|------------------|-------------------------------------------------------------------------|----------|
| 1    | (default)        | Server allocates the Object addr at `start_upload`; caller queries it back | Simple sequential uploader, address known after first tx |
| 2    | `*_pub`          | Same as Tier-1, but the entry returns the addr explicitly                | Move scripts that chain `start_upload` → `deploy_chunk` in one tx |
| 3    | `*_v2`           | **Deterministic** addr from `(uploader, master_nonce, chunk_index)` via sha3 + `create_named_object` | Frontends that pre-compute every chunk address in JS before any tx fires; supports parallel chunk uploads + retry-with-known-addr |

A frontend uploading a 5 MB image can pre-compute all 167 chunk addresses + 6 leaf-node addresses + 1 root-node address purely client-side (deterministic sha3 derivation matches Move's `create_named_object` exactly), submit chunk-deploy transactions in parallel without coordinating, and finalize once the last chunk lands — turning a 30+ tx serialized upload into a single round-trip.

---

## Where the value flows

**DESNET (the protocol token).** Registered as the `desnet` handle. Receives 90% of every handle-registration fee as a buyback-and-burn: APT → AMM swap → burn. Two-phase commit-reveal (`request_settle` → 60 s delay → `execute_settle`) defends against MEV. Every settle is permissionless and every burn is a permanent supply reduction.

**Per-profile tokens.** 1B supply at mint, allocated:
- 5% (50M) seeded into the AMM pool
- 5% (50M) into the reaction emission reserve (drained as Press distributes)
- 90% (900M) into the LP emission reserve (drained as LP stakers claim)
- Creator allocation: 0% — the forever-locked LP position is the stake

**Opinion markets** layer additional deflation onto creator-tokens: every trade on an opinion-mint burns 0.1% of the spot-equivalent `$creator_token`. Successful debate produces volume; volume produces burn. There is no protocol skim.

**LP staking.** V3-style position NFTs. Two stake kinds — *locked* (atomic at register, the creator's seed LP, never withdrawable) and *free* (anyone can add, withdrawable). Both feed `voter_history` for governance weight and `reference_gate` for engagement gating.

## Governance

Single DAO over the monolith package. Voting power = a voter's cumulative DESNET-denominated LP rewards (per-token isolated, with a transitional fallback to legacy mixed reads for pre-v0.3.2 voters). Chunked package upgrades stage modules into a `DaoUpgradeStaging` resource via `dao_stage_chunks_into_staging`, then publish atomically via `dao_publish_chunked_upgrade` with hash-pin verification. Multisig 3/5 on `@origin` for the bootstrap publisher path.

For deploy operators: see [`docs/sop-chunked-multisig-deploy.md`](docs/sop-chunked-multisig-deploy.md) for the full chunked-deploy SOP, including the BCS-digest pitfall, recovery scenarios, and reference txs from the v0.4 deploy.

## Audit

| Round | Verdict             | Notes                                                                  |
|-------|---------------------|------------------------------------------------------------------------|
| R1–R5 | iterative           | See [`docs/audit/`](docs/audit/) — submission packages + responses     |
| **R6 (v0.3.3)** | **5 GREEN / 1 YELLOW** | Q-H1 disputed → REJECTED on 5/6 consensus                  |
| **R7 (v0.4 opinion)** | **5 GREEN / 1 YELLOW** | 0 unfixed HIGH; full R7 panel under [`docs/audit/v040-rc1-submission/`](docs/audit/v040-rc1-submission/) |
| Pre-deploy paranoid (v0.4) | 4 / 4 GREEN | Compat / atomicity / friend-graph / state-invariant agents in parallel |
| rc4 fix bundle | applied             | M1 sym `E_ZERO_OUTPUT`, L1 `E_TAX_DRIFT`, L2 `E_MARKET_ALREADY_EXISTS` |

Tests: **113/113 GREEN** at the time of the v0.4 deploy.

## Source layout

```
sources/
  governance.move            DAO + chunked upgrade staging + multisig publish (with digest pin)
  factory.move               Atomic register_handle pipeline
  profile.move               PID Object NFT + handle registry + signer hierarchy
  amm.move                   APT/$TOKEN constant-product pool, 10 bps to LP
  lp_staking.move            V3-style LP positions + emission + fee claims
  lp_emission.move           Sealed 900M reserve drained by claims
  reaction_emission.move     Sealed 50M reserve drained by Press actors
  apt_vault.move             Per-token vault + embedded BurnRef
  handle_fee_vault.move      10/90 split + two-phase MEV-safe settle
  voter_history.move         Per-token voting power with legacy fallback
  reference_gate.move        Sync + balance + LP-stake gating primitive
  mint.move                  Mint / Voice / Remix verbs + create_opinion_mint
  pulse.move                 Spark / Echo verbs
  press.move                 Press collectible NFT
  link.move                  Sync verb + PidSyncSet state
  history.move               BCS append-only per-PID log, 30 KB chunks
  assets.move                Fractal-tree on-chain media ≤ 5 MB, Tier 1/2/3
  opinion.move               Perpetual no-settle prediction-market substrate  ← v0.4
  giveaway.move              FA / NFT giveaway primitive

scripts/
  asset_upload_b2.move          Tier-2 chunked-script upload helper
  asset_upload_b3.move          Tier-3 deterministic-addr upload helper
  asset_upload_b3_3chunks.move  Fixed-3-chunk variant (CLI vector<vector<u8>> workaround)

tests/
  v030_integration.move      Full-flow integration tests

docs/
  v0.4-assets-and-opinion-readme.md     v0.4 architecture reference
  sop-chunked-multisig-deploy.md        Deploy operator SOP (v0.4 lessons)
  v0.3.0-design-lock.md                 Locked design doc (read first)
  audit/                                 R1–R7 audit packages + responses
```

## Building

```sh
aptos move compile --named-addresses \
  desnet=<deploy_addr>,origin=<origin_addr>,desnet_claimer=<claimer_addr>
aptos move test
```

The package depends on `desnet-bootstrap` (a sibling local package providing the chunked-upgrade publisher capability — required because the package exceeds Aptos's single-tx publish limit). Mainnet upgrades go through `governance::multisig_stage_upgrade_chunk` → `multisig_publish_chunked_upgrade_with_digest` with a 3/5 multisig threshold on `@origin` and an off-chain-pinned source digest.

## Mainnet addresses

| Resource              | Address                                                              |
|-----------------------|----------------------------------------------------------------------|
| Package `@desnet`     | `0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724` |
| `@origin` multisig    | `0x000073c4dd3fa51260b4cd8b6878191214df1e6dcd4dbcd1ed906c05c3aaa9a9` |
| DESNET PID NFT        | `0xfa4dd0513a60afe94e9dcafda75e50072ef9718b14b8a91a731f2d04d9fc3adf` |
| DESNET FA             | `0x44c1006d4d8dae79195fa396c71408514343a5c4b4627b6e7595f64d65b224e7` |
| DESNET AMM pool       | `0x5ba92cb1c4eb871b36eb4475b85763c390f8aa604946eb1ea26c10ee46c822a8` |
| LP staking pool       | `0x983d04dd23cdaa139af36e79af464739e6ec9f13874c2f6dc329ee508389481b` |
| LP emission reserve   | `0x19c83d5de114c22ca462029c1ec5069d3c9c3aaec7a8028aefb4a41942e1088b` |
| Reaction emission     | `0x4d7544844fa9b6eea0a2720b434627986fc7adc0339d39b851824a892be44e23` |
| APT vault (DESNET)    | `0xfd45ced87cc95c4a9f2bba5c633b357d748d0b03071e19ff2b66529104774d09` |
| First opinion market  | `0xc3ee69681fe46af7d82480c96b1cc4a598f960aa94f8994d003d6463a5092dac` (`@desnet/seq=1` — "Make Aptos Great Again") |

## Design philosophy

- **One PID, one token, one pool, one tx.** Identity, currency, and market are inseparable.
- **Belief is liquid; resolution forecloses.** Opinion markets have no oracle, no expiry, no settlement. Price is the verdict.
- **No protocol fees on swaps.** AMM fee 10 bps, 100% to LP. Opinion tax 10 bps, 100% burned. Protocol revenue comes only from handle registration.
- **No off-chain dependencies for core flows.** Posts, media, history, opinion markets — all on-chain. Frontend is a renderer, not a backend.
- **Tickers are scarce by design.** Every `$X` ticker resolves to a PID. No anonymous launchpads.
- **Tags are ownerless.** Folksonomy permanently — no namespace landgrab.
- **Forever-lock the creator LP.** No rug surface. The creator earns from emissions and fees, not from extraction.
- **Conservation is asserted, not assumed.** Every opinion mutation re-checks `vault == total_yay_supply == total_nay_supply` against framework state.
- **Compat-safe upgrades.** v0.4 added a 1.7k LoC module without touching `MintEvent`'s BCS layout. Indexers continue to work unchanged.
- **F7 cross-token inflation defense.** Voting power isolates per-token rewards.
- **MEV-safe settle.** Commit-reveal with 60 s delay and 5% slippage cap.
- **Source digest pinned off-chain.** Final-chunk publish aborts if assembled `(metadata, code)` digest doesn't match the pre-shared expected digest. Defense-in-depth against rogue mid-deploy chunk substitution.

## Versions

- **v0.4** — current mainnet. R7 audit 5/6 GREEN + 4/4 paranoid agents GREEN. Adds opinion + assets multi-tier. Tag `v0.4-mainnet-live`.
- **v0.3.3** — superseded by v0.4. R6 audit 5/6 GREEN. Tag `v0.3.3-mainnet-live`.
- **v0.3.2** — superseded. Introduced two-phase settle infra and per-token voter history.
- **v0.3.1** — superseded. Added `handle_fee_vault` (initial 50/50 split, later changed to 10/90).
- **v0.3.0** — initial mainnet. Design lock under [`docs/v0.3.0-design-lock.md`](docs/v0.3.0-design-lock.md).
