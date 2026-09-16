# Extensions Roadmap — vllm-serving-kubernetes-platform

After the core **12-week roadmap (Weeks 1–6 on local k8s + EKS migration, Weeks 7–12 on AWS EKS)**, the following extensions are planned as distinct sessions, building on the foundation already in place.

## Phase A: MCP Server for Observability Queries

**Objective**: Expose Prometheus and DCGM metrics via Model Context Protocol (MCP), enabling natural language queries over your own infrastructure dashboards.

**Why now**: After Week 4 (Prometheus/Grafana installed), you have a working observability layer. Wrapping it in MCP makes it a reusable interface.

**Scope**:
- MCP server in Python (FastAPI, MCP protocol)
- Query Prometheus directly: TTFT, tokens/s, GPU utilization, cost/1M tokens
- Query DCGM exporter for fine-grained GPU metrics (power, temperature, memory pressure)
- Expose queries as MCP tools: `query_prometheus(query_expr, time_range)`, `get_gpu_metrics(pod_name)`

**Integration**: Claude Code CLI demo + optional remote MCP connector on claude.ai

**Timeline**: 1 session (~2–3 hours) once Prometheus is stable

**Portfolio Signal**: "I can write an MCP server to bridge any infrastructure tool to a conversational interface"

---

## Phase B: RAG over Project Documentation

**Objective**: Build a retrieval-augmented generation layer using your vLLM instance as the inference backend, enabling semantic search over your own deployment docs and operational logs.

**Why now**: You have Mistral 7B inference running reliably. Reusing it for retrieval + generation keeps architecture minimal and showcases vector-based retrieval in Kubernetes.

**Data Sources**:
- Static: README, weekly guides (weeks 1–5), Kubernetes manifests (YAML with comments), Terraform IaC
- Operational: Prometheus query results (6h rolling window), error logs (daily sync)

**Architecture**:
- **Embedding**: Use `nomic-embed-text` in Ollama (CPU-only, local sidecar) or Mistral FP16 embedding capability
- **Vector Store**: Qdrant (standalone container + PVC) or pgvector (if Valeo's PostgreSQL has it enabled)
- **Chunking**: By markdown sections (README), resource blocks (YAML), Terraform blocks (IaC)
- **Retrieval**: Similarity search in vector store, optional reranking
- **Generation**: Prompt → vLLM inference + streaming
- **Evaluation**: RAGAS-style metrics (retrieval precision, generation faithfulness, latency)

**Sequence**:
1. Session 1 (3–4 hours): Qdrant setup + chunking pipeline + ingestion
2. Session 2 (2–3 hours): MCP integration + retrieval loop
3. Session 3 (2 hours): RAGAS test suite + tuning

**Portfolio Signal**: "I built a production RAG system that retrieves from my own infrastructure documentation and serves answers via a conversational interface"

**Key Differentiator**: Cost tracking included — measure cost per query, embedding latency, and showcase it in a dashboard.

---

## Phase C: Evaluation Framework (RAGAS-style)

**Objective**: Measure the quality of your RAG system with automated metrics and golden QA test suites.

**Metrics**:
- **Retrieval Quality**: Precision@K, MRR, whether top-3 chunks are actually relevant
- **Generation Quality**: Faithfulness (does the LLM answer match the retrieved context?), Answer Relevance
- **Latency**: Embedding (ms), vector search (ms), generation (ms), total (ms)
- **Cost**: Tokens used per query, cost per query, cost per 1M tokens

**Implementation**:
- Python test suite using a subset of golden QA pairs (10–20 real questions about your deployment)
- LLM-as-judge or BERTScore/BLEU comparisons for faithfulness
- Benchmark: target ≥ 70% retrieval precision, ≥ 65% generation faithfulness
- Track results in a GitHub CI workflow or Grafana dashboard

**Why This Matters**: Your RAG system is only useful if it actually answers questions accurately. Proving it with metrics is the difference between a demo and a production system.

**Timeline**: 1–2 sessions once RAG is integrated

**Portfolio Signal**: "I evaluated my RAG system rigorously and documented the tradeoffs between speed, cost, and accuracy"

---

## Sequencing & Timeline

| Phase | Sessions | Hours | Depends On | Deliverables |
|-------|----------|-------|-----------|--------------|
| **MCP** | 1 | 2–3 | Week 4 (Prometheus) | MCP server code, README, demo via Claude Code CLI |
| **RAG** | 3 | 7–9 | MCP (optional), Week 1 (vLLM) | Chunking pipeline, Qdrant + pgvector comparison, YAML manifests, RAG-strategy.md |
| **Evaluation** | 1–2 | 2–3 | RAG | Test suite, RAGAS results, cost breakdown |

**Total Additional Work**: ~11–15 hours beyond the core 12-week roadmap, spread across 5–6 independent sessions.

**Why Separate Sessions**: Each phase can stand alone and be deployed independently. RAG doesn't require MCP; MCP doesn't require RAG. This gives you flexibility to ship incrementally.

---

## Deployment Architecture (All Phases on Kubernetes)

All three extensions run as sidecar services or separate deployments within the same EKS cluster (or local kind cluster for development):

```
vllm-namespace/
├── vllm-serving (Deployment + Service)           # Core inference
├── mcp-server (Deployment + Service)             # Phase A
├── qdrant (StatefulSet + PVC)                    # Phase B (RAG vector store)
├── rag-ingestion (CronJob)                       # Phase B (scheduled chunking + embedding)
├── evaluation (Pod / CI runner)                  # Phase C (RAGAS test suite)
└── prometheus (already exists)                   # Observability for all of the above
```

Each can be deployed independently with Terraform and Kubernetes manifests in the repo.

---

## GitHub Structure (Proposed)

```
docs/
├── week-01-baseline.md
├── ...
├── week-05-security.md
├── extensions/
│   ├── MCP-server.md                 # Phase A
│   ├── RAG-strategy.md               # Phase B (detailed architecture)
│   └── evaluation-framework.md       # Phase C
└── EXTENSIONS_ROADMAP.md             # This file

k8s/
├── vllm/
├── mcp/
│   ├── deployment.yaml
│   ├── service.yaml
│   └── configmap.yaml
└── rag/
    ├── qdrant-statefulset.yaml
    ├── qdrant-pvc.yaml
    ├── ingestion-cronjob.yaml
    └── mcp-extended.yaml

terraform/
├── eks/
├── mcp/                              # Phase A (optional separate TF module)
└── rag/                              # Phase B (optional separate TF module)

src/
├── scripts/
├── mcp/
│   ├── server.py                     # Phase A (MCP server)
│   └── prometheus_client.py
└── rag/
    ├── chunking.py                   # Phase B (chunking logic)
    ├── embedding.py
    ├── retrieval.py
    └── qdrant_client.py

tests/
├── test_rag_quality.py               # Phase C (RAGAS test suite)
├── test_mcp_server.py
└── golden_qa_pairs.json

README.md                              # Add link to EXTENSIONS_ROADMAP.md
```

---

## Success Criteria for Each Phase

### Phase A (MCP)
- MCP server responds to `query_prometheus` and `get_gpu_metrics` over stdio or HTTP
- End-to-end test via Claude Code CLI
- README + MCP schema documentation in repo

### Phase B (RAG)
- 500+ chunks ingested into Qdrant (from README + guides + manifests)
- Retrieval precision ≥ 70% on 10–15 golden QA pairs
- Generation faithfulness ≥ 65% (answer matches context, no hallucinations)
- Query latency ≤ 2 seconds (embedding + retrieval + generation)
- Cost breakdown in docs (tokens/query, cost/query)

### Phase C (Evaluation)
- CI workflow runs RAGAS test suite on every commit
- Dashboard showing precision, faithfulness, latency, cost trends
- Documented tradeoffs (speed vs. quality vs. cost)

---

## LinkedIn Angle (All Three Phases)

**Title**: "How I Built a Full-Stack AI Platform on Kubernetes — Serving, Retrieval, and Observability"

**Narrative**:
1. Week 1–5: Local vLLM serving on Kubernetes with autoscaling
2. Week 6–12: Cloud deployment (EKS) + cost optimization
3. Extensions: MCP for obsevability + RAG for documentation + evaluation for rigor

**Why It Works**: it's not just showing how to run vLLM — it's showing how to build a **platform** that serves models, retrieves context, and measures quality. That's typically an AI Platform Engineers work.

---

## Cost Estimate (AWS EKS)

| Component | Monthly Cost |
|-----------|--------------|
| EKS cluster + node group (g5.xlarge) | ~$500–$800 |
| Qdrant (compute, small) | ~$50–$100 |
| Prometheus/Grafana (standard) | ~$100–$200 |
| Data transfer + misc | ~$50 |
| **Total** | **~$700–$1150/month** |

Easily justifiable for a portfolio project. If cost becomes a concern, scale down to a single g5.large (~$150/month node cost) or shut down after demo.

---

## Risks & Mitigation

| Risk | Mitigation |
|------|-----------|
| RAG retrieval returns wrong docs (low precision) | Start with 15 golden QA pairs; tune chunking size and top-k retrieval |
| vLLM hallucination in RAG generation | Use low temperature (0.3), explicitly ask for source citations |
| Qdrant scales poorly (>10k chunks) | Monitor latency; shard by topic or use pgvector if needed |
| MCP server becomes outdated as Prometheus queries change | Treat MCP as API layer — add new queries without breaking old ones |
| Evaluation suite takes too long to run | Subset golden QA pairs to 10–12; run full suite weekly, not per-commit |

---

## Next Step

Once Week 6 is done and the core Kubernetes stack (local kind + EKS) is solid:
1. Schedule **Phase A (MCP)** as your next session (~2–3 hours)
2. Collect 10–15 realistic questions about your deployment for Phase B (RAG) golden QA suite
3. Plan Phase C (Evaluation) as the final polish before LinkedIn publication

---

**Last Updated**: September 13, 2026  
**Author**: Julien (github.com/PhenixForge)