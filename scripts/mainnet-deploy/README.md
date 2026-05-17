# DeSNet Supra mainnet deploy

Pattern A.2 — Aptos-mirror exact. `@origin` = Aptos vanity reused (will become 1/4 → 3/4 multisig). `@desnet` = sha3-derived resource_account, no privkey ever.

## Prereqs

- `supra` CLI v0.5.0+ on PATH
- `~/.deploy/vanity_aptos_cddead_supra.txt` (0600) — vanity privkey for @origin
- `~/.deploy/hot_0047_seller.txt` (0600) — hot wallet privkey for 0x0047 (step 05 only)
- `python3` with `pynacl` (`pip install pynacl`) — for BCS auth message construction in step 03
- `@origin` funded with ≥ 1 SUPRA (estimated total deploy cost ≈ 0.5–1 SUPRA)

## Files

| File | Purpose |
|---|---|
| `_env.sh` | Shared env vars (sourced by other scripts) |
| `00-check.sh` | Read-only pre-flight: balance, Move.toml, tests |
| `01-publish-bootstrap.sh` | Single-tx publish of bootstrap pkg at @origin |
| `02-publish-desnet-chunked.py` | Chunked publish of desnet pkg at @desnet |
| `03-convert-to-multisig.py` | Vanity → 1/4 multisig + auth_key revoke |
| `04-smoke.sh` | Read-only post-deploy checks |
| `05-raise-threshold.sh` | Raise multisig 1/4 → 3/4 (interactive deferral, see file) |

## Run order

```
cd scripts/mainnet-deploy
bash 00-check.sh
bash 01-publish-bootstrap.sh
python3 02-publish-desnet-chunked.py
python3 03-convert-to-multisig.py
bash 04-smoke.sh
# (live with 1/4 multisig for smoke window — register handle, mint, etc.)
bash 05-raise-threshold.sh
```

Each script prompts before submitting any tx. Read the output, sanity-check, then `y`.

## Post-deploy state

| Resource | Address |
|---|---|
| `@origin` (gov authority, becomes 1/4 → 3/4 multisig) | `0x000010b58aa6179cf0249e004ce452b870a503e850f248ca9e9b68e276cddead` |
| `@desnet` (pkg location, resource_account) | `0x8edc10f93d38bcf373f3f3f28890c0af13b9325e9dce4c9d37873e50dd316585` |

Vanity privkey is burned after step 03. From step 04 onward, every state-mutating tx requires the multisig (1/4 then 3/4) — propose via any single owner initially, scaled to 3/4 post-smoke for production.

## Rollback

If a step fails mid-deploy:

- **Bootstrap publish fails**: nothing on chain. Fix + re-run 01.
- **Chunked publish fails partway**: `publisher::cleanup_staging` to drop StagingArea, then re-run 02 from scratch. Bootstrap CapHolder still alive.
- **Multisig conversion fails BEFORE auth_key revoke**: vanity privkey still alive, re-run 03.
- **Multisig conversion succeeds, smoke shows issue**: pkg is governance-controlled, upgrade via multisig (1/4 threshold = any single owner) or wait for DAO. NO rollback to EOA — multisig conversion is one-way.

## See also

- Memory: `desnet_supra_experiment.md` (full project history)
- Source-of-truth Move.toml: `/home/rera/desnet-supra/Move.toml` (committed `ed70fe8`)
- Mainnet config snapshot: `~/.deploy/desnet_supra_mainnet_config.txt`
