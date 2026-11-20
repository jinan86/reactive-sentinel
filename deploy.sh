#!/usr/bin/env bash
# Sentinel hello-world loop — full deploy + live proof (testnet only).
#
# Order: emitter (Base Sepolia) -> reactive (Lasna) -> pong (Base Sepolia)
#        -> wire up -> ping -> poll for react() + callback.
#
# Prerequisites: Sepolia ETH in the project wallet (see FUNDING.md).
# The private key is read from .wallet.json (mode 600) and NEVER printed.
set -euo pipefail
cd "$(dirname "$0")"

export PATH="$HOME/.foundry/bin:$PATH"
BASE_RPC="https://sepolia.base.org"
LASNA_RPC="https://lasna-rpc.rnk.dev/"
FAUCET_BASE="0x2afaFD298b23b62760711756088F75B7409f5967" # Base Sepolia -> lREACT, 1 ETH = 100 lREACT

WALLET_JSON=".wallet.json"
[ -f "$WALLET_JSON" ] || { echo "ERROR: $WALLET_JSON not found"; exit 1; }
PK=$(python3 -c "import json;print(json.load(open('$WALLET_JSON'))['data'][0]['private_key'])")
ADDR=$(python3 -c "import json;print(json.load(open('$WALLET_JSON'))['data'][0]['address'])")
echo "Deployer: $ADDR"

BASE_BAL=$(cast balance "$ADDR" --rpc-url "$BASE_RPC")
BASE_BAL_ETH=$(cast to-unit "$BASE_BAL" ether)
echo "Base Sepolia balance: $BASE_BAL_ETH ETH"
if [ "$(cast to-unit "$BASE_BAL" wei | cut -d. -f1)" -lt 200000000000000000 ]; then
  echo "ERROR: need >= 0.2 Sepolia ETH in $ADDR (see FUNDING.md). Aborting before spending anything."
  exit 1
fi

echo "=== Step 0: convert 0.1 Sepolia ETH -> 10 lREACT (Lasna faucet) ==="
# Documented faucet call: request(address) with 0.1 ETH value, 1 ETH = 100 lREACT.
cast send "$FAUCET_BASE" "request(address)" "$ADDR" --value 0.1ether --rpc-url "$BASE_RPC" --private-key "$PK" --json | python3 -c "import json,sys;d=json.load(sys.stdin);print('faucet tx:',d.get('transactionHash'))"
sleep 10
echo -n "Lasna balance after conversion: "
cast balance "$ADDR" --rpc-url "$LASNA_RPC" | xargs -I{} cast to-unit {} ether | xargs echo -n
echo " lREACT"

echo "=== Step 1: deploy PingEmitter (Base Sepolia) ==="
forge script script/DeployEmitter.s.sol --rpc-url "$BASE_RPC" --private-key "$PK" --broadcast
EMITTER=$(python3 -c "import json;print(json.load(open('deployments/emitter.json'))['emitter'])")
echo "Emitter: $EMITTER"

echo "=== Step 2: deploy PingReactive (Lasna) ==="
EMITTER_ADDRESS="$EMITTER" forge script script/DeployLasna.s.sol --rpc-url "$LASNA_RPC" --private-key "$PK" --broadcast
REACTIVE=$(python3 -c "import json;print(json.load(open('deployments/lasna.json'))['reactive'])")
echo "Reactive: $REACTIVE"

echo "=== Step 3: deploy Pong (Base Sepolia) ==="
REACTIVE_ADDRESS="$REACTIVE" forge script script/DeployPong.s.sol --rpc-url "$BASE_RPC" --private-key "$PK" --broadcast
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
