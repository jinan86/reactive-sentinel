#!/usr/bin/env bash
# Resume of deploy.sh after a runtime restart interrupted Step 2.
# Steps 0-1 already done: faucet 0.04 ETH -> 4 lREACT, emitter deployed.
# This script runs Steps 2-5 only. Testnet only.
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

EMITTER=$(python3 -c "import json;print(json.load(open('deployments/emitter.json'))['emitter'])")
echo "Emitter (already deployed): $EMITTER"

echo "=== Step 2: deploy PingReactive (Lasna) ==="
EMITTER_ADDRESS="$EMITTER" forge script script/DeployLasna.s.sol --rpc-url "$LASNA_RPC" --private-key "$PK" --broadcast
REACTIVE=$(python3 -c "import json;print(json.load(open('deployments/lasna.json'))['reactive'])")
echo "Reactive: $REACTIVE"
echo -n "Reactive on-chain code check: "
cast code "$REACTIVE" --rpc-url "$LASNA_RPC" | wc -c

echo "=== Step 3: deploy Pong (Base Sepolia) ==="
PONG_FUND=0.002ether REACTIVE_ADDRESS="$REACTIVE" forge script script/DeployPong.s.sol --rpc-url "$BASE_RPC" --private-key "$PK" --broadcast
PONG=$(python3 -c "import json;print(json.load(open('deployments/pong.json'))['pong'])")
echo "Pong: $PONG"

echo "=== Step 4: wire destination (Lasna) ==="
REACTIVE_ADDRESS="$REACTIVE" PONG_ADDRESS="$PONG" forge script script/WireUp.s.sol --rpc-url "$LASNA_RPC" --private-key "$PK" --broadcast

echo "=== Step 5: ping + poll for the live loop ==="
PING_TX=$(cast send "$EMITTER" "ping(uint256)" 777 --rpc-url "$BASE_RPC" --private-key "$PK" --json | python3 -c "import json,sys;print(json.load(sys.stdin).get('transactionHash'))")
echo "Ping tx: $PING_TX (https://sepolia.basescan.org/tx/$PING_TX)"
echo "Waiting for Reactive nodes to deliver react() + callback (up to 10 min)..."
for i in $(seq 1 20); do
  sleep 30
  REACTS=$(cast call "$REACTIVE" "reactCount()(uint256)" --rpc-url "$LASNA_RPC" 2>/dev/null || echo 0)
  PONGS=$(cast call "$PONG" "count()(uint256)" --rpc-url "$BASE_RPC" 2>/dev/null || echo 0)
  echo "  [$((i * 30))s] reactCount=$REACTS pongCount=$PONGS"
  if [ "$REACTS" -ge 1 ] && [ "$PONGS" -ge 1 ]; then
    echo "LOOP PROVEN: ping -> react() on Lasna -> callback to Pong on Base Sepolia."
    echo "  emitter=$EMITTER reactive=$REACTIVE pong=$PONG pingTx=$PING_TX"
    exit 0
  fi
done
echo "Loop NOT confirmed within 10 min. Check Reactscan for the reactive tx:"
echo "  https://lasna.reactscan.net/address/$REACTIVE"
echo "and the pong count above. Nodes can lag; re-poll manually."
exit 2
