# DeSNet

A decentralized social network protocol on Supra. Every profile is an Object NFT, every profile spawns its own fungible token, and every social action — posts, likes, replies, quotes, presses, syncs — is an on-chain primitive. No centralized backend, no off-chain database, no protocol fees on swaps.

**Status:** v0.3.3 live on Supra mainnet (`@desnet = 0x7ba7ee5a...`). 18 Move modules, ~8.9k LoC, audited by a 6-LLM panel (5 GREEN / 1 YELLOW disputed-and-rejected).

**License:** [The Unlicense](LICENSE) — public domain.

---

## What it is

A profile (PID) on DeSNet is a transferable Object NFT with a deterministic address derived from its owner wallet. Registering a handle (`alice`, `bob`, `desnet`, …) atomically:

1. Mints the PID Object NFT to the registrant
2. Spawns a per-profile fungible token `$ALICE` (1B supply, 8 decimals)
3. Creates an SUPRA/`$ALICE` AMM pool seeded with 5 SUPRA + 50M tokens (FDV ≈ 100 SUPRA)
4. Locks the creator's LP position permanently into the staking pool
5. Splits the handle fee 10% to the deployer / 90% into SUPRA → DESNET buyback-burn

Handle pricing scales by length: 1-char = 100 SUPRA, 6+ chars = 1 SUPRA. One-time, immutable, no renewal.

The PID itself is the unit of identity, the token is the unit of speech-economy, and the AMM pool is the price discovery surface — all bound together at registration in a single transaction.

## The seven verbs

Every social action on DeSNet is one of seven on-chain primitives:

| Verb   | Module    | Meaning                                  |
|--------|-----------|------------------------------------------|
| Mint   | `mint`    | Original post (text ≤333 B + media)      |
| Spark  | `pulse`   | Like / positive reaction                 |
| Voice  | `mint`    | Reply (parent set)                       |
| Echo   | `pulse`   | Repost / amplify                         |
| Remix  | `mint`    | Quote-post (quote set)                   |
| Press  | `press`   | Mint a Mint as a collectible NFT         |
| Sync   | `link`    | Subscribe to a PID's mints               |

Posts can carry tags (ownerless folksonomy), tickers (factory-spawned `$X` only — every ticker resolves to a PID), mentions (any Supra address), and tips (any FA-standard token). Pressing a Mint distributes a linear-curve emission from that token's reaction reserve to the presser.

## Architecture

```
                          governance (DAO + chunked upgrade infra)
                                       │
       ┌──────────┬─────────┬──────────┼───────────┬────────────┬──────────┐
       │          │         │          │           │            │          │
   profile     factory     amm    lp_staking   supra_vault   supra_fee   voter_history
   (PID NFT)  (atomic     (SUPRA/$T  (LP NFT     (50/50      _vault       (DESNET-only
              spawn)       10bps)   positions   buyback-    (10/90       voting power
                                    + emission) burn)       deployer/    + fallback)
                                                            buyback-
                                                            burn)
       │
       ├── reference_gate (sync + balance + LP-stake gating)
       ├── link / pulse / mint / press   (verb modules — friend-only writers)
       ├── history       (per-PID BCS append-only log, 30 KB chunks rotate)
       ├── assets        (fractal-tree on-chain media ≤ 5 MB, MIME PNG/JPEG/WebP/GIF/SVG)
       ├── giveaway      (FA / NFT giveaways with 3 gates)
       ├── lp_emission / reaction_emission (sealed reserves: 90% LP, 5% reactions)
       └── supra_vault     (per-token SUPRA vault with embedded BurnRef)
```

**Eighteen modules total.** The graph is enforced by Move `friend` visibility — verb modules can only write to `history` through the friend interface, factory is the only creator of new `$TOKEN`s, `supra_vault` holds each token's `BurnRef` and exposes burn only via a delegate call from `supra_fee_vault`.

## Where the value flows

**DESNET (the protocol token).** Registered as the `desnet` handle. Receives 90% of every handle-registration fee as a buyback-and-burn: SUPRA → AMM swap → burn. Two-phase commit-reveal (`request_settle` → 60 s delay → `execute_settle`) defends against MEV. Every settle is permissionless and every burn is a permanent supply reduction. v0.3.2 first burn: 3,685,451 DESNET (-0.37% supply on a single 0.9 SUPRA settle).

**Per-profile tokens.** 1B supply at mint, allocated:
- 5% (50M) seeded into the AMM pool
- 5% (50M) into the reaction emission reserve (drained as Press distributes)
- 90% (900M) into the LP emission reserve (drained as LP stakers claim)
- Creator allocation: 0% (forever-locked LP position is the stake)

**LP staking.** V3-style position NFTs. Two stake kinds — *locked* (atomic at register, the creator's seed LP, never withdrawable) and *free* (anyone can add, withdrawable). Both feed `voter_history` for governance weight and `reference_gate` for engagement gating.

## Governance

Single DAO over the monolith package. Voting power = a voter's cumulative DESNET-denominated LP rewards (per-token isolated, with a transitional fallback to legacy mixed reads for pre-v0.3.2 voters). Chunked package upgrades stage modules into a `DaoUpgradeStaging` resource via `dao_stage_chunks_into_staging`, then publish atomically via `dao_publish_chunked_upgrade` with hash-pin verification. Multisig 3/5 on `@origin` for the bootstrap publisher path.

## Audit

External multi-LLM audit panel across six rounds (R1 → R6). v0.3.3 R6 verdict: **5 GREEN / 1 YELLOW**.

| Reviewer       | R6 Verdict | Notes                                         |
|----------------|-----------:|-----------------------------------------------|
| Gemini 3.1 Pro | GREEN      | "definitive and required fix" on settle MEV   |
| DeepSeek V3.2  | GREEN      | "Proceed with chunked mainnet deploy"         |
| Grok 4 (xAI)   | GREEN      | "Deploy v0.3.3. Production ready."            |
| Claude Opus 4.7| GREEN      | 6 LOW/INFO findings for v0.3.4 backlog        |
| Kimi K2.6      | GREEN      | "no latent HIGH or MED" sweep                 |
| Qwen 3 Max     | YELLOW     | Q-H1 disputed → REJECTED on 5/6 consensus     |

All R6 reviewer responses, the diff vs `v0.3.2-mainnet-live`, the self-audit (S1 was a HIGH self-find that we caught and fixed pre-deploy), and the cross-validation matrix are under [`docs/audit/v033-r6-submission/`](docs/audit/v033-r6-submission/). Earlier rounds R1-R5 are in [`docs/audit/`](docs/audit/) alongside the submission packages and external responses.

## Source layout

```
sources/
  governance.move          DAO + chunked upgrade staging + multisig publish
  factory.move             Atomic register_handle pipeline
  profile.move             PID Object NFT + handle registry + signer hierarchy
  amm.move                 SUPRA/$TOKEN constant-product pool, 10 bps to LP
  lp_staking.move          V3-style LP positions + emission + fee claims
  lp_emission.move         Sealed 900M reserve drained by claims
  reaction_emission.move   Sealed 50M reserve drained by Press actors
  supra_vault.move           Per-token vault + embedded BurnRef
  supra_fee_vault.move    10/90 split + two-phase MEV-safe settle
  voter_history.move       Per-token voting power with legacy fallback
  reference_gate.move      Sync + balance + LP-stake gating primitive
  mint.move                Mint / Voice / Remix verbs
  pulse.move               Spark / Echo verbs
  press.move               Press collectible NFT
  link.move                Sync verb + PidSyncSet state
  history.move             BCS append-only per-PID log, 30 KB chunks
  assets.move              Fractal-tree on-chain media ≤ 5 MB
  giveaway.move            FA / NFT giveaway primitive

tests/
  v030_integration.move    Full-flow integration tests
docs/
  v0.3.0-design-lock.md    Locked design doc (read first)
  v0.3.3-self-audit.md     Self-audit findings S1-S5
  audit/                   External R1-R6 audit packages + responses
```

## Building

```sh
supra move tool compile --named-addresses \
  desnet=<deploy_addr>,origin=<origin_addr>,desnet_claimer=<claimer_addr>
supra move tool test
```

The package depends on `desnet-bootstrap` (a sibling local package providing the chunked-upgrade publisher capability — required because the package exceeds Supra's 64 KB single-tx publish limit). Mainnet deploys go through `governance::multisig_stage_upgrade_chunk` → `multisig_publish_chunked_upgrade` with a 3/5 multisig threshold on `@origin`.

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
| SUPRA vault (DESNET)    | `0xfd45ced87cc95c4a9f2bba5c633b357d748d0b03071e19ff2b66529104774d09` |

## Design philosophy

- **One PID, one token, one pool, one tx.** Identity, currency, and market are inseparable.
- **No protocol fees on swaps.** AMM fee 10 bps, 100% to LP. Protocol revenue comes only from handle registration.
- **No off-chain dependencies for core flows.** Posts, media, history — all on-chain. Frontend is a renderer, not a backend.
- **Tickers are scarce by design.** Every `$X` ticker resolves to a PID. No anonymous launchpads.
- **Tags are ownerless.** Folksonomy permanently — no namespace landgrab.
- **Forever-lock the creator LP.** No rug surface. The creator earns from emissions and fees, not from extraction.
- **F7 cross-token inflation defense.** Voting power isolates per-token rewards; legacy mixed reads only as a pre-v0.3.2 transition fallback.
- **MEV-safe settle.** Commit-reveal with 60 s delay and 5% slippage cap. Snapshot amounts pin against vault growth between request and execute.

## Versions

- **v0.3.3** — current mainnet. R6 audit 5/6 GREEN. Tag `v0.3.3-mainnet-live`.
- **v0.3.2** — superseded. Introduced two-phase settle infra and per-token voter history.
- **v0.3.1** — superseded. Added `supra_fee_vault` (initial 50/50 split, later changed to 10/90).
- **v0.3.0** — initial mainnet. Design lock under [`docs/v0.3.0-design-lock.md`](docs/v0.3.0-design-lock.md).
