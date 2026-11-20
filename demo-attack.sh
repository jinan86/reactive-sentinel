#!/usr/bin/env bash
# Sentinel end-to-end demo (testnet only).
#
# Scenario 1 (benign): withdraw 50 tUSD (5% of TVL) -> AI scores 10, action
#   NONE -> reactive sees the verdict but takes no action, vault stays open.
# Scenario 2 (attack): withdraw 700 tUSD (~74% of remaining TVL) ->
#   LargeWithdrawal -> AI scores 85, action RESCUE -> reactive requests a
#   callback -> VaultGuard freezes the vault and rescues the remaining
#   funds to the safe vault (the deployer wallet, demo only).
#
# Prints every tx hash + the final on-chain state. Requires the AI service
# (ai-service/sentinel_agent.py) and the Phase 2 deployment.
set -euo pipefail
cd "$(dirname "$0")"

export PATH="$HOME/.foundry/bin:$PATH"
BASE_RPC="https://sepolia.base.org"
LASNA_RPC="https://lasna-rpc.rnk.dev/"

WALLET_JSON=".wallet.json"
PK=$(python3 -c "import json;print(json.load(open('$WALLET_JSON'))['data'][0]['private_key'])")
ADDR=$(python3 -c "import json;print(json.load(open('$WALLET_JSON'))['data'][0]['address'])")
TOKEN=$(python3 -c "import json;print(json.load(open('deployments/phase2-base.json'))['token'])")
VAULT=$(python3 -c "import json;print(json.load(open('deployments/phase2-base.json'))['vault'])")
ORACLE=$(python3 -c "import json;print(json.load(open('deployments/phase2-base.json'))['oracle'])")
REACTIVE=$(python3 -c "import json;print(json.load(open('deployments/phase2-lasna.json'))['reactive'])")
GUARD=$(python3 -c "import json;print(json.load(open('deployments/phase2-guard.json'))['guard'])")

echo "Vault: $VAULT  Oracle: $ORACLE  Reactive: $REACTIVE  Guard: $GUARD"
echo "TVL before: $(cast call "$TOKEN" "balanceOf(address)(uint256)" "$VAULT" --rpc-url "$BASE_RPC" | awk '{print $1}' | xargs -I{} cast to-unit {} ether) tUSD"
echo "Vault frozen before: $(cast call "$VAULT" "frozen()(bool)" --rpc-url "$BASE_RPC")"

# Scan from a bit before the vault deployment so the seed Deposit is scored too.
FROM_BLOCK=$(($(cast block-number --rpc-url "$BASE_RPC") - 3000))
export BASE_RPC VAULT_ADDRESS="$VAULT" ORACLE_ADDRESS="$ORACLE" WALLET_FILE="$PWD/$WALLET_JSON"

run_agent() {
  echo "--- AI service: scoring new vault events (from block $FROM_BLOCK) ---"
  python3 ai-service/sentinel_agent.py --once --from-block "$FROM_BLOCK"
  FROM_BLOCK=$(python3 -c "import json;print(json.load(open('ai-service/state.json'))['last_block'] + 1)")
}

echo
echo "=== Scenario 1: benign withdrawal 50 tUSD (5%) ==="
cast send "$VAULT" "withdraw(uint256)" 50000000000000000000 --rpc-url "$BASE_RPC" --private-key "$PK" --json | python3 -c "import json,sys;print('withdraw tx:',json.load(sys.stdin).get('transactionHash'))"
run_agent
echo "oracle verdictCount: $(cast call "$ORACLE" "verdictCount()(uint256)" --rpc-url "$BASE_RPC")"
echo "reactive reactCount: $(cast call "$REACTIVE" "reactCount()(uint256)" --rpc-url "$LASNA_RPC") actedCount: $(cast call "$REACTIVE" "actedCount()(uint256)" --rpc-url "$LASNA_RPC")"
echo "vault frozen: $(cast call "$VAULT" "frozen()(bool)" --rpc-url "$BASE_RPC")"
echo "TVL now: $(cast call "$TOKEN" "balanceOf(address)(uint256)" "$VAULT" --rpc-url "$BASE_RPC" | awk '{print $1}' | xargs -I{} cast to-unit {} ether) tUSD"

echo
echo "=== Scenario 2: ATTACK — withdraw 700 tUSD (~74% of remaining TVL) ==="
cast send "$VAULT" "withdraw(uint256)" 700000000000000000000 --rpc-url "$BASE_RPC" --private-key "$PK" --json | python3 -c "import json,sys;print('attack tx:',json.load(sys.stdin).get('transactionHash'))"
run_agent
echo "oracle verdictCount: $(cast call "$ORACLE" "verdictCount()(uint256)" --rpc-url "$BASE_RPC")"
echo "latest decision (ai-service/decisions.jsonl):"
tail -1 ai-service/decisions.jsonl | python3 -m json.tool | head -25
echo "Waiting for react() + callback (up to 5 min)..."
for i in $(seq 1 10); do
  sleep 30
  RC=$(cast call "$REACTIVE" "reactCount()(uint256)" --rpc-url "$LASNA_RPC" 2>/dev/null || echo 0)
  AC=$(cast call "$REACTIVE" "actedCount()(uint256)" --rpc-url "$LASNA_RPC" 2>/dev/null || echo 0)
  FROZEN=$(cast call "$VAULT" "frozen()(bool)" --rpc-url "$BASE_RPC" 2>/dev/null || echo false)
  echo "  [$((i * 30))s] reactCount=$RC actedCount=$AC frozen=$FROZEN"
  if [ "$AC" -ge 1 ] && [ "$FROZEN" = "true" ]; then
    break
  fi
done

echo
echo "=== Final state ==="
echo "vault frozen: $(cast call "$VAULT" "frozen()(bool)" --rpc-url "$BASE_RPC")"
echo "vault TVL: $(cast call "$TOKEN" "balanceOf(address)(uint256)" "$VAULT" --rpc-url "$BASE_RPC" | awk '{print $1}' | xargs -I{} cast to-unit {} ether) tUSD"
echo "safeVault (deployer) tUSD: $(cast call "$TOKEN" "balanceOf(address)(uint256)" "$ADDR" --rpc-url "$BASE_RPC" | awk '{print $1}' | xargs -I{} cast to-unit {} ether)"
echo "reactive reactCount: $(cast call "$REACTIVE" "reactCount()(uint256)" --rpc-url "$LASNA_RPC") actedCount: $(cast call "$REACTIVE" "actedCount()(uint256)" --rpc-url "$LASNA_RPC") lastRiskScore: $(cast call "$REACTIVE" "lastRiskScore()(uint256)" --rpc-url "$LASNA_RPC") lastAction: $(cast call "$REACTIVE" "lastAction()(uint8)" --rpc-url "$LASNA_RPC")"
echo "reactive balance: $(cast to-unit "$(cast balance "$REACTIVE" --rpc-url "$LASNA_RPC")" ether) lREACT"
echo "guard balance: $(cast to-unit "$(cast balance "$GUARD" --rpc-url "$BASE_RPC")" ether) ETH"
echo "decisions log: ai-service/decisions.jsonl"
