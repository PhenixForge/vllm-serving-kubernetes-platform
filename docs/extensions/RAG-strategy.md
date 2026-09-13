# RAG Extension Strategy — vllm-serving-kubernetes-platform

## Overview

Retrieval-Augmented Generation (RAG) layer for the vLLM serving platform, enabling natural language queries over project documentation and operational logs. Scheduled **after** core Kubernetes/observability stack (weeks 1–5) completes, as a portfolio extension demonstrating retrieval + inference integration.

**Design principle**: Reuse the Mistral 7B vLLM instance already serving inference; don't introduce a separate embedding model. Cost and latency tradeoff: embedding calls go through vLLM's existing API with a dedicated embedding endpoint (vLLM supports embedding out-of-the-box with `--enable-lora` models or external embedding microservice).

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  Frontend (Claude Code CLI / MCP Connector on claude.ai)        │
│  Query: "How do I tune KEDA for GPU utilization?"               │
└──────────────────────────────┬──────────────────────────────────┘
                               │
                    ┌──────────▼─────────────┐
                    │   MCP Server (Python)  │
                    │  - Retrieval engine    │
                    │  - Re-ranking          │
                    │  - Prompt assembly     │
                    └──────────────┬─────────┘
                                   │
                 ┌─────────────────┼─────────────────┐
                 │                 │                 │
         ┌───────▼─────────┐  ┌────▼────────┐  ┌───▼─────────┐
         │  Vector Store   │  │  vLLM API   │  │  Prometheus │
         │(Qdrant/pgvector)│  │(embedding+  │  │   Metrics   │
         │                 │  │ generation) │  │             │
         └─────────────────┘  └─────────────┘  └─────────────┘
                 │                 │                 │
         ┌───────▼────────────────▼──────────────────▼────────┐
         │  Ingestion Pipeline (scheduled, batch)             │
         │  - Chunk project README, guides, manifests         │
         │  - Embed chunks + store vectors + metadata         │
         │  - Index prometheus query results (cost, latency)  │
         └────────────────────────────────────────────────────┘
```

---

## Data Sources

### 1. Static Documentation (High Priority)
- **README.md** — project scope, quick start, architecture diagrams
- **Weekly guides** (week1.md — week5.md) — step-by-step deployment, troubleshooting
- **Kubernetes manifests** — ingress.yaml, deployment.yaml, keda-scaledobject.yaml (inline comments become context)
- **Terraform code** (EKS deployment) — infrastructure decisions, cost implications

### 2. Operational Metrics (Medium Priority)
- **Prometheus metrics** — ingestion every 6 hours; query recent TTFT, tokens/s, GPU util, cost/token
- **CloudWatch logs** (error patterns) — sync daily; identify recurrent issues

### 3. Observability Dashboards (Lower Priority)
- **Grafana dashboard JSON** — query definitions, thresholds, alert rules

---

## Chunking Strategy

**Goal**: Segments large documents into retrievable, self-contained context chunks that fit Mistral 7B's context window without losing semantic coherence.

### Static Documentation Chunks

| Source | Chunk Unit | Size Target | Metadata |
|--------|------------|-------------|----------|
| README | Section (## headers) | 300–800 tokens | filename, section_id, toc_heading |
| Weekly guides | Subsection or task | 200–600 tokens | week_number, topic, difficulty_level |
| Manifests | Single resource definition | 100–400 tokens | kind (Deployment/Ingress/etc), namespace, labels |
| Terraform | Resource block | 150–500 tokens | resource_type, variable_name, output_id |

### Operational Chunks

| Source | Chunk Unit | Refresh | Metadata |
|--------|------------|---------|----------|
| Prometheus metrics | Query result (last 6h rolling window) | Every 6h | metric_name, time_range, aggregation |
| Error logs | Log line + context (±5 lines) | Daily | severity, service, timestamp_iso |

**Chunking Implementation** (Python, sync to Qdrant/pgvector):
```python
# Pseudo-code
import tiktoken

def chunk_markdown(filepath, chunk_size_tokens=500, overlap_tokens=100):
    """Chunk markdown by headers; keep section hierarchy."""
    enc = tiktoken.encoding_for_model("mistral-7b")
    # Tokenize; split on ## headers if > chunk_size
    # Each chunk includes:
    # - content (text)
    # - source_file, section_id
    # - tokens (for billing)
    return chunks

def chunk_yaml(filepath, chunk_size_tokens=300):
    """Each K8s resource as separate chunk."""
    # Parse YAML; iterate resources
    # Each chunk: full resource + comments + namespace context
    return chunks
```

---

## Embedding Model & Vector Store

### Embedding Model

**Option A: vLLM's Native Embedding (Recommended for cost)**
- Use Mistral 7B's embedding capability (if available in the vLLM version used)
- Fallback: **Ollama** running locally with `nomic-embed-text` (small, fast, no GPU req'd)
- Embedding dimension: 384 (nomic) or 4096 (Mistral FP16)
- Batch embedding every 6 hours for new docs; on-demand for user queries

**Option B: External SentenceTransformers (CPU-only)**
- Model: `sentence-transformers/all-MiniLM-L6-v2` (fast, 384-dim)
- Runs in a sidecar container; negligible CPU cost

### Vector Store: Qdrant vs pgvector

| Aspect | Qdrant | pgvector |
|--------|--------|----------|
| **Deployment** | Standalone container + PVC | PostgreSQL extension (existing DB) |
| **Cost** | Separate infra | Reuse Valeo's PostgreSQL |
| **Ease of Setup** | 5 min (Helm chart) | Terraform + SQL migrations |
| **Scalability** | Good for 10k–1M vectors | Depends on Postgres instance |
| **Reranking** | Tightly integrated | Manual implementation |
| **Portfolio Signal** | "Full-stack vector DB" | "Production-grade integration" |

**Decision**: Start with **Qdrant** (simpler deployment, self-contained), migrate to **pgvector** if Valeo's PostgreSQL already has it enabled and you need tighter integration.

---

## Retrieval Pipeline

### Query Flow (User asks a question via MCP)

1. **Embedding** — embed user query with same model as corpus
2. **Similarity Search** — Qdrant: vector search (cosine similarity, top-10 candidates)
3. **Reranking** — optional; use a cross-encoder or heuristic (e.g., BM25 + vector score)
4. **Context Assembly** — concatenate top-3 chunks + metadata; total ≤ 4000 tokens (leave room for prompt + response)
5. **Prompt Construction**:
   ```
   You are a Kubernetes/vLLM infrastructure assistant. 
   Context from documentation:
   {retrieved_chunks}

   Question: {user_query}
   Answer concisely with links to relevant sections.
   ```
6. **Generation** — vLLM inference (Mistral 7B, streaming over MCP)
7. **Logging** — track query, retrieved chunks, answer latency, embedding tokens

---

## Integration with MCP Server

Extend the existing MCP server (from "Extensions: Serveur MCP" phase) to expose two endpoints:

```python
# mcp_server/rag.py

@mcp.tool()
def query_documentation(question: str, top_k: int = 3) -> dict:
    """Query RAG over project docs. Returns answer + sources."""
    # 1. Embed question
    embedding = embed_api(question)
    
    # 2. Search vector store
    results = qdrant_client.search(
        collection_name="vllm_docs",
        query_vector=embedding,
        limit=top_k,
        with_payload=True  # return metadata
    )
    
    # 3. Format retrieved chunks
    context = format_context(results)
    
    # 4. Call vLLM
    response = vllm_client.completions(
        model="mistral-7b",
        prompt=format_prompt(question, context),
        max_tokens=500,
        temperature=0.3
    )
    
    # 5. Return answer + provenance
    return {
        "answer": response.text,
        "sources": [r.payload for r in results],
        "latency_ms": elapsed,
        "tokens_used": response.usage.total_tokens
    }

@mcp.tool()
def ingest_documentation(file_path: str) -> dict:
    """Manually ingest or re-index a documentation file."""
    chunks = chunk_markdown(file_path)
    embeddings = [embed_api(chunk.text) for chunk in chunks]
    qdrant_client.upsert(
        collection_name="vllm_docs",
        points=[
            Point(
                id=uuid4(),
                vector=emb,
                payload={"text": chunk.text, "source": file_path, "metadata": chunk.metadata}
            )
            for chunk, emb in zip(chunks, embeddings)
        ]
    )
    return {"chunks_ingested": len(chunks), "collection": "vllm_docs"}
```

**MCP Schema** (expose to Claude):
- `query_documentation(question, top_k)`
- `ingest_documentation(file_path)` — for ops (re-index after README update)

---

## Evaluation Strategy (RAGAS-Style)

Measure RAG quality post-deployment using RAGAS (Retrieval-Augmented Generation Assessment) framework or simplified custom metrics.

### Metrics

1. **Retrieval Quality**
   - **Precision@K** — % of top-3 chunks actually relevant to query (manual label 10–20 queries)
   - **MRR** (Mean Reciprocal Rank) — ranking quality
   
2. **Generation Quality**
   - **Faithfulness** — does the LLM answer match retrieved chunks (no hallucinations)?
   - **Answer Relevance** — does the answer directly address the question?
   
3. **Latency & Cost**
   - **Embedding latency** (ms/query)
   - **Retrieval latency** (vector search)
   - **Generation latency** (vLLM)
   - **Cost per query** (tokens × pricing)

### Implementation (Python Test Suite)

```python
# tests/test_rag_quality.py

GOLDEN_QA_PAIRS = [
    {
        "query": "How do I tune KEDA pod scaling for GPU workloads?",
        "expected_sections": ["keda-scaledobject.yaml", "week 4 guide"],
        "ground_truth": "KEDA scales based on Prometheus queue depth metric..."
    },
    # ... 15–20 more pairs
]

def test_retrieval_precision():
    """Retrieve for each query; check % relevant in top-3."""
    relevant_count = 0
    for qa in GOLDEN_QA_PAIRS:
        results = query_qdrant(qa["query"], top_k=3)
        chunks = [r.payload["source"] for r in results]
        relevant = [c for c in chunks if c in qa["expected_sections"]]
        relevant_count += len(relevant) / 3
    
    precision = relevant_count / len(GOLDEN_QA_PAIRS)
    assert precision > 0.7, f"Retrieval precision {precision} below 0.7"

def test_generation_faithfulness():
    """Run each query; check answer vs ground truth."""
    for qa in GOLDEN_QA_PAIRS:
        answer = query_documentation(qa["query"])["answer"]
        # LLM-as-judge or BLEU/BERTScore comparison
        score = evaluate_faithfulness(answer, qa["ground_truth"])
        assert score > 0.65, f"Faithfulness {score} for '{qa['query']}'"
```

---

## Timeline & Sequencing

### Phase Ordering (After Weeks 1–5 Core Complete)

**Session N+1: RAG Foundation** (3–4 hours)
1. Set up Qdrant container (Helm chart on local kind cluster)
2. Implement chunking pipeline (README → test chunks)
3. Embed + ingest first 500 chunks
4. Prototype retrieval loop (manual MCP tool test)

**Session N+2: Integration & MCP** (2–3 hours)
1. Wire RAG into existing MCP server
2. Add `query_documentation` + `ingest_documentation` endpoints
3. Test via Claude Code CLI with real questions
4. Document MCP schema for claude.ai connector

**Session N+3: Evaluation & Polish** (2 hours)
1. Build RAGAS test suite (10–15 golden QA pairs)
2. Measure retrieval precision & generation faithfulness
3. Tune `top_k`, chunking size, reranking if needed
4. Write user guide (GitHub docs/rag-usage.md)

---

## Deployment Architecture (EKS)

```yaml
# k8s/rag/namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: vllm-rag

---
# k8s/rag/qdrant-statefulset.yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: qdrant
  namespace: vllm-rag
spec:
  serviceName: qdrant
  replicas: 1
  selector:
    matchLabels:
      app: qdrant
  template:
    metadata:
      labels:
        app: qdrant
    spec:
      containers:
      - name: qdrant
        image: qdrant/qdrant:latest
        ports:
        - containerPort: 6333
        volumeMounts:
        - name: qdrant-data
          mountPath: /qdrant/storage
  volumeClaimTemplates:
  - metadata:
      name: qdrant-data
    spec:
      accessModes: [ "ReadWriteOnce" ]
      resources:
        requests:
          storage: 10Gi

---
# k8s/rag/mcp-server-deployment.yaml (extended from prior MCP phase)
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mcp-server
  namespace: vllm-rag
spec:
  replicas: 2
  selector:
    matchLabels:
      app: mcp-server
  template:
    metadata:
      labels:
        app: mcp-server
    spec:
      containers:
      - name: mcp
        image: <your-registry>/mcp-server:latest
        ports:
        - containerPort: 8001
        env:
        - name: VLLM_API_URL
          value: "http://vllm-service.vllm:8000"
        - name: QDRANT_URL
          value: "http://qdrant.vllm-rag:6333"
        - name: LOG_LEVEL
          value: "INFO"
        resources:
          requests:
            memory: "512Mi"
            cpu: "500m"
          limits:
            memory: "1Gi"
            cpu: "1"
```

---

## Cost Analysis (Weekly)

**Assumptions**:
- 100 queries/week from internal users (Claude + analysts)
- Avg 50 tokens per query embedding
- Avg 200 tokens per retrieved context
- Avg 150 tokens per generated answer

**Cost Breakdown**:
| Component | Tokens/Week | Cost (Mistral pricing) |
|-----------|-------------|----------------------|
| Embeddings (query + docs) | 3,000 | ~$0.005 |
| vLLM generation | 15,000 | ~$0.008 |
| Vector store (Qdrant) | Compute only | ~$0.50 (local container) |
| Prometheus queries | Metrics only | $0 (in-cluster) |
| **Total** | — | **~$0.50–$1/week** |

Portfolio narrative: "Cost-optimized RAG layer demonstrating Kubernetes cost observability at scale."

---

## Risk & Mitigations

| Risk | Mitigation |
|------|-----------|
| Chunking loses context (e.g., interdependent manifests) | Keep chunk overlap at 100 tokens; include backlinks in metadata |
| Retrieval returns wrong docs (low precision) | Start with 10–15 golden QA pairs; tune `top_k` and embedding model |
| Generation hallucinates beyond context | Use temperature=0.3; explicitly ask vLLM to cite sources |
| Vector store scales poorly (10k+ chunks) | Monitor Qdrant latency; shard by topic if > 50k chunks |
| Qdrant downtime breaks MCP queries | Fallback to BM25 keyword search (local index) or document redirect |

---

## Success Criteria (Definition of Done)

- ✅ Qdrant + MCP server deployed on local kind cluster
- ✅ RAGAS evaluation: Retrieval precision ≥ 0.70, Generation faithfulness ≥ 0.65
- ✅ Query latency ≤ 2 seconds (embedding + retrieval + generation, streaming)
- ✅ End-to-end test: User query via Claude Code CLI → MCP server → Qdrant + vLLM → Answer with sources
- ✅ README + tests in GitHub repo
- ✅ LinkedIn post: "Building a retrieval layer over vLLM on Kubernetes" (portfolio impact)

---

## References & Resources

- **RAGAS Framework**: https://github.com/explodinggradients/ragas
- **Qdrant Helm Charts**: https://github.com/qdrant/qdrant-helm
- **Sentence Transformers**: https://www.sbert.net/
- **vLLM Embedding API**: https://docs.vllm.ai/en/latest/features/embeddings.html
- **Mistral 7B Context**: https://docs.mistral.ai/capabilities/function_calling/