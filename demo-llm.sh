#!/usr/bin/env bash
# Sentinel end-to-end demo WITH LLM in the loop (testnet only).
#
# Same two scenarios as demo-attack.sh, but the AI service scores every
# event through the 100milionseek LLM (deepseek-v4.1-flash-free via the
# Secure Vault surrogate -- no literal key anywhere). Heuristic is the
# fallback only; every decision records which layer decided.
#
# Pre-steps (vault is FROZEN from the previous demo): unfreeze() +
# re-seed 1000 tUSD from the deployer wallet.
#
# Prints every tx hash + the final on-chain state. Logs to demo-llm-run.log.
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

# LLM via 100milionseek proxy (OpenAI-compatible). Key reaches the agent
# only as a Secure Vault surrogate -- never as a literal value.
export LLM_API_URL="https://100milionseek.top/v1/chat/completions"
export LLM_MODEL="deepseek-v4.1-flash-free"
export LLM_USE_SURROGATE=1

echo "Vault: $VAULT  Oracle: $ORACLE  Reactive: $REACTIVE  Guard: $GUARD"
echo "LLM: $LLM_MODEL via $LLM_API_URL (surrogate auth)"

VERDICTS_BEFORE=$(cast call "$ORACLE" "verdictCount()(uint256)" --rpc-url "$BASE_RPC")
REACT_BEFORE=$(cast call "$REACTIVE" "reactCount()(uint256)" --rpc-url "$LASNA_RPC")
ACTED_BEFORE=$(cast call "$REACTIVE" "actedCount()(uint256)" --rpc-url "$LASNA_RPC")
echo "Baselines: verdictCount=$VERDICTS_BEFORE reactCount=$REACT_BEFORE actedCount=$ACTED_BEFORE"
echo "Vault frozen before: $(cast call "$VAULT" "frozen()(bool)" --rpc-url "$BASE_RPC")"

echo
echo "=== Step 0: unfreeze + re-seed 1000 tUSD ==="
cast send "$VAULT" "unfreeze()" --rpc-url "$BASE_RPC" --private-key "$PK" --json | python3 -c "import json,sys;print('unfreeze tx:',json.load(sys.stdin).get('transactionHash'))"
cast send "$TOKEN" "approve(address,uint256)" "$VAULT" 1000000000000000000000 --rpc-url "$BASE_RPC" --private-key "$PK" --json | python3 -c "import json,sys;print('approve tx:',json.load(sys.stdin).get('transactionHash'))"
cast send "$VAULT" "deposit(uint256)" 1000000000000000000000 --rpc-url "$BASE_RPC" --private-key "$PK" --json | python3 -c "import json,sys;print('seed deposit tx:',json.load(sys.stdin).get('transactionHash'))"
echo "TVL after seed: $(cast call "$TOKEN" "balanceOf(address)(uint256)" "$VAULT" --rpc-url "$BASE_RPC" | awk '{print $1}' | xargs -I{} cast to-unit {} ether) tUSD"
echo "Vault frozen after unfreeze: $(cast call "$VAULT" "frozen()(bool)" --rpc-url "$BASE_RPC")"

export BASE_RPC VAULT_ADDRESS="$VAULT" ORACLE_ADDRESS="$ORACLE" WALLET_FILE="$PWD/$WALLET_JSON"

run_agent() {
  echo "--- AI service (LLM) : scoring new vault events ---"
  python3 ai-service/sentinel_agent.py --once
  echo "latest decisions:"
  tail -2 ai-service/decisions.jsonl | python3 -c "import json,sys
for line in sys.stdin:
    d = json.loads(line)
    print(f\"  {d['event']} block {d['block']}: score {d['final_score']} {d['final_action']} layer={d['llm']['layer']} llm={d['llm'].get('llm')} reasons={d.get('final_reasons')}\")"
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
echo "Waiting for react() + callback (up to 10 min; need actedCount > $ACTED_BEFORE and frozen=true)..."
for i in $(seq 1 20); do
  sleep 30
  RC=$(cast call "$REACTIVE" "reactCount()(uint256)" --rpc-url "$LASNA_RPC" 2>/dev/null || echo 0)
  AC=$(cast call "$REACTIVE" "actedCount()(uint256)" --rpc-url "$LASNA_RPC" 2>/dev/null || echo 0)
  FROZEN=$(cast call "$VAULT" "frozen()(bool)" --rpc-url "$BASE_RPC" 2>/dev/null || echo false)
  echo "  [$((i * 30))s] reactCount=$RC actedCount=$AC frozen=$FROZEN"
  if [ "$AC" -gt "$ACTED_BEFORE" ] && [ "$FROZEN" = "true" ]; then
    break
  fi
done

echo
echo "=== Final state ==="
echo "vault frozen: $(cast call "$VAULT" "frozen()(bool)" --rpc-url "$BASE_RPC")"
echo "vault TVL: $(cast call "$TOKEN" "balanceOf(address)(uint256)" "$VAULT" --rpc-url "$BASE_RPC" | awk '{print $1}' | xargs -I{} cast to-unit {} ether) tUSD"
echo "safeVault (deployer) tUSD: $(cast call "$TOKEN" "balanceOf(address)(uint256)" "$ADDR" --rpc-url "$BASE_RPC" | awk '{print $1}' | xargs -I{} cast to-unit {} ether)"
echo "oracle verdictCount: $(cast call "$ORACLE" "verdictCount()(uint256)" --rpc-url "$BASE_RPC")"
echo "reactive reactCount: $(cast call "$REACTIVE" "reactCount()(uint256)" --rpc-url "$LASNA_RPC") actedCount: $(cast call "$REACTIVE" "actedCount()(uint256)" --rpc-url "$LASNA_RPC") lastRiskScore: $(cast call "$REACTIVE" "lastRiskScore()(uint256)" --rpc-url "$LASNA_RPC") lastAction: $(cast call "$REACTIVE" "lastAction()(uint8)" --rpc-url "$LASNA_RPC")"
echo "reactive balance: $(cast to-unit "$(cast balance "$REACTIVE" --rpc-url "$LASNA_RPC")" ether) lREACT"
echo "guard balance: $(cast to-unit "$(cast balance "$GUARD" --rpc-url "$BASE_RPC")" ether) ETH"
echo "decisions log: ai-service/decisions.jsonl"
