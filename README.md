# DeSNet (Supra port)

A decentralized social network protocol on Supra. Every profile is an Object NFT, every profile spawns its own fungible token through an IPO, and every social action — posts, likes, replies, quotes, presses, syncs, opinions — is an on-chain primitive. No centralized backend, no off-chain database, no protocol fees on swaps.

**Status:** **LIVE on Supra mainnet** (2026-05-18). 21 Move modules, ~10k LoC. `@origin` is a 3/5 multisig, vanity privkey burned, package upgrade #1 already landed via governance path.

**License:** [The Unlicense](LICENSE) — public domain.

---

## What it is

A profile (PID) on DeSNet is a transferable Object NFT. Registering a handle (`alice`, `bob`, `desnet`, …) atomically:

1. Mints the PID Object NFT to the registrant
2. Reserves a per-profile fungible token `$ALICE` (1B supply, 8 decimals)
3. Opens an **IPO** that accepts SUPRA at a fixed entry price up to a target TVL
4. Lets anyone (including the creator) back the handle by depositing SUPRA — depositors get a *subdomain* Profile NFT (`name@alice`) carrying their share + locked LP claim
5. On IPO completion, the AMM `SUPRA/$ALICE` pool spawns at the determined price, LP locks onto subdomain NFTs, and rewards start streaming through a permissionless multi-FA gauge

Handle pricing scales by length: 1-char = 100 SUPRA, 6+ chars = 1 SUPRA. One-time, immutable, no renewal.

**Pre-completion refund:** anyone holding an IPO subdomain Position NFT can burn it for **100% refund** at any time before the target TVL is reached. Refund auto-claims accrued LP rewards first.

**Subdomain PID is a full citizen.** `name@alice` can post, sync, press, opinion — all verbs accept an explicit `pid_addr` parameter, authorized via "caller is controller OR Profile NFT owner." Transferring a subdomain NFT carries the locked LP shares + reward debts + fee debts along with it.

## The eight verbs

Every social action on DeSNet is one of eight on-chain primitives:

| Verb     | Module      | Meaning                                                  |
|----------|-------------|----------------------------------------------------------|
| Mint     | `mint`      | Original post (text ≤333 B + media)                      |
| Spark    | `pulse`     | Like / positive reaction                                 |
| Voice    | `mint`      | Reply (parent set)                                       |
| Echo     | `pulse`     | Repost / amplify                                         |
| Remix    | `mint`      | Quote-post (quote set)                                   |
| Press    | `press`     | Mint a Mint as a collectible NFT — distributes rewards   |
| Sync     | `link`      | Subscribe to a PID's mints                               |
| Opinion  | `opinion`   | Binary YAY/NAY prediction market on a Mint               |

Posts can carry tags (ownerless folksonomy), tickers (factory-spawned `$X` only — every ticker resolves to a PID), mentions (any Supra address), and tips (any FA-standard token). Pressing a Mint distributes a BPS-of-pool slice from the author's multi-FA reward pool to the presser; pools decay asymptotically and never zero.

## Architectural delta vs DeSNet Aptos mode

| Surface              | Aptos mode (sibling)                 | This (Supra mode)                            |
|----------------------|--------------------------------------|----------------------------------------------|
| Token distribution   | 5% AMM / 5% reactions / 90% LP, all sealed at register | **100% to IPO pool**, depositor-driven |
| Creator allocation   | Locked LP NFT forever                | **0 token by default** — handle = identity only. Optional 10% MAX_CREATOR_BPS via creator self-IPO at register time |
| Launch mechanic      | Atomic spawn + immediate LP staking  | **IPO with refund-during-IPO** — burn position pre-target = 100% refund |
| LP reward source     | Sealed `$TOKEN` reserve, depleting   | **Permissionless multi-FA topup gauge** (Synthetix-style, MasterChef acc_per_share) |
| Reaction reward      | Sealed `$TOKEN` reserve, linear curve| **BPS-of-pool per press** from multi-FA gauge, per-PID isolated |
| Identity             | Main handle only                     | Main handle **+ subdomain `name@alice`** via IPO deposit |
| Profile entry path   | Must register own handle             | **Can also enter as backer** — IPO deposit creates subdomain Profile NFT |

## Architecture

```
                        governance (DAO + chunked upgrade infra)
                                       │
       ┌──────────┬─────────┬──────────┼───────────┬────────────┬──────────────┐
       │          │         │          │           │            │              │
   profile    factory    amm    lp_emission  supra_vault  supra_fee_vault  voter_history
  (PID NFT,  (reserves  (SUPRA/  (multi-FA   (per-token   (handle-fee     (DESNET-only
   sub-PID)   ticker)   $TOKEN   topup       buyback +    split + MEV-    voting power
                        100 bps) gauge)      MEV-safe     safe settle)    + fallback)
                                             settle)
       │
       ├── registration  (atomic register + optional creator self-IPO seed)
       ├── ipo            (100% IPO, refund-during, auto-stake Position)
       ├── opinion       (binary YAY/NAY prediction market)
       ├── reference_gate (sync + balance + LP-stake gating)
       ├── link / pulse / mint / press   (verb modules — friend-only history writers)
       ├── history       (per-PID BCS append-only log, 30 KB chunks rotate)
       ├── assets        (fractal-tree on-chain media ≤ 5 MB, MIME PNG/JPEG/WebP/GIF/SVG)
       ├── giveaway      (FA / NFT giveaways with 3 gates)
       ├── reaction_emission (per-PID BPS-of-pool multi-FA gauge for Press)
       └── lp_staking    (legacy free-stake path, AMM fee accrual only)
```

**21 modules total.** The graph is enforced by Move `friend` visibility — verb modules write to `history` only via the friend interface, `factory` is the only creator of new `$TOKEN`s, `supra_vault` holds each token's `BurnRef` and exposes burn only via delegate call from `supra_fee_vault`, `ipo` is friend of `profile` for subdomain Profile NFT creation + Position-at-PID-addr storage.

## IPO + reward economics

**Per-profile token at register:** 1B supply (8 decimals). 100% directed into the IPO pool. Tokens are only minted into circulating supply as IPO depositors claim post-completion (or as creator-seeded LP unwinds via emissions). Pre-completion, the IPO contract holds the entire mint allocation.

**Cap branching at `deposit_supra`:**
- Caller is the registered handle's wallet: `MAX_CREATOR_BPS = 1000` (10%)
- Any other depositor: `MAX_PER_ADDRESS_BPS = 100` (1%)

**Position auto-stake.** Reward debts are embedded in `ipo::Position`. There's no separate `lp_staking::Position` for IPO participants. Single NFT, single claim path. Reward debts are stored at the subdomain PID's deterministic address — transferring the subdomain NFT carries shares + debts together.

**Permissionless reward topup.** Anyone can call `lp_emission::notify_reward(handle, reward_token_meta, amount)` or `reaction_emission::notify_reward(author_pid, reward_token_meta, amount)`. Pools accept up to 32 registered reward tokens each. MasterChef-style `acc_per_share` with `ACC_SCALE = 1e12` (lowered from 1e18 to keep u128 intermediates safe at extreme bounds). DESNET notifies also feed `governance::record_emission_for_window` for DAO 30 d threshold tracking.

**Dispatchable-FA defense.** `notify_reward` rejects FAs that have `register_dispatch_functions` installed — a malicious FA hook could brick `press::press` or `burn_for_refund`. The check is one-shot at FA creation time, so a plain FA stays plain forever.

## Governance

Single DAO over the monolith package. Voting power = a voter's cumulative DESNET-denominated LP rewards (per-token isolated, F7 fix). Two upgrade paths to `@desnet`:

- **Multisig upgrade.** 3/5 multisig on `@origin` calls `governance::multisig_publish_chunked_upgrade_with_digest` with BCS-digest-verified payload. Used for the initial operational window (upgrade #1 landed via this path 2026-05-18).
- **DAO upgrade.** `governance::propose_upgrade` → `cast_vote` (7 d window, 35% quorum on the voter's emission-weighted balance) → `dao_publish_chunked_upgrade`. Eventually-canonical path.

The multisig path is one-way-disablable via `disable_multisig_upgrade`, handing exclusive control to the DAO.

## Audit

External multi-LLM audit panel **Supra-R1 submission** at `docs/audit/supra-r1-submission/` — five files covering surface deltas vs the audited Aptos R6 baseline, self-audit Y-1..Y-5 + status, focused reviewer checklist, full source bundle (550 KB / 13.6k lines). Aptos baseline R1–R6 (5 GREEN / 1 YELLOW final on the v0.3.3 sibling repo) is explicitly carry-over.

Notable self-finds during Supra port:
- **D-3 (HIGH).** `ipo::complete_ipo` was permissionless `total_supra_raised > 0` → anyone could lock the IPO after first deposit, voiding refund. Fixed to `>= ipo.target_tvl`.
- **Y-1 (HIGH).** Anti-wash on `burn_for_refund` — `depositor_totals` decrement only when caller == original depositor (closes NFT-transfer-then-refund cycling).
- **Y-2 (HIGH).** Slippage params `min_supra_out` / `min_token_out` on refund (was zero-slippage).
- **Y-4 (HIGH).** Dispatchable-FA defense on both gauges, as above.
- **`supra_vault` HIGH (post-submit).** `execute_settle` used `min_out = 0` on buyback swap → MEV sandwich window. Fixed with snapshot `min_token_out = quote × 95%` and grace-window guards.

## Source layout

```
sources/
  governance.move            DAO + chunked upgrade staging + multisig publish
  registration.move          Atomic register_handle + optional creator self-IPO seed
  factory.move               Token reservation, mint authority, BurnRef parking
  profile.move               PID Object NFT + handle registry + subdomain Profile NFT
  ipo.move                   100% IPO + refund + auto-stake Position at PID addr
  amm.move                   SUPRA/$TOKEN constant-product pool, 100 bps to LP
  lp_emission.move           Multi-FA permissionless topup gauge for IPO Positions
  lp_staking.move            Legacy free-stake path (AMM fee only, no emission)
  reaction_emission.move     Per-author-PID BPS-of-pool multi-FA gauge for Press
  voter_history.move         Per-token voting power with legacy fallback
  reference_gate.move        Sync + balance + LP-stake gating primitive
  mint.move                  Mint / Voice / Remix verbs
  pulse.move                 Spark / Echo verbs
  press.move                 Press collectible NFT (calls reaction_emission)
  link.move                  Sync verb + PidSyncSet state
  history.move               BCS append-only per-PID log, 30 KB chunks rotate
  assets.move                Fractal-tree on-chain media ≤ 5 MB (Tier-1 / Tier-2 / Tier-3)
  giveaway.move              FA / NFT giveaways (follower / NFT-hold / LP-stake gates)
  opinion.move               Binary YAY/NAY prediction market on a Mint
  supra_vault.move           Per-token vault + embedded BurnRef + MEV-safe settle
  supra_fee_vault.move       Handle-fee split + two-phase MEV-safe settle

tests/
  v030_integration.move      Aptos-baseline carry-over integration tests
  supra_port_v04.move        Per-PID reaction isolation + Supra-port-specific surfaces

docs/
  audit/                     R1–R6 Aptos audit packages + Supra-R1 submission
scripts/
  mainnet-deploy/            Five-step deploy runbook (Pattern A.2, executed 2026-05-18)
```

## Building

```sh
supra move tool test --dev --ignore-compile-warnings
supra move tool build-publish-payload \
  --package-dir . \
  --named-addresses desnet=<desnet_addr>,origin=<origin_addr> \
  --included-artifacts none \
  --override-size-check
```

The package depends on `desnet-bootstrap-supra` (a sibling local package providing the chunked-upgrade publisher capability — required because the package exceeds Supra's 64 KB single-tx publish limit). Mainnet deploys go through `publisher::stage_chunk` (N times) → `publisher::publish_chunked`, all signed by `@origin`. Post-publish, `@origin` was converted to a 3/5 multisig and the vanity privkey was burned via `account::create_with_existing_account_and_revoke_auth_key`.

## Mainnet addresses

| Resource                  | Address                                                              |
|---------------------------|----------------------------------------------------------------------|
| Package `@desnet`         | `0x8edc10f93d38bcf373f3f3f28890c0af13b9325e9dce4c9d37873e50dd316585` |
| `@origin` (3/5 multisig)  | `0x000010b58aa6179cf0249e004ce452b870a503e850f248ca9e9b68e276cddead` |
| Bootstrap pkg (publisher) | `0x000010b58aa6179cf0249e004ce452b870a503e850f248ca9e9b68e276cddead` (at @origin) |
| First handle `desnet` PID | `0xecb7e428…f93105a`                                                 |
| DESNET FA                 | `0xe96e2642…d10a9c012`                                               |
| DESNET IPO Object         | `0x19c97e33…5793bc59` (target 1M SUPRA)                              |
| AMM pool (post-deposit)   | `0xbf4386f1e4d4…30ad0a16`                                            |
| First subdomain PID       | `0xc6361ff35…a311f62e80` (`intern@desnet`, held by `0x0047a3e1…`)    |

Multisig owners (5, all confirmed raw-key Supra-signing-capable per audit 2026-05-18):
`0x85d1e404…814efd30`, `0x0047a3e1…f647321c9`, `0x85c7ab96…d3061197`, `0x1a502d89…e17f59a7`, `0xc257b12e…8fa0b093`.

## Design philosophy

- **One PID, one token, one IPO, one tx.** Identity, currency, and market are inseparable, but the market opens through a refundable depositor pool — not a pre-allocated reserve.
- **Subdomain PID is first class.** Backers are identities, not just shareholders. Their LP follows the NFT, their reward stream follows the NFT.
- **No protocol fees on swaps.** AMM fee 100 bps (1%), 100% to LP. Protocol revenue comes from handle registration only.
- **No off-chain dependencies for core flows.** Posts, media, history — all on-chain. Frontend is a renderer.
- **Tickers are scarce by design.** Every `$X` ticker resolves to a PID. No anonymous launchpads.
- **Tags are ownerless.** Folksonomy permanently — no namespace landgrab.
- **Permissionless rewards.** Anyone funds the gauge for any handle. No protocol-mandated emission schedule.
- **MEV-safe settle.** Commit-reveal with delay window and slippage cap on both `supra_vault` and `supra_fee_vault`.

## Sibling

The Aptos-mainnet sibling (v0.3.3, 18 modules, sealed-reserve economics) lives at [`github.com/darbitex/desnet`](https://github.com/darbitex/desnet) on the legacy `@desnet=0x7ba7ee5a…`. Both modes coexist on different chains so the market chooses.
