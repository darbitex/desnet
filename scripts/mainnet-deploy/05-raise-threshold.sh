#!/usr/bin/env bash
# Raise multisig threshold from 1/4 -> 3/4 via Supra multisig propose+execute.
#
# Since current threshold = 1, ANY one of 4 owners can propose+execute
# unilaterally. We use the hot wallet (0x0047) as the proposer; signs via its
# own privkey (not the vanity, which is dead post-conversion).
#
# Requires HOTWALLET_PRIVKEY env var set (or ~/.deploy/hot_0047_seller.txt parsed).
#
# Flow:
#  1. propose_transaction on @origin with payload = update_signatures_required(3)
#  2. (threshold=1, no other votes needed) → propose triggers immediate execute
#  OR
#  1. create_transaction_with_hash + first owner's vote happens automatically
#  2. execute_transaction (single-tx if threshold satisfied)

source "$(dirname "$0")/_env.sh"

# Pull hot wallet privkey. Mirror of vanity privkey extraction.
HOT_PRIVKEY_FILE="${HOME}/.deploy/hot_0047_seller.txt"
if [[ ! -f "$HOT_PRIVKEY_FILE" ]]; then
  echo "ERROR: hot wallet privkey not found at $HOT_PRIVKEY_FILE" >&2
  echo "Need privkey for $HOTWALLET to propose+execute the threshold raise" >&2
  exit 1
fi
HOTWALLET_PRIVKEY="0x$(grep -E '^private_key' "$HOT_PRIVKEY_FILE" | sed -E 's/.*ed25519-priv-0x([0-9a-fA-F]+).*/\1/')"
if [[ ! "$HOTWALLET_PRIVKEY" =~ ^0x[0-9a-fA-F]{64}$ ]]; then
  echo "ERROR: could not extract Ed25519 seed from $HOT_PRIVKEY_FILE" >&2
  exit 1
fi

echo "==[ 05-raise-threshold ]=================================="
echo "Multisig: $ORIGIN_ADDR"
echo "Proposer: $HOTWALLET (one of 4 owners)"
echo "Target  : update_signatures_required($THRESHOLD_FINAL) (was $THRESHOLD_INITIAL)"
echo

echo "Read current threshold..."
supra move tool view \
  --function-id "0x1::multisig_account::num_signatures_required" \
  --args "address:$ORIGIN_ADDR" \
  --rpc-url "$RPC_URL" 2>&1 | head -5

echo
read -p "Submit threshold-raise propose+execute? (y/n) >> " ans
[[ "${ans,,}" != "y" ]] && { echo "aborted"; exit 0; }

# The cleanest path: use create_transaction (which packages the payload + first
# vote) since the threshold is 1, this single tx will mark the proposal
# approved. Then call execute_transaction with the same proposer.
#
# Alternatively (one fewer tx): use the "shortcut" propose_and_vote pattern if
# multisig_account exposes it. Falling back to create+execute here.

echo
echo "Step 1: create_transaction (proposer=$HOTWALLET, payload=update_signatures_required(3))..."

# Build the BCS-encoded entry function payload for update_signatures_required.
# Easier path: use multisig_account::create_transaction with raw payload bytes.
# We construct the payload via the supra CLI's build helper indirectly.
#
# Hack: use the high-level helper if supra fwk exposes one. If not, we have to
# hand-build BCS for the EntryFunctionPayload.

# For now, defer to the actual deployer to drive this step interactively given
# multisig-payload-builder is a non-trivial helper that lives in our anomaly
# frontend code (chain/multisig-payload-builders.ts). If you have that wired,
# call it. Otherwise:

cat <<EOF
DEFERRED INTERACTIVE STEP:

The standard pattern requires building a BCS-encoded EntryFunctionPayload for
update_signatures_required(3) and passing it as bytes to multisig_account::
create_transaction.

Two options:
  (a) Use anomaly frontend's multisig manager UI:
      https://anomaly.wal.app/multisig/{ORIGIN_ADDR}
      → Propose → "Raise threshold to 3" → execute.

  (b) Use supra CLI propose_transaction directly with hex payload.
      Need to BCS-encode:
        EntryFunctionPayload {
          module_address: 0x1,
          module_name: "multisig_account",
          function_name: "update_signatures_required",
          ty_args: [],
          args: [bcs::to_bytes(3_u64)],
        }
      Then run:
        supra move tool run \\
          --function-id 0x1::multisig_account::create_transaction \\
          --args address:$ORIGIN_ADDR hex:<bcs_payload_hex> \\
          --private-key \$HOTWALLET_PRIVKEY --sender-account $HOTWALLET \\
          --rpc-url $RPC_URL --max-gas $MAX_GAS_ENTRY --gas-unit-price $GAS_PRICE

      With threshold=1, this tx triggers immediate execute internally.

Pick (a) if frontend is live; (b) for CLI-only paths.
EOF
