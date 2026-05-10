````markdown
# vllm-serving-kubernetes-platform

Production-grade LLM serving platform on Kubernetes — vLLM inference, GPU autoscaling with Karpenter and KEDA, full observability (Prometheus, DCGM, Grafana). Built on Mistral open-weight models. Documented end-to-end by a senior infrastructure engineer learning AI infrastructure in public.

---

## Status

**Week 1/12 — complete**

Local vLLM inference running on a single RTX 4060 (8 GB VRAM) with Mistral 7B Instruct v0.2 AWQ quantization. Baseline latency and throughput metrics captured.

---

## Architecture (target)

```
┌─────────────┐     ┌──────────────────────────────────────────┐
│   Client    │────▶│              Kubernetes (EKS)           │
└─────────────┘     │                                          │
                    │  ┌──────────┐      ┌─────────────────┐   │
                    │  │  Service │────▶│   vLLM Pods     │   │
                    │  └──────────┘      │  Mistral 7B     │   │
                    │                    │  (GPU nodes)    │   │
                    │  ┌──────────┐      └────────┬────────┘   │
                    │  │  KEDA    │               │            │
                    │  │ (scale   │◀─────────────┘            │
                    │  │  pods)   │                            │
                    │  └──────────┘                            │
                    │                                          │
                    │  ┌──────────┐      ┌─────────────────┐   │
                    │  │Karpenter │      │   Prometheus    │   │
                    │  │(scale    │      │   DCGM Exporter │   │
                    │  │ nodes)   │      │   Grafana       │   │
                    │  └──────────┘      └─────────────────┘   │
                    └──────────────────────────────────────────┘
```

---
## Mermaid diagram

```mermaid

graph TB
    Client(["🖥️ Client\n(OpenAI-compatible API)"])

    subgraph Local["Local — Fedora Silverblue 44"]
        Podman["Podman Container\nvLLM 0.20.2"]
        GPU1["NVIDIA RTX 4060\n8 GB VRAM"]
        Model1["Mistral 7B Instruct\nAWQ 4-bit"]
        Podman --> GPU1
        Podman --> Model1
    end

    subgraph EKS["AWS EKS — Target Architecture"]
        direction TB

        subgraph Serving["Inference Layer"]
            Service["Kubernetes Service\n(LoadBalancer)"]
            Pod1["vLLM Pod"]
            Pod2["vLLM Pod"]
            Pod3["vLLM Pod\n(scaled)"]
            Service --> Pod1
            Service --> Pod2
            Service -.->|"scale-out"| Pod3
        end

        subgraph Scaling["Autoscaling Layer"]
            KEDA["KEDA\nPod autoscaler\n(queue depth)"]
            Karpenter["Karpenter\nNode autoscaler\n(GPU nodes)"]
            KEDA -.->|"scale pods"| Pod3
            Karpenter -.->|"provision\ng5.xlarge"| GPU2
        end

        subgraph Nodes["GPU Nodes"]
            GPU2["NVIDIA A10G\n24 GB VRAM\n(g5.xlarge)"]
            Model2["Mistral 7B Instruct\nFP16"]
            GPU2 --> Model2
        end

        subgraph Observability["Observability Layer"]
            DCGM["DCGM Exporter\nGPU metrics"]
            Prometheus["Prometheus\nMetrics store"]
            Grafana["Grafana\nDashboard"]
            DCGM -->|"gpu_util\nttft\nthroughput"| Prometheus
            Prometheus --> Grafana
        end

        subgraph IaC["Infrastructure as Code"]
            Terraform["Terraform\nEKS + Karpenter\n+ node groups"]
        end

        Pod1 -->|"metrics"| DCGM
        Pod2 -->|"metrics"| DCGM
    end

    Client -->|"Week 1 ✅"| Podman
    Client -->|"Week 5-6 🎯"| Service
    Terraform -.->|"provisions"| EKS

    classDef done fill:#1a7a4a,color:#fff,stroke:#0f5c35
    classDef target fill:#1a3a6b,color:#fff,stroke:#0f2a52
    classDef infra fill:#5a3e1b,color:#fff,stroke:#3d2a10
    classDef obs fill:#5a1b3e,color:#fff,stroke:#3d0f2a

    class Podman,GPU1,Model1 done
    class Service,Pod1,Pod2,Pod3,GPU2,Model2 target
    class KEDA,Karpenter,Terraform infra
    class DCGM,Prometheus,Grafana obs
```

---

## Stack

| Layer | Technology |
|---|---|
| Model | Mistral 7B Instruct v0.2 (Apache 2.0) |
| Inference server | vLLM 0.20.2 |
| Container runtime | Podman (Fedora Silverblue 44) |
| Orchestration | Kubernetes — kind (local) → EKS (cloud) |
| Node autoscaling | Karpenter |
| Pod autoscaling | KEDA (queue depth metric) |
| GPU observability | DCGM Exporter + Prometheus + Grafana |
| Infrastructure as code | Terraform |
| Hardware (local) | NVIDIA RTX 4060 8 GB VRAM |
| Hardware (cloud) | NVIDIA A10G 24 GB VRAM (g5.xlarge) |

---

## Roadmap

- [x] **Week 1** — local vLLM inference working (Mistral 7B AWQ on RTX 4060, baseline metrics captured)
- [ ] **Week 2** — clean Containerfile, all OpenAI-compatible endpoints tested
- [ ] **Week 3-4** — Kubernetes deployment on kind (local), Deployment + Service + ConfigMap manifests
- [ ] **Week 5-6** — migration to EKS with GPU nodes (g5.xlarge), Karpenter node autoscaling
- [ ] **Week 7-8** — KEDA pod autoscaling on queue depth, load testing with latency benchmarks
- [ ] **Week 9-10** — full observability stack (Prometheus, DCGM, Grafana dashboard: TTFT, GPU util, throughput, cost per 1M tokens)
- [ ] **Week 11-12** — architecture diagrams, clean README, lessons-learned article

---

## Week 1 — lessons learned

Getting vLLM running on a consumer GPU involved several non-obvious constraints worth documenting.

**Model format matters more than model size.** Mistral 7B in FP16 requires ~14 GB VRAM — impossible on a 8 GB card. The AWQ 4-bit quantized version fits in ~4 GB and delivers usable throughput. Understanding the difference between FP16, BF16, FP8, and AWQ quantization is a prerequisite for any AI infrastructure work.

**Fedora Silverblue requires a different mental model.** The immutable OS means no `dnf install` — everything goes through `rpm-ostree` with a mandatory reboot. The NVIDIA Container Toolkit SSL configuration needed manual adjustment because rpm-ostree runs in an isolated context that cannot access the system CA bundle at the expected path. Toolbox containers do not have GPU access by default — vLLM runs in a dedicated Podman container launched from the host, not from inside toolbox.

**Baseline metrics (Mistral 7B AWQ, RTX 4060, context 2048 tokens):** to be updated after benchmark run.

---

## Observability targets

The goal is a Grafana dashboard tracking four key metrics in production:

- **TTFT** (time to first token) — P50 and P95
- **Throughput** — tokens per second per GPU
- **GPU utilization** — via DCGM Exporter
- **Cost efficiency** — estimated cost per 1M tokens based on cloud instance pricing

---

## Why Mistral

This project deliberately uses Mistral open-weight models rather than Meta's Llama or Alibaba's Qwen. Mistral AI is a Paris-based lab building sovereign European AI infrastructure — using and documenting their models in production is a concrete way to support that ecosystem. All models used in this project are released under the Apache 2.0 license.

---

## Author

Senior Infrastructure Engineer (AWS, Kubernetes, Terraform, GPU observability) transitioning into AI infrastructure.
Documenting the full journey publicly — including dead ends, wrong turns, and real production constraints.

[LinkedIn](https://www.linkedin.com/in/julien-p-68834731/) · [GitHub](https://github.com/PhenixForge)
````