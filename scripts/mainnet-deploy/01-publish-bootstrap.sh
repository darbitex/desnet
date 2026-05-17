#!/usr/bin/env bash
# Publish the bootstrap pkg at @origin. Single-tx publish (small pkg).
# This is signed by the vanity privkey (still alive at this point).
#
# Outcome:
#   - DesnetBootstrap pkg installed at @origin
#   - init_module fires: creates resource_account at @desnet via
#     account::create_resource_account(@origin_signer, b"desnet")
#   - SignerCap for @desnet stored in CapHolder at @origin

source "$(dirname "$0")/_env.sh"

echo "==[ 01-publish-bootstrap ]================================"
echo "Publishing $BOOTSTRAP_PKG_DIR -> @origin = $ORIGIN_ADDR"
echo "Named addresses: $NAMED_ADDRESSES"
echo

read -p "Proceed? (y/n) >> " ans
[[ "${ans,,}" != "y" ]] && { echo "aborted"; exit 0; }

cd "$BOOTSTRAP_PKG_DIR"

supra move tool publish \
  --package-dir "$BOOTSTRAP_PKG_DIR" \
  --named-addresses "$NAMED_ADDRESSES" \
  --private-key "$VANITY_PRIVKEY" \
  --sender-account "$ORIGIN_ADDR" \
  --url "$RPC_URL" \
  --max-gas "$MAX_GAS_PUBLISH" \
  --gas-unit-price "$GAS_UNIT_PRICE" \
  --included-artifacts none \
  --skip-fetch-latest-git-deps \
  --assume-yes 2>&1 | tee /tmp/01-publish-bootstrap.log

echo
echo "==[ verify on-chain ]====================================="
echo "Checking CapHolder at @origin..."
sleep 5
supra move tool view \
  --function-id "${ORIGIN_ADDR}::publisher::cap_exists" \
  --rpc-url "$RPC_URL" 2>&1 | head -10

echo
echo "Checking @desnet exists as resource account..."
supra move account balance \
  --account-address "$DESNET_ADDR" \
  --rpc-url "$RPC_URL" 2>&1 | head -5

echo
echo "==[ 01-publish-bootstrap done — next: 02-publish-desnet-chunked.py ]=="
