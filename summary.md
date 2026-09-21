# vllm-serving-kubernetes-platform

Production-grade LLM serving on Kubernetes for enterprise environments — vLLM inference, GPU autoscaling, security hardening, full observability and cost tracking. Documented end-to-end by a senior infrastructure engineer.

Production-grade LLM serving platform on Kubernetes — vLLM inference, GPU autoscaling with Karpenter, security hardening, full observability (Prometheus, DCGM, Grafana) and cost tracking. 

Built on Mistral 7B Instruct v0.1 AWQ (Mistral AI) for sovereignty and solidarity to the french ecosystem.

Documented end-to-end by a senior infrastructure DevOps / SysOps.


## Status

Week 6/12 — in progress (last updated 2026-09-21; real dates and per-week validation in [README.md](README.md#timeline--how-to-read-this-repo))
Core Platform: Weeks 1–6 (local k8s + EKS)
Extensions: RAG + MCP + Evaluation (separate sessions, post-Week-6)

## Roadmap

- [x] Week 1: local vLLM inference working (Mistral 7B AWQ Marlin on NVIDIA RTX 4060)
- [x] Week 2: containerized vLLM, OpenAI-compatible API tested
- [x] Week 3: Kubernetes deployment (kind), GPU passthrough, Ingress + SSE streaming, KEDA autoscaler wired (Prometheus trigger pending Week 4)
- [x] Week 4: full observability (Prometheus, DCGM, Grafana dashboards), benchmarking, GPU resource management
- [x] Week 5: security hardening (NetworkPolicies, non-root SecurityContext, secrets review, graceful shutdown, Ingress auth + rate limiting)
- [ ] Week 6: migration to EKS with GPU nodes (g5.xlarge), Karpenter — Terraform + EKS Kubernetes manifests written/validated, not applied/deployed (no credentials, real cost)
- [ ] Week 7-8 (prepared offline 2026-09-21, see docs/week7 guide.md; runs after the Week 6 apply): prove on EKS the KEDA queue-depth autoscaling already validated on kind (Week 4), load testing on cloud GPUs
- [ ] Week 9-10: replicate the Week 4 observability stack on EKS + cost per 1M tokens panel
- [ ] Week 11-12: architecture diagrams, lessons-learned post

## Stack

- **Model**: Mistral-7B-Instruct-v0.1-AWQ (Mistral AI, Apache 2.0)
- **Inference server**: vLLM
- **Orchestration**: Kubernetes (kind → EKS)
- **GPU autoscaling**: Karpenter + KEDA
- **Observability**: Prometheus, DCGM Exporter, Grafana

## Author

Senior Infrastructure Engineer transitioning into AI infrastructure (since April 2026) ;
Documenting the full journey publicly — including dead ends.