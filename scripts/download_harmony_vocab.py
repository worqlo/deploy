#!/usr/bin/env python3
"""
Download Harmony encoding vocab into deploy/vocab_cache for baking into the Docker image.

Run from backend repo root: python deploy/scripts/download_harmony_vocab.py
Or from deploy repo root: python scripts/download_harmony_vocab.py

Requires network. After this, rebuild the API image so the vocab is copied into the container.
"""
import sys
from pathlib import Path

# Works when deploy is in backend/deploy (submodule) or standalone deploy repo
DEPLOY_ROOT = Path(__file__).resolve().parents[1]
VOCAB_CACHE_DIR = DEPLOY_ROOT / "vocab_cache"


def main() -> int:
    VOCAB_CACHE_DIR.mkdir(parents=True, exist_ok=True)
    cache_dir = str(VOCAB_CACHE_DIR)

    import os
    os.environ["TIKTOKEN_RS_CACHE_DIR"] = cache_dir

    print("Downloading Harmony encoding (HarmonyGptOss) into", cache_dir, "...")
    try:
        from openai_harmony import load_harmony_encoding, HarmonyEncodingName

        load_harmony_encoding(HarmonyEncodingName.HARMONY_GPT_OSS)
    except Exception as e:
        print("FAILED:", e, file=sys.stderr)
        return 1

    files = list(VOCAB_CACHE_DIR.iterdir())
    print("OK. Cache now has", len(files), "file(s):")
    for f in files:
        if f.is_file():
            print(" ", f.name, f.stat().st_size, "bytes")
    print("Rebuild the API image so the vocab is included: docker compose build api")
    return 0


if __name__ == "__main__":
    sys.exit(main())
