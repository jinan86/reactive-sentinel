#!/usr/bin/env python3
"""Sentinel Agent — off-chain AI service for the Reactive Omni Buildathon.

Watches DemoVault events on Base Sepolia, scores each event in two layers:
  (a) deterministic heuristic scorer (always on, fully auditable);
  (b) an LLM reasoning pass (optional, swappable OpenAI-compatible API).
A verdict (risk score 0-100 + action NONE/FREEZE/RESCUE + written reasons)
is written to VerdictOracle on-chain. Doubt = no action (fail closed):
scores below the threshold map to action NONE, and any LLM failure falls
back to the heuristic score.

LLM configuration (all optional — without a key the agent runs
heuristic-only and says so in every decision log):
  LLM_API_KEY   API key (never hardcoded, never logged)
  LLM_API_URL   OpenAI-compatible chat-completions endpoint
                (default https://api.openai.com/v1/chat/completions)
  LLM_MODEL     model name (default gpt-4o-mini)

Chain configuration (env, with sane testnet defaults):
  BASE_RPC      default https://sepolia.base.org
  VAULT_ADDRESS DemoVault address (required)
  ORACLE_ADDRESS VerdictOracle address (required)
  WALLET_FILE   project wallet keypair JSON (default ../.wallet.json)
  RISK_THRESHOLD default 70

Usage:
  python3 sentinel_agent.py --once [--from-block N]
  python3 sentinel_agent.py --watch 15 [--from-block N]

State (checkpoint + audit trail) lives next to this script:
  state.json      last processed block
  decisions.jsonl append-only decision log (one JSON object per event)
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.request
import urllib.error

# cast is usually on PATH via ~/.foundry/bin; resolve it once so the
# agent also works when started without that PATH (e.g. from a cron).
CAST = shutil.which("cast") or os.path.expanduser("~/.foundry/bin/cast")

# --- event topics (keccak of the canonical signatures) ---
TOPIC_DEPOSIT = "0x90890809c654f11d6e72a28fa60149770a0d11ec6c92319d6ceb2bb0a4ea1a15"
TOPIC_WITHDRAWAL = "0xdf273cb619d95419a9cd0ec88123a0538c85064229baa6363788f743fff90deb"
TOPIC_LARGE_WITHDRAWAL = "0xa2832264a51be8d7acb2d058999bca0b75c92cb349c42556484ed6bd5d5bd58c"
TOPIC_PRICE_DEVIATION = "0xf46526c26ccf6324bbd8ed1ccee39035d9ea5ab24523d2d963afecf2d539b9fd"

ACTION_NONE = 0
ACTION_FREEZE = 1
ACTION_RESCUE = 2
ACTION_NAMES = {0: "NONE", 1: "FREEZE", 2: "RESCUE"}

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
STATE_FILE = os.path.join(BASE_DIR, "state.json")
DECISIONS_FILE = os.path.join(BASE_DIR, "decisions.jsonl")


def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def _rpc_urls(primary):
    fallbacks = os.environ.get(
        "BASE_RPC_FALLBACKS",
        "https://base-sepolia-rpc.publicnode.com,https://base-sepolia.drpc.org",
    )
    urls = [primary] + [u.strip() for u in fallbacks.split(",") if u.strip()]
    seen, out = set(), []
    for u in urls:
        if u not in seen:
            seen.add(u)
            out.append(u)
    return out


def rpc(method, params, url, retries=5):
    """JSON-RPC call with retries on transient failures (public testnet
    RPCs drop connections under load — a single failure must not kill a
    demo run). Rotates through fallback RPCs; sends a browser User-Agent
    because some endpoints 403 Python-urllib's default UA."""
    body = json.dumps({"jsonrpc": "2.0", "method": method, "params": params, "id": 1}).encode()
    urls = _rpc_urls(url)
    last_err = None
    for attempt in range(retries):
        u = urls[attempt % len(urls)]
        try:
            req = urllib.request.Request(u, data=body, headers={
                "Content-Type": "application/json",
                "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36",
            })
            with urllib.request.urlopen(req, timeout=30) as resp:
                out = json.load(resp)
            if "error" in out:
                raise RuntimeError(f"RPC {method} failed: {out['error']}")
            return out["result"]
        except Exception as e:  # noqa: BLE001 - retry everything transient
            # A JSON-RPC error object is a real failure, not transient.
            if isinstance(e, RuntimeError):
                raise
            last_err = e
            wait = 2 ** attempt
            log(f"RPC {method} via {u} attempt {attempt + 1}/{retries} failed ({e}); retrying in {wait}s")
            time.sleep(wait)
    raise RuntimeError(f"RPC {method} failed after {retries} attempts: {last_err}")


def u256(word):
    return int(word, 16)


def i256(word):
    v = int(word, 16)
    return v - (1 << 256) if v >= (1 << 255) else v


def addr(topic):
    return "0x" + topic[-40:]


def decode_log(log):
    """Decode a DemoVault log into (event_name, args dict)."""
    topic0 = log["topics"][0].lower()
    data = bytes.fromhex(log["data"][2:])
    words = [data[i:i + 32] for i in range(0, len(data), 32)]
    user = addr(log["topics"][1]) if len(log.get("topics", [])) > 1 else None
    if topic0 == TOPIC_DEPOSIT:
        return "Deposit", {"user": user, "amount": u256(words[0].hex()), "balance": u256(words[1].hex())}
    if topic0 == TOPIC_WITHDRAWAL:
        return "Withdrawal", {"user": user, "amount": u256(words[0].hex()), "balance": u256(words[1].hex())}
    if topic0 == TOPIC_LARGE_WITHDRAWAL:
        return "LargeWithdrawal", {"user": user, "amount": u256(words[0].hex()), "shareBps": u256(words[1].hex())}
    if topic0 == TOPIC_PRICE_DEVIATION:
        return "PriceDeviation", {
            "oldPrice": i256(words[0].hex()),
            "newPrice": i256(words[1].hex()),
            "deviationBps": u256(words[2].hex()),
        }
    return None, {}


# ---------------------------------------------------------------- heuristics
def heuristic_score(event, args, context):
    """Deterministic risk score 0-100 + action. Fully auditable, no model.

    Context: {"recent_deviation_bps": int, "recent_withdrawals": int}
    (events of the last ~10 minutes, same vault).
    """
    if event == "LargeWithdrawal":
        share = args["shareBps"]
        if share >= 7500:
            score = 90
        elif share >= 5000:
            score = 85
        elif share >= 2500:
            score = 70
        else:
            score = 40
        reasons = [f"large withdrawal {share / 100:.1f}% of TVL in one tx"]
        if context.get("recent_deviation_bps", 0) >= 1000:
            score += 10
            reasons.append(f"price deviation {context['recent_deviation_bps'] / 100:.1f}% in the same window")
        if context.get("recent_withdrawals", 0) >= 3:
            score += 10
            reasons.append(f"{context['recent_withdrawals']} withdrawals in the last 10 min (velocity)")
        score = min(score, 100)
    elif event == "PriceDeviation":
        dev = args["deviationBps"]
        if dev >= 2000:
            score = 75
        elif dev >= 1000:
            score = 55
        elif dev >= 500:
            score = 35
        else:
            score = 15
        reasons = [f"price moved {dev / 100:.1f}% (mock feed)"]
    elif event == "Withdrawal":
        score = 10
        reasons = ["ordinary withdrawal below the large-share threshold"]
    else:  # Deposit
        score = 5
        reasons = ["ordinary deposit"]
    if score >= 85:
        action = ACTION_RESCUE
    elif score >= 70:
        action = ACTION_FREEZE
    else:
        action = ACTION_NONE
    return score, action, "; ".join(reasons)


# ---------------------------------------------------------------- LLM layer
def llm_score(event, args, heuristic, threshold):
    """Optional LLM reasoning pass. Returns (score, action, reasons, meta).

    Meta records which layer decided. Any failure (no key, network error,
    bad JSON, out-of-range values) falls back to the heuristic verdict —
    the LLM can never raise risk on its own, and a missing LLM never
    blocks the pipeline.
    """
    h_score, h_action, h_reasons = heuristic
    api_key = os.environ.get("LLM_API_KEY", "")
    if not api_key:
        return h_score, h_action, h_reasons, {"layer": "heuristic_only", "llm": "skipped_no_key"}
    url = os.environ.get("LLM_API_URL", "https://api.openai.com/v1/chat/completions")
    model = os.environ.get("LLM_MODEL", "gpt-4o-mini")
    prompt = (
        "You are a DeFi security analyst. Score this vault event for exploit risk.\n"
        f"Event: {event} {json.dumps(args, default=str)}\n"
        f"Heuristic score: {h_score}/100 (action {ACTION_NAMES[h_action]}), reasons: {h_reasons}\n"
        "Rules: risk_score is 0-100. action is 0 (NONE, score<70), 1 (FREEZE, 70-84), "
        "2 (RESCUE, >=85, only for an existential drain). A single large withdrawal "
        "after a sharp price drop is a classic exploit pattern. A lone small move is not.\n"
        "Reply with JSON only: {\"risk_score\": <int>, \"action\": <0|1|2>, \"reasons\": \"<one sentence>\"}."
    )
    payload = json.dumps({
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "temperature": 0,
        "max_tokens": 200,
    }).encode()
    req = urllib.request.Request(
        url, data=payload,
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {api_key}"},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            out = json.load(resp)
        text = out["choices"][0]["message"]["content"].strip()
        parsed = json.loads(text[text.index("{"):text.rindex("}") + 1])
        score = int(parsed["risk_score"])
        reasons = str(parsed["reasons"])[:300]
        if not (0 <= score <= 100):
            raise ValueError(f"out-of-range LLM score: {parsed}")
        # The LLM may lower risk, but may not escalate beyond heuristic+15:
        # a model hallucination must not rescue a healthy vault.
        if score > h_score + 15:
            score = h_score + 15
            reasons += " (LLM score capped at heuristic+15)"
        # Action is always derived from the final score by the same
        # deterministic thresholds — the LLM supplies judgment, not control.
        action = ACTION_RESCUE if score >= 85 else ACTION_FREEZE if score >= 70 else ACTION_NONE
        return score, action, reasons, {"layer": "llm", "llm": "ok", "model": model}
    except Exception as e:  # noqa: BLE001 - any LLM failure falls back
        return h_score, h_action, h_reasons, {"layer": "heuristic_fallback", "llm": f"error: {type(e).__name__}"}


# ---------------------------------------------------------------- chain I/O
def load_wallet_key(wallet_file):
    with open(wallet_file) as f:
        data = json.load(f)
    return data["data"][0]["private_key"], data["data"][0]["address"]


def write_verdict(oracle, vault, score, action, reasons, pk, rpc_url):
    """Send writeVerdict via cast. Returns (tx_hash, verdict_id or None)."""
    cmd = [
        CAST, "send", oracle,
        "writeVerdict(address,uint256,uint8,string)",
        vault, str(score), str(action), reasons,
        "--private-key", pk, "--rpc-url", rpc_url, "--json",
    ]
    out = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    if out.returncode != 0:
        raise RuntimeError(f"cast send failed: {out.stderr.strip()[-500:]}")
    tx = json.loads(out.stdout)
    tx_hash = tx.get("transactionHash")
    # The verdict id is the next index; read it back from the oracle.
    count_out = subprocess.run(
        [CAST, "call", oracle, "verdictCount()(uint256)", "--rpc-url", rpc_url],
        capture_output=True, text=True, timeout=60,
    )
    verdict_id = None
    if count_out.returncode == 0:
        try:
            verdict_id = int(count_out.stdout.strip(), 0) - 1
        except ValueError:
            pass
    return tx_hash, verdict_id


def fetch_logs(vault, from_block, to_block, rpc_url):
    """eth_getLogs in <=200-block windows (public Base Sepolia endpoints
    reject wider ranges with 413 / 'limited to a 200 range')."""
    out = []
    step = 200
    b = from_block
    while b <= to_block:
        e = min(b + step - 1, to_block)
        params = [{
            "fromBlock": hex(b),
            "toBlock": hex(e),
            "address": vault,
            "topics": [[TOPIC_DEPOSIT, TOPIC_WITHDRAWAL, TOPIC_LARGE_WITHDRAWAL, TOPIC_PRICE_DEVIATION]],
        }]
        out.extend(rpc("eth_getLogs", params, rpc_url))
        b = e + 1
    return out


# ---------------------------------------------------------------- main loop
def process_range(vault, oracle, pk, rpc_url, from_block, to_block):
    logs = fetch_logs(vault, from_block, to_block, rpc_url)
    # Context window: deviations + withdrawal counts inside this range.
    recent_dev = 0
    recent_wd = 0
    for lg in logs:
        ev, a = decode_log(lg)
        if ev == "PriceDeviation":
            recent_dev = max(recent_dev, a["deviationBps"])
        if ev in ("Withdrawal", "LargeWithdrawal"):
            recent_wd += 1
    context = {"recent_deviation_bps": recent_dev, "recent_withdrawals": recent_wd}
    threshold = int(os.environ.get("RISK_THRESHOLD", "70"))
    for lg in logs:
        event, args = decode_log(lg)
        if event is None:
            continue
        block = int(lg["blockNumber"], 16)
        h = heuristic_score(event, args, context)
        score, action, reasons, meta = llm_score(event, args, h, threshold)
        tx_hash, verdict_id = write_verdict(oracle, vault, score, action, reasons, pk, rpc_url)
        decision = {
            "ts": int(time.time()),
            "block": block,
            "txHash": lg["transactionHash"],
            "logIndex": int(lg["logIndex"], 16),
            "event": event,
            "args": {k: str(v) for k, v in args.items()},
            "heuristic": {"score": h[0], "action": ACTION_NAMES[h[1]], "reasons": h[2]},
            "llm": meta,
            "final_score": score,
            "final_action": ACTION_NAMES[action],
            "verdict_tx": tx_hash,
            "verdict_id": verdict_id,
        }
        with open(DECISIONS_FILE, "a") as f:
            f.write(json.dumps(decision) + "\n")
        log(f"block {block} {event} {args} -> score {score} action {ACTION_NAMES[action]} "
            f"({meta['layer']}) verdict_tx {tx_hash}")
    return len(logs)


def load_state():
    if os.path.exists(STATE_FILE):
        with open(STATE_FILE) as f:
            return json.load(f)
    return {}


def save_state(state):
    with open(STATE_FILE, "w") as f:
        json.dump(state, f, indent=2)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--once", action="store_true", help="process new events once, then exit")
    ap.add_argument("--watch", type=int, metavar="SECONDS", help="poll every N seconds")
    ap.add_argument("--from-block", type=int, default=None, help="first block to scan (first run only)")
    args = ap.parse_args()
    if not (args.once or args.watch):
        ap.error("choose --once or --watch SECONDS")

    rpc_url = os.environ.get("BASE_RPC", "https://sepolia.base.org")
    vault = os.environ.get("VAULT_ADDRESS", "")
    oracle = os.environ.get("ORACLE_ADDRESS", "")
    if not vault or not oracle:
        print("ERROR: set VAULT_ADDRESS and ORACLE_ADDRESS", file=sys.stderr)
        sys.exit(1)
    wallet_file = os.environ.get("WALLET_FILE", os.path.join(BASE_DIR, "..", ".wallet.json"))
    pk, addr = load_wallet_key(wallet_file)
    log(f"Sentinel Agent starting — vault {vault} oracle {oracle} writer {addr}")
    log(f"LLM: {'enabled (' + os.environ.get('LLM_MODEL', 'gpt-4o-mini') + ')' if os.environ.get('LLM_API_KEY') else 'disabled (heuristic-only)'}")

    state = load_state()
    if "last_block" not in state:
        if args.from_block is not None:
            state["last_block"] = args.from_block - 1
        else:
            latest = int(rpc("eth_blockNumber", [], rpc_url), 16)
            state["last_block"] = latest  # start from now; history via --from-block
            log(f"no checkpoint; starting at latest block {latest} (use --from-block to replay)")
    save_state(state)

    def run_once():
        latest = int(rpc("eth_blockNumber", [], rpc_url), 16)
        frm = state["last_block"] + 1
        if frm > latest:
            return 0
        n = process_range(vault, oracle, pk, rpc_url, frm, latest)
        state["last_block"] = latest
        save_state(state)
        return n

    if args.once:
        last_err = None
        for attempt in range(3):
            try:
                n = run_once()
                log(f"done: {n} event(s) processed")
                return
            except Exception as e:  # noqa: BLE001 - retry the whole pass
                last_err = e
                log(f"--once attempt {attempt + 1}/3 failed ({e}); retrying")
                time.sleep(2 ** attempt)
        print(f"ERROR: --once failed after 3 attempts: {last_err}", file=sys.stderr)
        sys.exit(1)
    while True:
        try:
            n = run_once()
            if n:
                log(f"watch tick: {n} event(s) processed")
        except Exception as e:  # noqa: BLE001 - watcher must not die on RPC hiccups
            log(f"watch tick error (will retry): {e}")
        time.sleep(args.watch)


if __name__ == "__main__":
    main()
