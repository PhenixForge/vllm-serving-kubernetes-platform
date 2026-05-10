# vllm-serving-kubernetes-platform

Production-grade LLM serving on Kubernetes for enterprise environments — vLLM inference, GPU autoscaling, security hardening, full observability and cost tracking. Documented end-to-end by a senior infrastructure engineer.

Production-grade LLM serving platform on Kubernetes — vLLM inference, GPU autoscaling with Karpenter, security hardening, full observability (Prometheus, DCGM, Grafana) and cost tracking. 

Built on Ministral 3 (Mistral AI) for sovereignty and solidarity to the french ecosystem.

Documented end-to-end by a senior infrastructure DevOps / SysOps.


## Status

Week 1/12 — WIP

## Roadmap

- [x] Week 1: local vLLM inference working (Ministral 7B on NVIDIA RTX 4060)
- [ ] Week 2: containerized vLLM, OpenAI-compatible API tested
- [ ] Week 3-4: Kubernetes deployment (kind), basic monitoring
- [ ] Week 5-6: migration to EKS with GPU nodes (g5.xlarge), Karpenter
- [ ] Week 7-8: KEDA autoscaling on queue depth, load testing
- [ ] Week 9-10: full observability (Prometheus, DCGM, Grafana dashboards)
- [ ] Week 11-12: architecture diagrams, lessons-learned post

## Stack

- **Model**: Ministral 7B Instruct (Mistral AI, Apache 2.0)
- **Inference server**: vLLM
- **Orchestration**: Kubernetes (kind → EKS)
- **GPU autoscaling**: Karpenter + KEDA
- **Observability**: Prometheus, DCGM Exporter, Grafana

## Author

Senior Infrastructure Engineer transitioning into AI infrastructure (May 2026)
Documenting the full journey publicly — including dead ends.