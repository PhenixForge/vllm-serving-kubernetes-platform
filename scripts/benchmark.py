"""Benchmark de charge pour vLLM sous Kubernetes.

Semaine 1-3 : run séquentiel unique (baseline). Semaine 4 : balayage de
niveaux de concurrence croissants pour mesurer le throughput agrégé sous
charge et repérer la limite d'OOM sur la KV cache (--max-model-len 880,
--gpu-memory-utilization 0.6, cf. container/Containerfile — marge
volontairement réduite, peu de VRAM libre sur cette RTX 4060 8 Go).

Semaine 7 : mode soutenu (--duration) — concurrence FIXE pendant N secondes,
résumé par fenêtre de temps horodaté. Sert à observer l'effet d'un scale-out
(KEDA + Karpenter) : la latence p95 et le throughput par fenêtre doivent
s'améliorer quand le 2e replica devient prêt. À lancer dans le cluster (cf.
kubernetes-eks/loadtest.yaml), pas via l'Ingress (rate limiting 5 req/s).

Usage typique (depuis un `kubectl port-forward svc/vllm-service 8000:8000 -n vllm`) :
    python scripts/benchmark.py --levels 1,2,4,8,16,32
    python scripts/benchmark.py --duration 900 --concurrency 32 --window 15
"""
import argparse
import os
import statistics
import threading
import time
from datetime import datetime, timezone
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


def _print_window(t_start, t_end, samples):
    ok = [s for s in samples if s["ok"]]
    failed = len(samples) - len(ok)
    stamp = datetime.fromtimestamp(t_end, timezone.utc).strftime("%H:%M:%SZ")
    if ok:
        lat = sorted(s["dt"] for s in ok)
        p50 = lat[len(lat) // 2]
        p95 = lat[min(len(lat) - 1, int(0.95 * len(lat)))]
        tps = sum(s["tokens"] for s in ok) / (t_end - t_start)
        print(f"{stamp} ok={len(ok)} failed={failed} p50={p50:.2f}s p95={p95:.2f}s tok/s={tps:.1f}", flush=True)
    else:
        print(f"{stamp} ok=0 failed={failed}", flush=True)


def run_sustained(url, concurrency, duration, window, max_tokens):
    """Concurrence fixe pendant `duration` s ; une ligne de résumé toutes les `window` s."""
    deadline = time.time() + duration
    lock = threading.Lock()
    samples = []  # (t_fin, résultat)

    def worker():
        while time.time() < deadline:
            r = run_one(url, max_tokens)
            with lock:
                samples.append((time.time(), r))

    threads = [threading.Thread(target=worker, daemon=True) for _ in range(concurrency)]
    t0 = time.time()
    for t in threads:
        t.start()

    win_start = t0
    while win_start < deadline:
        time.sleep(min(window, max(0.0, deadline - win_start)))
        win_end = time.time()
        with lock:
            batch = [r for (t, r) in samples if win_start <= t < win_end]
        _print_window(win_start, win_end, batch)
        win_start = win_end
    for t in threads:
        t.join(timeout=130)  # requêtes en vol : timeout de run_one = 120 s


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default=os.environ.get("VLLM_HOST", "localhost"))
    parser.add_argument("--port", default=8000, type=int)
    parser.add_argument("--max-tokens", default=200, type=int)
    parser.add_argument("--requests-per-level", default=20, type=int)
    parser.add_argument("--levels", default="1,2,4,8,16,32")
    parser.add_argument("--duration", type=int, default=0, help="Mode soutenu : durée en secondes (0 = balayage par niveaux).")
    parser.add_argument("--concurrency", type=int, default=32, help="Mode soutenu : nombre de requêtes simultanées.")
    parser.add_argument("--window", type=int, default=15, help="Mode soutenu : taille de la fenêtre de résumé, en secondes.")
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
    if args.duration > 0:
        print(f"--- Sustained load: {MODEL} @ {url} — concurrency={args.concurrency}, {args.duration}s, window={args.window}s ---", flush=True)
        run_sustained(url, args.concurrency, args.duration, args.window, args.max_tokens)
        return

    levels = [int(x) for x in args.levels.split(",")]

    print(f"--- Load benchmark: {MODEL} @ {url} ---")
    for c in levels:
        had_failures = run_level(url, c, args.requests_per_level, args.max_tokens)
        if had_failures and not args.no_stop_on_failure:
            print(f"\nArrêt du balayage : première défaillance à concurrency={c}")
            break


if __name__ == "__main__":
    main()
