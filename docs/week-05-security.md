# Week 5 — Security Hardening & Production Readiness

Full write-up (network policies, SecurityContext, secrets management, HA/probes) lives in [`week5 guide.md`](../week5%20guide.md) at the repo root. This page only tracks what comes after the core platform is done.

## Next Steps: Extensions

Once the core Kubernetes platform is stable (Weeks 1–6, including the EKS migration), three independent extensions are planned:

- **MCP Server** (1 session): Expose Prometheus/DCGM metrics via Claude — [docs/extensions/MCP-server.md](extensions/MCP-server.md)
- **RAG Layer** (3 sessions): Query documentation semantically with Qdrant + vLLM — [docs/extensions/RAG-strategy.md](extensions/RAG-strategy.md)
- **Evaluation** (1–2 sessions): Measure RAG quality with RAGAS — [docs/extensions/evaluation-framework.md](extensions/evaluation-framework.md)

See [`EXTENSIONS_ROADMAP.md`](extensions/EXTENSIONS_ROADMAP.md) for sequencing and success criteria.