#!/usr/bin/env bash
# Pre-flight checks before mainnet deploy. Idempotent + read-only.

source "$(dirname "$0")/_env.sh"

echo "==[ 00-check ]==========================================="
echo "Pattern A.2 (Aptos-mirror exact)"
echo

bal_raw=$(supra move account balance \
  --account-address "$ORIGIN_ADDR" \
  --rpc-url "$RPC_URL" 2>&1 | grep -oE '"value": "[0-9]+"' | grep -oE '[0-9]+')

if [[ -z "$bal_raw" ]]; then
  echo "FAIL: could not parse @origin balance"
  echo "  (account may not exist on Supra mainnet yet)"
  echo "  fund @origin = $ORIGIN_ADDR with ~3 SUPRA from $HOTWALLET first"
  exit 1
fi
bal_supra=$(awk "BEGIN { printf \"%.4f\", $bal_raw / 100000000 }")
echo "@origin balance       : $bal_supra SUPRA ($bal_raw raw)"
if (( bal_raw < 100000000 )); then
  echo "WARN: balance < 1 SUPRA; chunked publish may exhaust gas"
fi

if supra move account balance \
  --account-address "$DESNET_ADDR" \
  --rpc-url "$RPC_URL" 2>&1 | grep -q '"value"'; then
  echo "@desnet               : already exists (cancel: deploy already done?)"
  exit 1
else
  echo "@desnet               : not yet on chain (expected pre-deploy)"
fi

echo
cd "$DESNET_PKG_DIR"
ver_desnet=$(grep '^version' Move.toml | head -1 | sed -E 's/.*"(.*)".*/\1/')
echo "Desnet Move.toml ver  : $ver_desnet"
cd "$BOOTSTRAP_PKG_DIR"
ver_bs=$(grep '^version' Move.toml | head -1 | sed -E 's/.*"(.*)".*/\1/')
echo "Bootstrap Move.toml v : $ver_bs"

echo
echo "Run tests once more before deploy?"
echo "  (y/n) >> "
read -r ans
if [[ "${ans,,}" == "y" ]]; then
  cd "$DESNET_PKG_DIR"
  if supra move tool test --dev --ignore-compile-warnings 2>&1 | grep -E 'Test result|^Total' | tail -2; then
    echo "OK: tests pass"
  else
    echo "FAIL: tests broken — abort"
    exit 1
  fi
fi

echo
echo "==[ 00-check OK — ready for 01-publish-bootstrap.sh ]====="
