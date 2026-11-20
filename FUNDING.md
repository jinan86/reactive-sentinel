# FUNDING.md — how the hello-world loop gets its testnet gas

## The blocker (as of 20 Nov 2026 ~21:30 WIB)

The project wallet is **empty on every testnet**. No Sepolia ETH could be
acquired headlessly from this VM: every no-login faucet is either dead
(`faucet.sepolia.dev`, Paradigm, `faucet.base.org`), captcha-gated
(pk910 PoW faucet — custom captcha required to start a session; Chainlink
faucet — Cloudflare Turnstile; Google Cloud faucet — reCAPTCHA + Google
sign-in), or account-gated (Alchemy, QuickNode, Infura, Coinbase).

## The wallet (testnet only, project-only, no real value)

- **Address: `0x9e377851c1DF9aCB840d5081572E3AF7C45ac449`**
- Keypair: `sentinel/.wallet.json` (mode 600, gitignored — never commit it,
  never paste it anywhere).
- Balances checked 20 Nov 2026: Base Sepolia 0, Eth Sepolia 0, Lasna 0.
- This is **NOT** zee's wallet. Never send anything to or from
  `0xf05EE95B254010D710436D50fEA750E283d00623`.

## What is needed: 0.2 Sepolia ETH (testnet, worthless)

| Use | Amount | Where |
| --- | --- | --- |
| Convert to lREACT (1 ETH = 100 lREACT) | 0.1 ETH | send to `0x2afaFD298b23b62760711756088F75B7409f5967` on **Base Sepolia** → 10 lREACT on Lasna |
| Base Sepolia deploys (emitter + pong) + pong funding (0.01) + ping txs | ~0.05 ETH | Base Sepolia |
| Buffer | ~0.05 ETH | — |

Cost sanity (live, 20 Nov 2026): Lasna gas price 100 gwei, system fee
coeff 1.0, extraGas 100,000 — one react() ≈ 0.035 lREACT. Base Sepolia gas
price 0.006 gwei, proxy coeff 1.1, extraGas 80,000 — one callback ≈
0.0000015 ETH. 10 lREACT + 0.1 ETH is far more than the loop needs.

## How to fund it (2 minutes, zee's phone)

1. Open any Sepolia faucet on a phone/browser where zee is already signed
   in — **Google Cloud Web3 faucet** (Google account) or **Alchemy faucet**
   (free account) both work.
2. Paste the wallet address above, claim ~0.2–0.5 Sepolia ETH.
3. Tell Anomali (or just run `./deploy.sh` in this directory) — the script
   preflights the balance, converts 0.1 ETH to lREACT, deploys everything,
   sends a ping, and polls until the loop is proven (or reports the lag).

Alternative without zee: a browser task can do the Google Cloud faucet
with zee signing in via takeover and solving the reCAPTCHA himself.

## After funding

`./deploy.sh` does everything and prints the proof:
`emitter / reactive / pong` addresses + the ping tx hash + `reactCount=1`
+ `pongCount=1`. Those go into `PHASE1.md` and the report to zee.
