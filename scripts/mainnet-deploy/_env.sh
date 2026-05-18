#!/usr/bin/env bash
# Shared env vars for mainnet deploy scripts. Source via: source _env.sh

set -euo pipefail

# Mainnet addresses (locked, committed in Move.toml at ed70fe8).
export ORIGIN_ADDR="0x000010b58aa6179cf0249e004ce452b870a503e850f248ca9e9b68e276cddead"
export DESNET_ADDR="0x8edc10f93d38bcf373f3f3f28890c0af13b9325e9dce4c9d37873e50dd316585"

# Vanity privkey (Ed25519 seed, 32 bytes). File contains a single line:
#   private_key = ed25519-priv-0x<64 hex>
# We extract the 64-hex part and prepend 0x for supra CLI.
export PRIVKEY_FILE="${HOME}/.deploy/vanity_aptos_cddead_supra.txt"
if [[ ! -f "$PRIVKEY_FILE" ]]; then
  echo "ERROR: vanity privkey file not found at $PRIVKEY_FILE" >&2
  exit 1
fi
export VANITY_PRIVKEY="0x$(grep -E '^private_key' "$PRIVKEY_FILE" | sed -E 's/.*ed25519-priv-0x([0-9a-fA-F]+).*/\1/')"
if [[ ! "$VANITY_PRIVKEY" =~ ^0x[0-9a-fA-F]{64}$ ]]; then
  echo "ERROR: could not extract a valid Ed25519 seed from $PRIVKEY_FILE" >&2
  exit 1
fi

# Hot wallet (one of the 4 multisig owners; pays gas for some helper txs).
export HOTWALLET="0x0047a3e13465172e10661e20b7b618235e9c7e62a365d315e91cf1ef647321c9"

# Multisig target (after conversion). 5 owners, 1/5 initial then 3/5 post-smoke.
# Owner #5 (0xc257b12e) added 2026-05-18 after user confirmed it's a raw-key
# Supra-signing-capable wallet (not Petra social login).
export MULTISIG_OWNERS_VEC='["0x85d1e4047bde5c02b1915e5677b44ff5a6ba13452184d794da4658a4814efd30","0x0047a3e13465172e10661e20b7b618235e9c7e62a365d315e91cf1ef647321c9","0x85c7ab96a2da5eef66292422b2468f3c24cb26e10012831f6bba1ec7d3061197","0x1a502d8938a8839b89cc2c553e00dba2e6574184f7c7883b27d9e7a6e17f59a7","0xc257b12ef33cc0d221be8eecfe92c12fda8d886af8229b9bc4d59a518fa0b093"]'
export THRESHOLD_INITIAL=1
export THRESHOLD_FINAL=3

# Supra mainnet RPC. supra CLI v0.5.0 expects the bare host (no /rpc/vX path).
export RPC_URL="https://rpc-mainnet.supra.com"
export CHAIN_ID=8

# Gas params. Supra mainnet floor = 100_000 gasUnitPrice (see memory
# feedback_supra_gas_price_floor_100k). Submit-time validation requires
# max_gas * gas_price <= sender_balance (HOLD, refunded after exec).
# publish_chunked runs 21 modules' init_module + bytecode link verification —
# needs the headroom. Typical actual usage ~100K-500K gas units.
# publish_chunked hold: 1_000_000 * 100K = 1e11 quants = 100 SUPRA.
# stage_chunk hold:       100_000 * 100K = 1e10 quants =  10 SUPRA.
export GAS_UNIT_PRICE=100000
export MAX_GAS_PUBLISH=1000000
export MAX_GAS_ENTRY=100000

# Package directories.
export BOOTSTRAP_PKG_DIR="${HOME}/desnet-bootstrap-supra"
export DESNET_PKG_DIR="${HOME}/desnet-supra"

# Named addresses passed to compiler. Must match both Move.toml files.
export NAMED_ADDRESSES="origin=${ORIGIN_ADDR},desnet=${DESNET_ADDR}"

# Sanity print.
if [[ "${1:-}" == "--show" ]]; then
  echo "ORIGIN_ADDR      = $ORIGIN_ADDR"
  echo "DESNET_ADDR      = $DESNET_ADDR"
  echo "HOTWALLET        = $HOTWALLET"
  echo "RPC_URL          = $RPC_URL"
  echo "VANITY_PRIVKEY   = (loaded, ${#VANITY_PRIVKEY} chars)"
  echo "BOOTSTRAP_PKG    = $BOOTSTRAP_PKG_DIR"
  echo "DESNET_PKG       = $DESNET_PKG_DIR"
fi
