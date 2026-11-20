#!/usr/bin/env bash
# Sentinel Phase 2 deploy — DemoVault + VerdictOracle + SentinelReactive +
# VaultGuard (testnet only).
#
# Order: A (Base Sepolia: token/vault/oracle + seed 1000 tUSD)
#     -> B (Lasna: SentinelReactive + 0.5 lREACT)
#     -> C (Base Sepolia: VaultGuard + 0.001 ETH)
#     -> wire (reactive.setDestination + vault.setGuard) via cast
#     -> verify state, print addresses.
set -euo pipefail
cd "$(dirname "$0")"

export PATH="$HOME/.foundry/bin:$PATH"
BASE_RPC="https://sepolia.base.org"
LASNA_RPC="https://lasna-rpc.rnk.dev/"

WALLET_JSON=".wallet.json"
[ -f "$WALLET_JSON" ] || { echo "ERROR: $WALLET_JSON not found"; exit 1; }
PK=$(python3 -c "import json;print(json.load(open('$WALLET_JSON'))['data'][0]['private_key'])")
ADDR=$(python3 -c "import json;print(json.load(open('$WALLET_JSON'))['data'][0]['address'])")
echo "Deployer: $ADDR"
echo "Base Sepolia balance: $(cast to-unit "$(cast balance "$ADDR" --rpc-url "$BASE_RPC")" ether) ETH"
echo "Lasna balance: $(cast to-unit "$(cast balance "$ADDR" --rpc-url "$LASNA_RPC")" ether) lREACT"

echo "=== Step A: deploy vault stack (Base Sepolia) ==="
forge script script/DeployPhase2Base.s.sol --rpc-url "$BASE_RPC" --private-key "$PK" --broadcast
TOKEN=$(python3 -c "import json;print(json.load(open('deployments/phase2-base.json'))['token'])")
VAULT=$(python3 -c "import json;print(json.load(open('deployments/phase2-base.json'))['vault'])")
ORACLE=$(python3 -c "import json;print(json.load(open('deployments/phase2-base.json'))['oracle'])")
echo "Token: $TOKEN  Vault: $VAULT  Oracle: $ORACLE"

echo "=== Step B: deploy SentinelReactive (Lasna) ==="
ORACLE_ADDRESS="$ORACLE" forge script script/DeployPhase2Lasna.s.sol --rpc-url "$LASNA_RPC" --private-key "$PK" --broadcast
REACTIVE=$(python3 -c "import json;print(json.load(open('deployments/phase2-lasna.json'))['reactive'])")
echo "Reactive: $REACTIVE"
echo -n "Reactive on-chain code check: "
cast code "$REACTIVE" --rpc-url "$LASNA_RPC" | wc -c

echo "=== Step C: deploy VaultGuard (Base Sepolia) ==="
REACTIVE_ADDRESS="$REACTIVE" forge script script/DeployPhase2Guard.s.sol --rpc-url "$BASE_RPC" --private-key "$PK" --broadcast
GUARD=$(python3 -c "import json;print(json.load(open('deployments/phase2-guard.json'))['guard'])")
echo "Guard: $GUARD"

echo "=== Wire up ==="
echo "-- reactive.setDestination(guard) on Lasna"
cast send "$REACTIVE" "setDestination(address)" "$GUARD" --rpc-url "$LASNA_RPC" --private-key "$PK" --json | python3 -c "import json,sys;print(' tx:',json.load(sys.stdin).get('transactionHash'))"
echo "-- vault.setGuard(guard) on Base Sepolia"
cast send "$VAULT" "setGuard(address)" "$GUARD" --rpc-url "$BASE_RPC" --private-key "$PK" --json | python3 -c "import json,sys;print(' tx:',json.load(sys.stdin).get('transactionHash'))"

echo "=== Verify ==="
echo "reactive.destination: $(cast call "$REACTIVE" "destination()(address)" --rpc-url "$LASNA_RPC")"
echo "vault.guard: $(cast call "$VAULT" "guard()(address)" --rpc-url "$BASE_RPC")"
echo "vault.safeVault: $(cast call "$VAULT" "safeVault()(address)" --rpc-url "$BASE_RPC")"
echo "vault TVL (tUSD): $(cast call "$TOKEN" "balanceOf(address)(uint256)" "$VAULT" --rpc-url "$BASE_RPC" | awk '{print $1}' | xargs -I{} cast to-unit {} ether)"
echo "reactive balance: $(cast to-unit "$(cast balance "$REACTIVE" --rpc-url "$LASNA_RPC")" ether) lREACT"
echo "guard balance: $(cast to-unit "$(cast balance "$GUARD" --rpc-url "$BASE_RPC")" ether) ETH"
echo
echo "Phase 2 deployed:"
echo "  token=$TOKEN vault=$VAULT oracle=$ORACLE"
echo "  reactive=$REACTIVE guard=$GUARD"
echo "Next: run the end-to-end demo — see demo-attack.sh"
