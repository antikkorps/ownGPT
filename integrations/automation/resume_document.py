#!/usr/bin/env python3
"""Automatic document summary through the company AI gateway (LiteLLM).

Usage:
    export OWNGPT_API_URL=https://api.exemple.fr     # gateway base URL
    export OWNGPT_AUTOMATION_KEY=sk-...              # "automatisation" virtual key
    python3 resume_document.py document.txt [--modele mistral-small]

Stdlib only: runs on any server with Python 3.9+, no dependency to install.
The gateway logs who called which model and the cost, never the document itself.
"""
import argparse
import json
import os
import sys
import urllib.error
import urllib.request

PROMPT = (
    "Résume le document suivant pour un comité de direction : une phrase d'essentiel, "
    "puis 3 à 5 points clés en puces, puis « Actions » si le document en contient. "
    "N'invente rien.\n\n---\n{texte}"
)
MAX_CHARS = 60_000  # keeps one call well under the model context and the key budget


def parse_args():
    p = argparse.ArgumentParser(description="Résumé automatique via la passerelle IA")
    p.add_argument("fichier")
    p.add_argument("--modele", default="mistral-small")
    return p.parse_args()


def summarize(text, model):
    body = json.dumps({
        "model": model,
        "temperature": 0.2,
        "max_tokens": 600,
        "messages": [{"role": "user", "content": PROMPT.format(texte=text[:MAX_CHARS])}],
    }).encode()
    req = urllib.request.Request(
        os.environ["OWNGPT_API_URL"].rstrip("/") + "/v1/chat/completions",
        data=body,
        headers={"Authorization": "Bearer " + os.environ["OWNGPT_AUTOMATION_KEY"],
                 "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=120) as r:
        data = json.load(r)
    return data["choices"][0]["message"]["content"], data.get("usage", {})


def check_env():
    missing = [v for v in ("OWNGPT_API_URL", "OWNGPT_AUTOMATION_KEY") if not os.environ.get(v)]
    if missing:
        sys.exit("Variables manquantes : " + ", ".join(missing))


def main():
    args = parse_args()
    check_env()
    with open(args.fichier, encoding="utf-8") as f:
        text = f.read()
    if len(text) > MAX_CHARS:
        print(f"Attention : document tronqué à {MAX_CHARS} caractères sur {len(text)}.", file=sys.stderr)
    try:
        summary, usage = summarize(text, args.modele)
    except urllib.error.HTTPError as e:
        # 401 = key revoked or blocked, 400/429 with "budget" = key budget exhausted.
        sys.exit(f"Refusé par la passerelle (HTTP {e.code}) : {e.read().decode()[:300]}")
    except urllib.error.URLError as e:
        sys.exit(f"Passerelle injoignable ({os.environ['OWNGPT_API_URL']}) : {e.reason}")
    print(summary)
    print(f"\n[{args.modele} · {usage.get('total_tokens', '?')} tokens]", file=sys.stderr)


if __name__ == "__main__":
    main()
