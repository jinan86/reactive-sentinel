#!/usr/bin/env python3
"""Sentinel demo video — slide-based, 1280x720, ~140s.
Renders PNG slides with PIL and concatenates them with ffmpeg + silent audio.
TX hashes from demo-llm-run4.log (22 Nov 2026, demo run #4 — full LLM loop,
attack verdict 85 RESCUE via OpenRouter fallback after 100milionseek 502 x3).
Pattern copied from takeprofit/make-video.py.
"""
import os
import subprocess
import textwrap

from PIL import Image, ImageDraw, ImageFont

W, H = 1280, 720
OUT = os.path.dirname(os.path.abspath(__file__))
SLIDES_DIR = os.path.join(OUT, "video-slides")
os.makedirs(SLIDES_DIR, exist_ok=True)

# --- tx hashes from demo-llm-run4.log (short hashes shown on slides) ---
TX_SEED = "0x0606d8c7…06bcc73"      # seed deposit 1000 tUSD
TX_BENIGN = "0xaf846b22…005972d"    # withdraw 50 tUSD
TX_V_BENIGN = "0x5b134721…5fb9264a5c0a"  # verdict #18 Withdrawal 50 -> 10 NONE
TX_ATTACK = "0x48d25877…8aea91a0b"  # attack withdraw 700 tUSD
TX_VERDICT = "0x42c15a0b…497043"    # verdict #20 LargeWithdrawal -> 85 RESCUE
TX_REACT = "0xd6c1f4f8…35d14760"    # Lasna react() tx
TX_CALLBACK = "0xebcf85c3…8ebe647"  # Base Sepolia callback tx

BG = (13, 17, 23)
CARD = (22, 27, 34)
ACCENT = (88, 166, 255)
GREEN = (63, 185, 80)
RED = (248, 81, 73)
TEXT = (230, 237, 243)
MUTED = (139, 148, 158)

FONT_BIG = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
FONT_REG = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"


def font(size, bold=False):
    return ImageFont.truetype(FONT_BIG if bold else FONT_REG, size)


def slide(idx, title, lines, accent=ACCENT, seconds=16):
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([60, 60, W - 60, H - 60], radius=24, fill=CARD)
    d.rectangle([60, 60, W - 60, 72], fill=accent)
    d.text((100, 110), title, font=font(44), fill=TEXT)
    y = 200
    for line in lines:
        for chunk in textwrap.wrap(line, width=62):
            d.text((100, y), chunk, font=font(30), fill=TEXT if not chunk.startswith("  ") else MUTED)
            y += 46
        y += 14
    d.text((100, H - 110), "Sentinel  ·  Reactive Omni Buildathon — Reactive Meets AI  ·  testnet",
           font=font(20), fill=MUTED)
    path = os.path.join(SLIDES_DIR, f"slide{idx:02d}.png")
    img.save(path)
    return path, seconds


def main():
    slides = [
        slide(1, "Sentinel — AI circuit breaker",
              ["A vault on Base Sepolia, watched by an AI service.",
               "The AI scores every event; a Reactive contract on Lasna",
               "enforces the verdict — freeze or rescue — in seconds."],
              seconds=14),
        slide(2, "How the loop works",
              ["1 · DemoVault emits events (deposit / withdrawal / attack).",
               "2 · AI service scores risk: heuristics + LLM reasoning.",
               "3 · Verdict written on-chain to VerdictOracle.",
               "4 · SentinelReactive (Lasna) reacts, VaultGuard acts."],
              seconds=16),
        slide(3, "1 · Vault seeded — 1,000 tUSD",
              ["DemoVault holds 1,000 tUSD. The AI sees the deposit:",
               "score 5, action NONE. Nothing to do — normal activity.",
               f"tx {TX_SEED}"],
              seconds=12),
        slide(4, "2 · Benign withdrawal — 50 tUSD",
              ["A user withdraws 50 tUSD — just 5% of the vault.",
               "LLM verdict #18: score 10, action NONE.",
               "The reactive contract records it and does NOTHING.",
               f"withdraw {TX_BENIGN}",
               f"verdict {TX_V_BENIGN}"],
              seconds=16),
        slide(5, "3 · ATTACK — withdraw 700 tUSD",
              ["One withdrawal of 700 tUSD — 73.7% of the vault.",
               "This is the drain pattern the circuit breaker is for.",
               f"tx {TX_ATTACK}"],
              accent=RED, seconds=14),
        slide(6, "4 · LLM verdict: 85 — RESCUE",
              ["The LLM reasons: a single withdrawal of 73.7% of TVL",
               "is an existential drain consistent with exploit behavior.",
               "Verdict #20: score 85, action RESCUE — written on-chain.",
               "Honest note: primary LLM proxy 502'd 3x; the OpenRouter",
               "fallback model scored it. Retry + fallback saved the run.",
               f"tx {TX_VERDICT}"],
              accent=RED, seconds=20),
        slide(7, "5 · Reactive fires — vault frozen, funds rescued",
              ["SentinelReactive on Lasna sees verdict #20 and reacts.",
               "Callback to VaultGuard: freeze the vault, rescue the rest.",
               "250 tUSD moved to the safe vault in under 30 seconds.",
               f"react {TX_REACT}",
               f"callback {TX_CALLBACK}"],
              accent=GREEN, seconds=18),
        slide(8, "Result — drain stopped",
              ["Vault: FROZEN, TVL 0 tUSD.",
               "safeVault holds 1,000 tUSD (750 withdrawn + 250 rescued).",
               "On-chain: verdictCount 21, reactCount 21, actedCount 5,",
               "lastRiskScore 85, lastAction RESCUE. Doubt = no action;",
               "here the AI was sure — and the chain enforced it."],
              accent=GREEN, seconds=18),
        slide(9, "Contracts + repo",
              ["DemoVault 0x13F90bfd…Fbe5E  ·  VerdictOracle 0xbE1284e…E0AC",
               "SentinelReactive (Lasna) 0x62f29479…d724",
               "VaultGuard 0x974C8F67…44f  ·  tUSD 0x3d82cf0E…eDF5",
               "Repo: github.com/jinan86/reactive-sentinel",
               "Testnet only. No real funds. LLM chain: 100milionseek",
               "→ OpenRouter → Coarena → heuristic fallback."],
              seconds=18),
    ]
    total = sum(s for _, s in slides)
    print(f"slides: {len(slides)}, total ~{total}s")
    concat = os.path.join(SLIDES_DIR, "concat.txt")
    with open(concat, "w") as f:
        for path, secs in slides:
            f.write(f"file '{path}'\nduration {secs}\n")
        f.write(f"file '{slides[-1][0]}'\n")
    out = os.path.join(OUT, "demo-video.mp4")
    subprocess.run([
        "ffmpeg", "-y", "-f", "concat", "-safe", "0", "-i", concat,
        "-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo",
        "-map", "0:v", "-map", "1:a", "-t", str(total),
        "-vf", "format=yuv420p", "-c:v", "libx264", "-r", "30",
        "-c:a", "aac", "-shortest", out,
    ], check=True)
    print("wrote", out)


if __name__ == "__main__":
    main()
