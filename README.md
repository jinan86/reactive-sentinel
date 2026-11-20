# Sentinel — AI-scored cross-chain circuit breaker (Reactive Omni Buildathon)

Track: **Reactive Meets AI** (then Set It and Forget It).
Full plan: [`../PLAN.md`](../PLAN.md) (Indonesian).

## What it is

A demo vault on Base Sepolia emits events (deposits, withdrawals, large
withdrawals, price deviations, simulated attacks). An off-chain AI service
scores each event in two layers — deterministic heuristics + an LLM reasoning
pass — and writes a reasoned verdict on-chain. A reactive contract on Lasna
subscribes to risky-verdict events and, via `react()` + callback, freezes
or rescues the vault. Every action carries a reasoned audit trail.
Doubt = no action (fail closed).

## Status — Phase 1 (hello-world loop) — ✅ LOOP PROVEN LIVE, 21 Nov 2026 ~00:05 WIB

**Ping 777 from Base Sepolia → `react()` on Lasna → callback to Pong on
Base Sepolia, all within 30 seconds.** `reactCount=1`, `pongCount=1`,
`lastValue=777`.

| Step | Chain | Contract | Tx |
| --- | --- | --- | --- |
| `ping(777)` | Base Sepolia | `0x5C80e41332FEEa4B2DB7aB1C1d1d76e1Adb2FF0B` | [`0xc184ddb6…52799d`](https://sepolia.basescan.org/tx/0xc184ddb6fafe73223ffa8dfe63c31f49a4ceb8eb1738534ae26491704152799d) (block 61300936) |
| `react()` | Lasna | `0x29924B7F22eC397925f94996a1815c1f78F9E939` | [`0x82cf8f1f…0bc6212`](https://lasna.reactscan.net/tx/0x82cf8f1f3943f0d71b1e09d92c7eb3c2b923b72a8412665c012dd56af0bc6212) (block 8815301, gas 158,923; `Reacted` event value 777) |
| callback `pong()` | Base Sepolia | `0x2f1795AbC81e6CDa56E164ec3457938DdFA927d7` | [`0x5f871b8f…68a3d724e`](https://sepolia.basescan.org/tx/0x5f871b8f7f736b5fed11c4e0de592ee5a8f0c139aa131fb730ee41868a3d724e) (block 61300944; `PongReceived` event, count=1) |

Loop cost: reactive balance 0.5 → 0.48013 lREACT; pong balance 0.002 →
~0.001999 ETH.

- `src/PingEmitter.sol` — origin contract (Base Sepolia): emits `Ping`.
- `src/PingReactive.sol` — reactive contract (Lasna): subscribes to `Ping`,
  `react()` requests a callback to Pong.
- `src/Pong.sol` — callback contract (Base Sepolia): receives the callback.
- `test/Ping.t.sol` — 10 unit tests (mock system contract etched at the
  real SYSTEM address): event decoding, non-matching log filtering,
  `onlySystem` guard, callback payload, Pong's `onlyServiceProvider` +
  `onlyCallbackSender` guards.
- `test/PingFork.t.sol` — fork test against the **real** Lasna system
  contract and the **real** Base Sepolia callback proxy: a real `Ping`
  event is emitted on the Base Sepolia fork, its log is fed to `react()`
  on the Lasna fork as SYSTEM, and the callback request is verified.
- `script/` + `deploy.sh` — full deploy + live-proof runner (see below).
- `forge test`: **11/11 pass** (Phase 1 only; full suite now 33/33, see Phase 2).

## Status — Phase 2 (Sentinel core) — ✅ DEMO LIVE END-TO-END, 21 Nov 2026 ~13:54 WIB

**Benign withdrawal ignored, attack rescued in ~30 seconds.** Vault
seeded 1000 tUSD → withdraw 50 tUSD (5% TVL) scored 10 / NONE → attack
withdraw 700 tUSD (73.7% of TVL) scored 85 / RESCUE → reactive on Lasna
→ callback froze the vault and rescued the remaining 250 tUSD to the
safeVault. Final state: `verdictCount=4`, `reactCount=4`, `actedCount=1`,
`lastRiskScore=85`, `lastAction=2` (RESCUE), `vault.frozen=true`, vault
TVL 0, safeVault holds 1000 tUSD (750 withdrawn + 250 rescued). Full
record with every tx hash: [`../PHASE2.md`](../PHASE2.md).

| Step | Chain | Contract | Tx |
| --- | --- | --- | --- |
| attack withdraw 700 tUSD | Base Sepolia | DemoVault `0x13F90bfd0349173A500a7E860C7C097Cf6bFbe5E` | [`0x4157bf8a…ebcfa`](https://sepolia.basescan.org/tx/0x4157bf8aa2aff10c29bffdc96b2d0c7d547d26fd30468f035c985c41180ebcfa) (block 61304825) |
| verdict RESCUE (score 85) | Base Sepolia | VerdictOracle `0xbE1284eaff6F75e79828c97f5bF38A48502BE0AC` | [`0xb93b1475…3ca2`](https://sepolia.basescan.org/tx/0xb93b1475882b54c037dab60a1660d8e6c17dd489bfc8497efd4072263e853ca2) (verdict #3) |
| `react()` | Lasna | SentinelReactive `0x62f29479A81B2DE7A871518cEDA38Fbe8B96d724` | [`0x504a7e22…07664`](https://lasna.reactscan.net/tx/0x504a7e220e9b003ed1a9d4d8b386155a8dc1436485b13bd5665f58d6a1907664) (block 8816037; riskScore 85, action 2) |
| callback freeze + rescue | Base Sepolia | VaultGuard `0x974C8F676a0f7375329c94E360A492Ca7827044f` | [`0x8640572f…6025`](https://sepolia.basescan.org/tx/0x8640572f9103a34124b2aba8317bfa8786cfaff2d2c75312c8e45d0547c66025) (block 61304912) |

- `src/DemoToken.sol` — mock ERC20 tUSD (owner-only mint).
- `src/DemoVault.sol` — holds tUSD; emits Deposit / Withdrawal /
  LargeWithdrawal (≥25% TVL) / PriceDeviation (≥5% move); `freeze()`
  guard-or-owner, `unfreeze()` owner-only, `rescue()` guard-only,
  requires frozen, moves all funds to safeVault.
- `src/VerdictOracle.sol` — writer-only `writeVerdict(vault, riskScore,
  action, reasons)`; `Verdict` event.
- `src/SentinelReactive.sol` — Lasna; subscribes to Verdict events;
  `RISK_THRESHOLD = 70`; below threshold or action NONE → record only,
  no callback; ≥70 + FREEZE/RESCUE → callback to VaultGuard
  (`CALLBACK_GAS_LIMIT = 300_000`).
- `src/VaultGuard.sol` — Base Sepolia; `execute()` — 1 = freeze,
  2 = freeze-if-needed + rescue; reverts on invalid action.
- `ai-service/sentinel_agent.py` — off-chain AI service (Python 3.12
  stdlib + `cast` CLI, no extra deps). Two layers: deterministic
  heuristics + optional LLM pass (env `LLM_API_KEY`, `LLM_API_URL`,
  `LLM_MODEL`; LLM may lower risk but never escalate beyond
  heuristic+15; any LLM failure falls back to heuristic and is logged).
  Without a key it runs heuristic-only (the live demo ran this way).
  RPC-resilient: retries + fallback RPC rotation + ≤200-block log
  windows (public Base Sepolia RPCs drop connections and 403
  Python-urllib's default User-Agent). Audit trail append-only
  `ai-service/decisions.jsonl`; checkpoint `ai-service/state.json`.
- `test/Sentinel.t.sol` — 22 tests. `forge test`: **33/33 pass**
  (22 Sentinel + 10 Ping + 1 fork).

## Funding (done)

The project wallet `0x9e377851c1DF9aCB840d5081572E3AF7C45ac449` received
0.05 Sepolia ETH from the Google Cloud Web3 faucet (Ethereum Sepolia,
tx `0x2ee3490c…91f824`). It was bridged to Base Sepolia via the official
L1StandardBridge (0.048 ETH, ~6 min to land) and 0.04 ETH was converted
to 4 lREACT via the Lasna faucet. Remaining: ~0.006 ETH Base Sepolia,
~3.5 lREACT Lasna — enough for Phase 2 deploys + demo pings. Full funding
trail: `FUNDING.md` + `../PHASE1.md`.

## Run

```bash
forge build
forge test          # 33 tests, incl. the two-chain fork test
./deploy.sh         # needs funded wallet; deploys + proves the live loop
./deploy-phase2.sh  # deploys the Sentinel core (DemoVault, Oracle, Reactive, Guard)
./demo-attack.sh    # benign + attack demo end-to-end (vault must be unfrozen + seeded)
```

Deploy order (enforced by `deploy.sh`): emitter (Base Sepolia) →
reactive (Lasna) → pong (Base Sepolia) → `setDestination` (Lasna) →
ping → poll `reactCount` / `pongCount`.

## Key facts (verified live, 20 Nov 2026)

- System contract (Lasna + mainnet): `0x8888888888888888888888888888888888888888`
- Base Sepolia callback proxy: `0x476F44b11F5C942c58f4c8E3d0300E5710743585`
  (fee coeff 1.1, extraGas 80,000, maxChargeGas 50,000)
- Lasna system fee: coeff 1.0, extraGas 100,000, maxChargeGas 50,000
- Lasna gas price ~100 gwei → one react() ≈ 0.035 lREACT
- Base Sepolia gas price ~0.006 gwei → one callback ≈ 0.0000015 ETH
- Library: `reactive-lib-omni` v0.1.0 (Omni API — NOT the legacy demos repo)
- Funding model in this lib version: the reactive/callback contract holds
  native balance; debt is settled from it via `pay()` / `coverDebt()`.
  There is no `depositTo` in the lib.

## Rules

- **Testnet only.** Lasna (5318007) + Base Sepolia (84532). No mainnet,
  no real funds. Never use zee's wallet
  `0xf05EE95B254010D710436D50fEA750E283d00623`.
- Project testnet wallet keypair lives in `.wallet.json` (mode 600,
  gitignored). Never commit it, never paste it.
- AI service: deterministic/mock scorer first + swappable LLM client
  (API key via env var, never hardcoded). LLM model + key decided by zee
  later — the build does not block on it.

## License

MIT
