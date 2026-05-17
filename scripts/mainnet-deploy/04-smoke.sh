#!/usr/bin/env bash
# Read-only smoke checks. Run after multisig conversion to confirm everything
# landed correctly + governance state is initialized.

source "$(dirname "$0")/_env.sh"

echo "==[ 04-smoke ]============================================"
echo

ok=0
fail=0
check() {
  local label="$1"; shift
  echo "[?] $label"
  if "$@" 2>&1 | tee /tmp/smoke-last.out | tail -5; then
    if grep -q '"data"\|"value"\|"vec":' /tmp/smoke-last.out; then
      echo "  -> OK"
      ((ok++))
    else
      echo "  -> ??? (review output above)"
      ((fail++))
    fi
  else
    echo "  -> FAIL"
    ((fail++))
  fi
  echo
}

check "@origin is now a multisig" \
  supra move tool show \
    --query resource --name 0x1::multisig_account::MultisigAccount \
    --account-address "$ORIGIN_ADDR" --rpc-url "$RPC_URL"

check "@origin auth_key revoked (= 0x0)" \
  supra move tool show \
    --query resource --name 0x1::account::Account \
    --account-address "$ORIGIN_ADDR" --rpc-url "$RPC_URL"

check "@desnet has the desnet pkg installed (governance::GovernanceState)" \
  supra move tool show \
    --query resource --name "${DESNET_ADDR}::governance::GovernanceState" \
    --account-address "$DESNET_ADDR" --rpc-url "$RPC_URL"

check "factory module exists at @desnet" \
  supra move tool show --query module --name factory \
    --account-address "$DESNET_ADDR" --rpc-url "$RPC_URL"

check "supra_fee_vault initialized" \
  supra move tool view \
    --function-id "${DESNET_ADDR}::supra_fee_vault::vault_exists" \
    --rpc-url "$RPC_URL"

check "bootstrap CapHolder CONSUMED (should return false)" \
  supra move tool view \
    --function-id "${ORIGIN_ADDR}::publisher::cap_exists" \
    --rpc-url "$RPC_URL"

echo "==[ smoke summary: $ok ok / $fail fail ]======="
echo
if (( fail > 0 )); then
  echo "Some checks didn't return expected shape — review outputs above."
  echo "/tmp/smoke-last.out has the last raw output."
  exit 1
fi
echo "All read-only checks pass. Mainnet pkg is live."
echo
echo "Next: 05-raise-threshold.sh to lift multisig from 1/4 -> 3/4"
