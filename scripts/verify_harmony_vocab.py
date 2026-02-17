#!/usr/bin/env python3
"""
Verify that the Harmony encoding vocab is available (for SGLang token counting).

Checks:
  1. If TIKTOKEN_RS_CACHE_DIR is set, list that directory.
  2. Try to load the Harmony GPT-OSS encoding; report success or failure.
  3. After load, list cache dir again to confirm vocab file exists.

Run from repo root:
  python deploy/scripts/verify_harmony_vocab.py
Or with explicit cache dir:
  TIKTOKEN_RS_CACHE_DIR=/app/.cache/tiktoken_rs python deploy/scripts/verify_harmony_vocab.py
"""
import os
import sys
from pathlib import Path


def main() -> int:
    cache_dir = os.environ.get("TIKTOKEN_RS_CACHE_DIR")
    if cache_dir:
        p = Path(cache_dir)
        print(f"TIKTOKEN_RS_CACHE_DIR={cache_dir}")
        print(f"  exists={p.exists()}, contents={list(p.iterdir()) if p.exists() else 'N/A'}")
    else:
        print("TIKTOKEN_RS_CACHE_DIR is not set (library will use its default).")

    print("\nLoading Harmony encoding (HarmonyGptOss)...")
    try:
        from openai_harmony import load_harmony_encoding, HarmonyEncodingName

        enc = load_harmony_encoding(HarmonyEncodingName.HARMONY_GPT_OSS)
        n = len(enc.encode("hello", disallowed_special=()))
        print(f"  OK. Token count for 'hello': {n}")
    except Exception as e:
        print(f"  FAILED: {e}")
        return 1

    if cache_dir:
        p = Path(cache_dir)
        if p.exists():
            files = list(p.rglob("*"))
            print(f"\nCache dir after load: {len(files)} file(s)")
            for f in files:
                if f.is_file():
                    print(f"  {f.name} ({f.stat().st_size:,} bytes)")
        else:
            print("\nCache dir still missing (library may use a different path).")

    print("\nVocab is available; native token counter can be used.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
