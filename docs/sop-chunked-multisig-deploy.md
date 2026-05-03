# SOP — Chunked Multisig Deploy (desnet mainnet upgrade)

Operating procedure for upgrading the live `desnet` package on Aptos
mainnet via the 3/5 multisig at `@origin = 0x000073c4...`.

**Use this when**: source code changes are too large to fit in a single
`code::publish_package_txn` payload (typical Aptos cap ≈ 64 KB after BCS
overhead). Current desnet pkg is ~88 KB → 2 chunks.

**Use the simpler single-tx upgrade `governance::multisig_upgrade` when**:
total payload < ~50 KB. We outgrew that as of v0.3.x.

---

## Golden rule — SERIAL chunk flow

Wait until chunk_N's multisig execute lands AND the on-chain `UpgradeStaging`
resource is verified before proposing chunk_N+1. **Never propose chunk_N+1
back-to-back with chunk_N.**

Why: if chunk_N goes wrong (E_HASH_MISMATCH, accidental bad bytecode,
off-band signer disagreement), having chunk_N+1 already proposed creates a
recovery tangle — you'd need another multisig action to reject the stale
proposal. Serial keeps recovery surface small.

---

## Step 0 — Prerequisites

- 3/5 multisig owners ready to approve off-band (Telegram/Signal). For v0.4
  deploy this was: us (owner 5 = `final` profile = `0x0047a3e1...`) +
  owner 1 (`0x13f0c2ed...`) + owner 4 (`0xa1189e55...`).
- Geomi RPC API key for fast/throttle-free RPC (`aptoslabs_HQjT...` per
  feedback memory `feedback_geomi_rpc_endpoint.md`). Pass via
  `--node-api-key <key>` to every aptos CLI command.
- Owner 5 hot wallet APT balance ≥ ~0.5 APT (chunked deploy gas typically
  0.05-0.20 APT total but escrow validation requires generous max-gas budget).
- Working tree clean + tag the source commit (e.g., `v0.4-pre-deploy`).
- Tests GREEN locally (`aptos move test`).
- Self-audit / external audit panel results in hand.

## Step 1 — Build the deployment payload

```bash
cd /home/rera/desnet
aptos move build-publish-payload \
  --json-output-file .deploy/desnet_payload.json \
  --named-addresses \
desnet=0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724,origin=0x000073c4dd3fa51260b4cd8b6878191214df1e6dcd4dbcd1ed906c05c3aaa9a9,desnet_claimer=0x000073c4dd3fa51260b4cd8b6878191214df1e6dcd4dbcd1ed906c05c3aaa9a9 \
  --included-artifacts none \
  --override-size-check
```

Output reports `package size NNNNN bytes`. Note this — it's input to chunker.

## Step 2 — Chunk + compute digest

Use `.deploy/chunker_v04.py` (or successor for future versions). It:

1. Splits `code` array into chunks targeting 50 KB each (under 64 KB tx cap)
2. Computes `expected_digest = sha3-256(bcs(metadata) || bcs(code[0]) || ... || bcs(code[N-1]))`
3. Writes per-chunk JSON files to `.deploy/chunks_v04/`:
   - First N-1 chunks → `multisig_stage_upgrade_chunk` calls (no digest)
   - Final chunk → `multisig_publish_chunked_upgrade_with_digest` call (digest pinned in args[3])

**CRITICAL — BCS encoding for digest**

The on-chain `governance::compute_upgrade_digest` uses BCS, NOT raw bytes:

```move
let buf = bcs::to_bytes(metadata);   // ULEB128 length prefix + raw bytes
for each chunk: vector::append(&mut buf, bcs::to_bytes(chunk));
hash::sha3_256(buf)
```

Python equivalent:

```python
def uleb128(n):
    out = bytearray()
    while n > 0x7F:
        out.append((n & 0x7F) | 0x80)
        n >>= 7
    out.append(n)
    return bytes(out)

def bcs_vec_u8(b):
    return uleb128(len(b)) + b

hasher = hashlib.sha3_256()
hasher.update(bcs_vec_u8(metadata_bytes))
for cb in code_chunks_bytes:
    hasher.update(bcs_vec_u8(cb))
expected_digest = hasher.hexdigest()
```

Skipping the BCS prefix → digest mismatch → final-chunk multisig execute
aborts `E_HASH_MISMATCH=18`. R5 G5 hardening catches this before bad
bytecode publishes, but you waste 1 multisig cycle (~3 owner-clicks +
~0.16 APT gas).

**Cross-validate digest with on-chain view fn before any multisig action**:

```bash
# Tiny test vector — compare local Python vs on-chain
aptos move view \
  --function-id 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::governance::compute_upgrade_digest_view \
  --args hex:0x42 'hex:["0xAB"]' \
  --profile final --node-api-key <Geomi key>
# Should match local sha3(bcs(0x42) || bcs(0xAB)) = 0x3fc0f38f08f172ce452b636234796d8a1f68566b868f1e062373547c8aff60fe
```

## Step 3 — Phase 1: stage chunk_00 (and any intermediate chunks)

### 3a. Propose

```bash
aptos multisig create-transaction \
  --multisig-address 0x000073c4dd3fa51260b4cd8b6878191214df1e6dcd4dbcd1ed906c05c3aaa9a9 \
  --json-file .deploy/chunks_v04/chunk_00_multisig_stage_upgrade_chunk.json \
  --profile final \
  --node-api-key <Geomi key> \
  --max-gas 2000000 --gas-unit-price 100 \
  --assume-yes
```

Note the assigned multisig sequence number (look in returned tx events
or query `MultisigAccount.next_sequence_number - 1`).

### 3b. Off-band: collect 2 more approvals

Relay sequence number to other owners. Each runs:

```bash
aptos multisig approve \
  --multisig-address 0x000073c4dd3fa51260b4cd8b6878191214df1e6dcd4dbcd1ed906c05c3aaa9a9 \
  --sequence-number <N> \
  --profile <their_owner_profile>
```

Monitor vote count via:

```bash
aptos move view --function-id 0x1::multisig_account::get_pending_transactions \
  --args address:0x000073c4dd3fa51260b4cd8b6878191214df1e6dcd4dbcd1ed906c05c3aaa9a9 \
  --profile final --node-api-key <Geomi key>
# Look at votes.data — count value=true; need 3
```

### 3c. Execute

```bash
aptos multisig execute \
  --multisig-address 0x000073c4dd3fa51260b4cd8b6878191214df1e6dcd4dbcd1ed906c05c3aaa9a9 \
  --profile final \
  --node-api-key <Geomi key> \
  --max-gas 3000000 --gas-unit-price 100 \
  --assume-yes
```

If you see `INSUFFICIENT_BALANCE_FOR_TRANSACTION_FEE`, your `--max-gas ×
--gas-unit-price` exceeds your free balance. Drop max-gas (e.g., 40,000)
and retry. Actual usage typically 50-300 K gas, often net ≈ 0 after
storage refunds.

### 3d. Verify chunk_00 staged on chain

```bash
curl -s -H "Authorization: Bearer <Geomi key>" \
  "https://api.mainnet.aptoslabs.com/v1/accounts/0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724/resource/0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::governance::UpgradeStaging" \
  | python3 -c "import sys,json; d=json.load(sys.stdin)['data']; print('metadata=', len(d['metadata'])//2-1, 'B; code slots=', len(d['code']), '; sizes=', [(i, len(c)//2-1) for i,c in enumerate(d['code']) if c != '0x'])"
```

Sum the slot sizes — must match chunker's reported `code_size` for chunk_00 exactly.

## Step 4 — Phase 2: publish (chunk_N final, with digest)

Only after step 3d verifies clean.

```bash
aptos multisig create-transaction \
  --multisig-address 0x000073c4dd3fa51260b4cd8b6878191214df1e6dcd4dbcd1ed906c05c3aaa9a9 \
  --json-file .deploy/chunks_v04/chunk_NN_multisig_publish_chunked_upgrade_with_digest.json \
  --profile final \
  --node-api-key <Geomi key> \
  --max-gas 2000000 --gas-unit-price 100 \
  --assume-yes
```

Wait for 3/5 votes (off-band), then execute as in 3c.

## Step 5 — Verify upgrade landed

**CRITICAL gotcha**: outer `multisig execute` reports `success: true` even
if the inner publish aborted with E_HASH_MISMATCH or E_INCOMPLETE_CHUNKS.
Always check events:

```bash
curl -s -H "Authorization: Bearer <Geomi key>" \
  "https://api.mainnet.aptoslabs.com/v1/transactions/by_hash/<execute_tx_hash>" \
  | python3 -c "import sys,json; tx=json.load(sys.stdin); [print(e['type'], e.get('data', {})) for e in tx.get('events', [])]"
```

You want to see BOTH:
- `0x1::multisig_account::TransactionExecutionSucceeded`
- `<@desnet>::governance::MultisigUpgrade`

If you see `TransactionExecutionFailed` with `error_code: '18'` →
E_HASH_MISMATCH, fix digest in chunker and re-propose (the staged chunk
data is preserved across the abort because Move tx atomicity reverts the
`move_from` of UpgradeStaging).

If you see `error_code: '23'` → E_INCOMPLETE_CHUNKS, you missed an
intermediate chunk (out-of-order or wrong index list).

## Step 6 — Final verification

```bash
# 1. upgrade_number bumped
aptos move view --function-id 0x1::code::get_upgrade_number \
  --args address:0x7ba7ee5a... \
  --profile final --node-api-key <Geomi key>
# Should be one greater than before

# 2. UpgradeStaging consumed (no longer exists)
curl -s -H "Authorization: Bearer <Geomi key>" \
  ".../resource/...::governance::UpgradeStaging"
# Expect "data" key absent — resource is gone

# 3. New module entries available (smoke for the feature you added)
curl -s -H "Authorization: Bearer <Geomi key>" \
  ".../module/<new_module>"
# Verify abi.exposed_functions contains the new entry fns
```

## Reference: v0.4 mainnet deploy (2026-05-04)

| Phase | Tx hash | Result |
|---|---|---|
| chunk_00 propose | `0x4891f38d…` | multisig #27 created |
| chunk_00 execute | `0x55868b0a…` | UpgradeStaging populated, modules 0-10 |
| chunk_01 propose (BAD digest, no BCS) | `0xc8a383d2…` | multisig #28 created |
| chunk_01 execute (aborted E_HASH_MISMATCH) | `0x3ba1c3a3…` | TransactionExecutionFailed error_code=18 |
| chunk_01 propose (GOOD digest, BCS-correct) | `0x3cc39789…` | multisig #29 created |
| chunk_01 execute → PUBLISHED | `0x12f9c5d8…` | MultisigUpgrade event, upgrade_number 5→6 |

Total deploy gas owner 5: ~0.078 APT.

## Recovery scenarios

- **Wrong digest pinned (E_HASH_MISMATCH=18)**: Move tx atomicity preserves
  UpgradeStaging across the inner abort. Just fix the chunker, regenerate
  chunk_NN JSON, and propose a fresh multisig action (new sequence number).
- **Missed an intermediate chunk (E_INCOMPLETE_CHUNKS=23)**: figure out
  which slot is empty in UpgradeStaging, propose a `multisig_stage_upgrade_chunk`
  with that single missing chunk's index, then redo the publish.
- **Need to abandon the upgrade entirely**: propose
  `governance::cleanup_upgrade_staging` via 3/5 multisig — consumes the
  UpgradeStaging resource and emits `UpgradeStagingCleanup` event.
- **Wrong proposal stuck pending**: any owner can propose
  `multisig_account::vote_transaction(false)` to formally reject. With 3
  rejections, the proposal becomes ineligible to execute.

## Common pitfalls (the cost we already paid)

1. **Forgot BCS encoding on digest** → 1 wasted cycle, ~0.16 APT, R5 G5 saved us
2. **Confused `create_transaction` (full payload) vs `create_transaction_with_hash` (hash only)** — full payload uses more storage but other owners can re-validate the actual call args; hash-only is cheaper but requires off-band payload sharing. Use full payload for deploy txs.
3. **Anonymous RPC throttled during execute** — use Geomi `--node-api-key` for all CLI calls.
4. **Owner 5 hot wallet drained mid-deploy** — keep ≥ 1 APT buffer; if low, swap some creator-token back to APT before continuing.
5. **`outer success ≠ inner success`** for multisig execute → ALWAYS check events.
