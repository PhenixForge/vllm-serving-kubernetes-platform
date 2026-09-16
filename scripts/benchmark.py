"""Benchmark de charge pour vLLM sous Kubernetes.

Semaine 1-3 : run séquentiel unique (baseline). Semaine 4 : balayage de
niveaux de concurrence croissants pour mesurer le throughput agrégé sous
charge et repérer la limite d'OOM sur la KV cache (--max-model-len 880,
--gpu-memory-utilization 0.6, cf. container/Containerfile — marge
volontairement réduite, peu de VRAM libre sur cette RTX 4060 8 Go).

Usage typique (depuis un `kubectl port-forward svc/vllm-service 8000:8000 -n vllm`) :
    python scripts/benchmark.py --levels 1,2,4,8,16,32
"""
import argparse
import os
import statistics
import time
from concurrent.futures import ThreadPoolExecutor, as_completed

import requests

MODEL = "TheBloke/Mistral-7B-Instruct-v0.1-AWQ"
PROMPT = "List 5 Kubernetes best practices for resource limits."


def run_one(url, max_tokens):
    t0 = time.time()
    try:
        r = requests.post(
            url,
            json={
                "model": MODEL,
                "prompt": PROMPT,
                "max_tokens": max_tokens,
            },
            timeout=120,
        )
        dt = time.time() - t0
        if r.status_code != 200:
            return {"ok": False, "dt": dt, "reason": f"HTTP {r.status_code}: {r.text[:200]}"}
        tokens = r.json()["usage"]["completion_tokens"]
        return {"ok": True, "dt": dt, "tokens": tokens}
    except requests.RequestException as e:
        return {"ok": False, "dt": time.time() - t0, "reason": str(e)}


def run_level(url, concurrency, n_requests, max_tokens):
    t_start = time.time()
    with ThreadPoolExecutor(max_workers=concurrency) as pool:
        futures = [pool.submit(run_one, url, max_tokens) for _ in range(n_requests)]
        results = [f.result() for f in as_completed(futures)]
    wall = time.time() - t_start

    ok = [r for r in results if r["ok"]]
    failed = [r for r in results if not r["ok"]]
    total_tokens = sum(r["tokens"] for r in ok)

    print(f"\n--- concurrency={concurrency} ---")
    print(f"  {len(ok)}/{len(results)} ok, {len(failed)} failed, wall={wall:.1f}s")
    if ok:
        latencies = sorted(r["dt"] for r in ok)
        p50 = latencies[len(latencies) // 2]
        p95 = latencies[int(0.95 * len(latencies))]
        print(f"  latency p50={p50:.2f}s p95={p95:.2f}s mean={statistics.mean(latencies):.2f}s")
        print(f"  throughput={total_tokens / wall:.1f} tok/s aggregate")
    if failed:
        reasons = {}
        for r in failed:
            reasons[r["reason"]] = reasons.get(r["reason"], 0) + 1
        for reason, count in reasons.items():
            print(f"  failure x{count}: {reason}")
    return len(failed) > 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default=os.environ.get("VLLM_HOST", "localhost"))
    parser.add_argument("--port", default=8000, type=int)
    parser.add_argument("--max-tokens", default=200, type=int)
    parser.add_argument("--requests-per-level", default=20, type=int)
    parser.add_argument("--levels", default="1,2,4,8,16,32")
    parser.add_argument(
        "--no-stop-on-failure",
        action="store_true",
        help="Continuer le balayage même après la première défaillance (par défaut, on s'arrête pour ne pas s'acharner sur un serveur déjà en train de rejeter des requêtes).",
    )
    args = parser.parse_args()

    # /v1/completions, pas /v1/chat/completions : ce tokenizer n'a pas de chat
    # template par défaut ("no longer allowed" depuis transformers v4.44,
    # cf. docs/week-03-notes.md) et l'image tourne avec --trust-request-chat-template
    # (le client devrait fournir son propre template pour l'endpoint chat).
    url = f"http://{args.host}:{args.port}/v1/completions"
    levels = [int(x) for x in args.levels.split(",")]

    print(f"--- Load benchmark: {MODEL} @ {url} ---")
    for c in levels:
        had_failures = run_level(url, c, args.requests_per_level, args.max_tokens)
        if had_failures and not args.no_stop_on_failure:
            print(f"\nArrêt du balayage : première défaillance à concurrency={c}")
            break


if __name__ == "__main__":
    main()
