import time, requests, statistics
import os

HOST = os.environ.get("VLLM_HOST", "192.168.1.24")
URL = f"http://{HOST}:8000/v1/chat/completions"

MODEL = "TheBloke/Mistral-7B-Instruct-v0.2-AWQ"
URL   = "http://192.168.1.24:8000/v1/chat/completions"
PROMPT = "List 5 Kubernetes best practices for resource limits."

latencies = []
for i in range(20):
    t0 = time.time()
    r  = requests.post(URL, json={
        "model": MODEL,
        "messages": [{"role": "user", "content": PROMPT}],
        "max_tokens": 200
    })
    dt = time.time() - t0
    latencies.append(dt)
    tokens = r.json()["usage"]["completion_tokens"]
    print(f"Run {i+1:02d}: {dt:.2f}s | {tokens} tokens | {tokens/dt:.1f} tok/s")

s = sorted(latencies)
print(f"\n--- Baseline Mistral-7B AWQ on RTX 4060 ---")
print(f"Mean : {statistics.mean(latencies):.2f}s")
print(f"P50  : {statistics.median(latencies):.2f}s")
print(f"P95  : {s[int(0.95*len(s))]:.2f}s")