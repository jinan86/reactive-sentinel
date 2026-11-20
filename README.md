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

## Status — Phase 1 (hello-world loop) — 20 Nov 2026

**Code-complete, tests green, live loop proof PENDING FUNDS.**

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
- `forge test`: **11/11 pass.**

**What is NOT yet proven:** the live network loop (Reactive nodes picking
up the event, `react()` executing on Lasna, the proxy delivering the
callback to Pong). That needs funded deployment — see `FUNDING.md`.

## The blocker: Sepolia ETH

The project wallet `0x9e377851c1DF9aCB840d5081572E3AF7C45ac449` is empty on
every testnet. No headless no-login faucet worked from this VM (see
`FUNDING.md` for the full list). **Needed: 0.2 Sepolia ETH** (testnet,
worthless) — 0.1 ETH converts to 10 lREACT via the Lasna faucet, the rest
covers Base Sepolia deploys + callback funding. Once funded, run
`./deploy.sh` — it deploys everything, sends a ping, and polls until the
loop is proven (or reports the lag).

## Run

```bash
forge build
forge test          # 11 tests, incl. the two-chain fork test
./deploy.sh         # needs funded wallet; deploys + proves the live loop
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
