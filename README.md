[![Status](https://img.shields.io/badge/status-Week_6%2F12-orange)](#status)
[![CI](https://github.com/PhenixForge/vllm-serving-kubernetes-platform/actions/workflows/ci.yml/badge.svg)](https://github.com/PhenixForge/vllm-serving-kubernetes-platform/actions/workflows/ci.yml)
[![Versions verified](https://img.shields.io/badge/versions_verified-2026--09--21-green)](#version-policy--provisioning-without-toil)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-1.36_(EKS_target)-326CE5?logo=kubernetes&logoColor=white)](https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html)
[![Terraform](https://img.shields.io/badge/Terraform-%E2%89%A51.7-844FBA?logo=terraform&logoColor=white)](terraform/)
[![Karpenter](https://img.shields.io/badge/Karpenter-1.14.1-blue)](terraform/karpenter.tf)
[![vLLM](https://img.shields.io/badge/vLLM-0.20.2-blueviolet)](container/Containerfile)
[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![LinkedIn](https://img.shields.io/badge/LinkedIn-Julien-blue?logo=linkedin)](https://www.linkedin.com/in/julien-p-68834731/?locale=fr)

# Production-grade LLM serving platform on Kubernetes

vLLM model serving platform on Kubernetes — vLLM inference, GPU autoscaling with Karpenter and KEDA, with full observability (Prometheus, DCGM, Grafana) and costs tracking.

Built on Mistral open-weight models. 

Documented end-to-end by a senior infrastructure engineer learning AI infrastructure in public.

---

## Status

**Week 6/12 — in progress** · last updated 2026-09-28 (see [Timeline](#timeline--how-to-read-this-repo))

Local vLLM inference running on a single personal Nvidia graphic card (RTX 4060 with 8 GB VRAM) from a Docker container, with Mistral 7B Instruct v0.1 AWQ quantization. Baseline latency and throughput metrics captured.

Deployed on a local Kubernetes cluster (kind) with GPU passthrough: Deployment, Service, Ingress (SSE streaming validated end-to-end), PVC and KEDA autoscaling manifests applied.

Full observability stack live: Prometheus + DCGM Exporter (GPU metrics) + Grafana dashboard. KEDA's Prometheus trigger is now healthy end-to-end (`HPAActive=True`). Load benchmarking swept up to 128 concurrent requests with zero failures — vLLM's scheduler throttles admission under KV cache pressure (99.5% usage observed) instead of OOMing.

Security hardening done: `vllm-server` runs non-root (UID 1000), no capabilities, read-only root filesystem, no `privileged`. NetworkPolicies written and applied (inert on this cluster's CNI — no policy engine, documented). Ingress locked down with Basic Auth + rate limiting.

EKS migration: Terraform written for VPC + EKS + Karpenter-managed GPU node pool (see [`terraform/`](terraform/)) — validated (`init`/`validate`/`plan` up to the expected missing-credentials wall) but **not applied**. EKS-specific Kubernetes manifests also written (see [`kubernetes-eks/`](kubernetes-eks/) — no manual GPU passthrough needed there, unlike `kind`) but not yet deployed to a real cluster. No AWS credentials configured yet, and standing up real GPU nodes costs real money — that step is deliberately left for a deployer with an AWS account and budget sign-off, not run automatically.

---

## Timeline — how to read this repo

This is a **multi-month, part-time project**, not a 12-calendar-week sprint. "Week N" is a unit of *content* inherited from the original plan; the dates below are the real ones (from the commit history).

| Period | What happened |
|---|---|
| 2026-05-09 → 05-11 | Week 1 — local vLLM inference, baseline benchmark, README |
| 2026-05-26 → 07-03 | Week 2 — containerisation (`Containerfile`, GPU tuning on 06-30, OpenAI-compatible chat), Week 1–2 guides and feedback |
| 2026-07-03 → 08-18 | Gap in commits; documentation pass on 2026-08-18 (guides for Weeks 1–5, incl. the new Week 5 security guide) |
| 2026-09-13 → 09-17 | Weeks 3–6 in one focused stretch — Kubernetes on kind, observability, security hardening, EKS Terraform |
| 2026-09-21 | Terraform/EKS re-verified and moved to Kubernetes 1.36 (see below) |
| 2026-09-28 | CI pipeline added (GitHub Actions: YAML lint, `terraform fmt`/`validate`, Containerfile lint, image build+push to GHCR on merge to `main`) — see [`.github/workflows/ci.yml`](.github/workflows/ci.yml) |

### Validated so far — nothing here restarts from zero

Each week below was validated when it was done, and the result is committed. The next stages build on these; they do not redo them. The commit history is kept as-is (no rewriting), so the dates below are the real ones.

| Week | Dates | Commits | Validated by | Carries over to EKS |
|---|---|---|---|---|
| 1 | 2026-05-09 | `77b313e`, `d4ab0e4` | Baseline latency/throughput captured ([`week-01-baseline.md`](docs/week-01-baseline.md)) | Benchmark script, model choice |
| 2 | 2026-05-26 → 07-03 | `5dafe1e`, `0f8befd`, `e965b81`…`dfd515e` | Containerised vLLM answering OpenAI-compatible requests | `container/Containerfile` (image pushed to ECR) |
| 3 | 2026-09-13 → 09-15 | `c0ae78a`…`44f1db3`, closed by `fba5c9d` | Real inference from a pod on kind (2026-09-14); Ingress + SSE streaming; validation closed 2026-09-15 | Service, PVC, ConfigMap, Ingress manifests |
| 4 | 2026-09-16 | `b17cdbe` | KEDA `HPAActive=True` on a live Prometheus value; 128 concurrent requests, 0 failures | Prometheus, Grafana, KEDA `ScaledObject`, DCGM (EKS variant) |
| 5 | 2026-09-16 | `d1490b1` | Non-root inference end to end; Basic Auth 401/401/200; ~7 s graceful shutdown; NetworkPolicy inertness proven on kindnet | `network-policy.yaml` unchanged (enforced by VPC CNI on EKS), hardened Deployment |
| 6 | 2026-09-17, revised 2026-09-21 | `6405b71`*, `be4b0a6` | `terraform init` + `validate` green; `plan` stops at the expected missing-credentials wall — **not applied** | — (this is the new work) |

\* The message of `6405b71` reads "week5: Terraform code" but the content is the Week 6 Terraform; history was not rewritten to change it.

What is left is genuinely new: the real `apply`, then proving on EKS what was already proven on kind (KEDA scaling and load testing on cloud GPUs, the same observability stack, cost per 1M tokens).

Consequences for the reader, and for the maintainer:

- **Everything is a dated snapshot.** Versions, support windows and "latest" claims are true *as of the date stated next to them*; upstream moves on during a months-long project (the EKS/Terraform layer had drifted from the versions first pinned by the time it was reviewed — see the Week 6 lessons). Each week's notes are a chronological log, not a description of the current state — the current state is this README and the manifests.
- **Re-verify before you provision.** The EKS layer was written months before any real `apply` is expected. A pre-apply checklist (support calendar, compatibility matrix, current module/provider versions) lives in [`terraform/README.md`](terraform/README.md#avant-de-lancer-un-apply--re-vérifier-les-versions).
- **Deferred work is deliberate, not forgotten.** The real `apply` needs AWS credentials and a budget sign-off; extensions (MCP, RAG, evaluation, Vault, Packer) are scheduled after the core project — see [`docs/extensions/EXTENSIONS_ROADMAP.md`](docs/extensions/EXTENSIONS_ROADMAP.md).

---

## Version policy — provisioning without toil

The provisioned layer targets the **current** Kubernetes release, checked against the official AWS documentation rather than assumed, so the demo doesn't ship already deprecated:

- **Kubernetes 1.36** — the newest EKS version in standard support at the time of writing, per the [EKS Kubernetes versions page](https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html). Standard support lasts 14 months, then paid extended support: creating a cluster on an older version buys an upgrade chore (and a surcharge) on day one.
- **Amazon Linux 2023 nodes** — EKS stopped publishing AL2 AMIs after Kubernetes 1.32, so AL2 was never an option for a current cluster.
- **Compatibility checked ahead of the apply** — Karpenter's compatibility matrix (1.36 needs Karpenter ≥ 1.13; the chart is pinned at 1.14.1), the EKS 1.36 release notes (removed/deprecated features such as `gitRepo` volumes and `externalIPs`, containerd 2.x requirement) and the current Terraform provider/module majors, all queried against the live registries.
- **Deliberate drift from the local cluster** — `kind` stays on an older version for the Week 3–5 work; the cloud target does not inherit it.

Why this matters (SRE): a forced upgrade, an unsupported AMI family or a surprise extended-support bill discovered *after* deployment is pure toil — repetitive, manual, automatable-away work with no lasting value. Reading the release calendar and compatibility matrices before provisioning removes it at the source. `terraform validate` cannot catch any of this (a valid config can still target an end-of-life version); it only shows up at apply time, or on the bill. Details and the exact corrections in [`docs/week-06-notes.md`](docs/week-06-notes.md).

Scope note: this policy is applied to the EKS/Terraform layer. Application-layer images in `kubernetes/` (Prometheus, Grafana, ingress controller, DCGM) were pinned during Weeks 3–5 and are being reviewed against the same rule — the ingress controller is the priority, since the upstream ingress-nginx project has been archived.

---

## Architecture (target)

```
┌─────────────┐      ┌──────────────────────────────────────────┐
│   Client    │────▶│             Kubernetes (EKS)             │
└─────────────┘      │                                          │
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
                     │  │ (scale   │      │   DCGM Exporter │   │
                     │  │ nodes)   │      │   Grafana       │   │
                     │  └──────────┘      └─────────────────┘   │
                     └──────────────────────────────────────────┘
```

---
## Mermaid diagram

```mermaid
graph TB

    Client["Client API"]

    subgraph Local["Local Fedora 44"]
        Podman["Podman Container"]
        GPU1["RTX 4060"]
        Model1["Mistral 7B AWQ"]

        Podman --> GPU1
        Podman --> Model1
    end

    subgraph EKS["AWS EKS"]

        EKSRoot["EKS Cluster"]

        subgraph Serving["Inference"]
            Service["Kubernetes Service"]

            Pod1["vLLM Pod"]
            Pod2["vLLM Pod"]

            Service --> Pod1
            Service --> Pod2
        end

        subgraph Scaling["Autoscaling"]
            KEDA["KEDA"]
            Karpenter["Karpenter"]

            KEDA -.-> Pod2
            Karpenter -.-> GPU2
        end

        subgraph Nodes["GPU Nodes"]
            GPU2["A10G"]
            Model2["Mistral FP16"]

            GPU2 --> Model2
        end

        subgraph Observability["Observability"]
            DCGM["DCGM"]
            Prometheus["Prometheus"]
            Grafana["Grafana"]

            DCGM --> Prometheus
            Prometheus --> Grafana
        end

        Terraform["Terraform"]

        Terraform -.-> EKSRoot
    end

    Client --> Podman
    Client --> Service
```
---

## Security architecture

Two views: what happens to a request on its way to vLLM (perimeter → namespace → pod), and how the AWS/EKS side protects identity and data at rest. Both reflect what's actually built (weeks 5-6), including the honest gaps — nothing here is aspirational.

### Request path (perimeter → pod)

```mermaid
graph TB
    Client["Client"]

    subgraph Perimeter["Network perimeter"]
        Ingress["Ingress (nginx)<br/>Basic Auth + rate limit (5 rps/IP)"]
        Gap["⚠️ HTTP only — no TLS/cert-manager configured yet"]
        Ingress --- Gap
    end

    subgraph NetPolicy["Namespace isolation (NetworkPolicy)"]
        NP["deny-all by default<br/>+ explicit allow: ingress-nginx, monitoring"]
        NPStatus["kind: written, INERT (no policy engine on kindnetd)<br/>EKS: enforced for real (VPC CNI, ENABLE_NETWORK_POLICY=true)"]
        NP --- NPStatus
    end

    subgraph PodSec["Pod runtime (SecurityContext)"]
        Pod["vLLM container"]
        Ctx["runAsNonRoot, UID 1000<br/>capabilities: drop ALL<br/>allowPrivilegeEscalation: false<br/>readOnlyRootFilesystem: true"]
        Pod --- Ctx
    end

    Secrets["Secrets<br/>no HF_TOKEN in use today (public model)<br/>documented path when needed: K8s Secret + envFrom — never in a committed YAML"]

    Client --> Ingress --> NP --> Pod
    Pod -.-> Secrets

    classDef gap fill:#c77b1f,stroke:#8a5613,color:#fff
    class Gap,NPStatus gap
```

### AWS / EKS infrastructure

```mermaid
graph TB
    subgraph TFBox["Terraform (terraform/)"]
        TF["terraform apply<br/>— always manual, never automated"]
    end

    subgraph EKSCtrl["EKS control plane"]
        Etcd["etcd (Kubernetes Secrets)"]
        KMS["Customer-managed KMS key<br/>(EKS module default: create_kms_key=true)"]
        KMS -->|envelope encryption| Etcd
    end

    subgraph IAMAuth["Workload identity — least privilege, no static keys"]
        IRSA["IRSA<br/>EBS CSI driver"]
        PodID["EKS Pod Identity<br/>Karpenter controller"]
        Note["Two mechanisms, not a deliberate choice:<br/>Karpenter's submodule dropped IRSA support in v21"]
        IRSA --- Note --- PodID
    end

    subgraph Net["VPC"]
        Public["Public subnets<br/>NAT Gateway + load balancer only"]
        Private["Private subnets<br/>EKS nodes — no public IP"]
        Public -->|egress only| Private
    end

    TF --> EKSCtrl
    TF --> IAMAuth
    TF --> Net
    IAMAuth -.->|grants scoped AWS API access| EKSCtrl

    classDef gap fill:#c77b1f,stroke:#8a5613,color:#fff
    class Note gap
```

## Stack

| Layer | Technology |
|---|---|
| Model | Mistral 7B Instruct v0.1 AWQ (Apache 2.0) |
| Inference server | vLLM 0.20.2 |
| Container runtime | Podman (Fedora 44) |
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
- [x] **Week 2** — clean Containerfile, all OpenAI-compatible endpoints tested
- [x] **Week 3** — Kubernetes deployment on kind (local), GPU passthrough, Ingress + SSE streaming validated, KEDA autoscaler wired (Prometheus trigger pending Week 4)
- [x] **Week 4** — Prometheus/DCGM/Grafana observability, load benchmarking (128 concurrent requests, 0 failures), GPU resource management (nodeAffinity/tolerations)
- [x] **Week 5** — security hardening: NetworkPolicies (written, inert on kindnet — no policy engine), non-root/read-only SecurityContext, secrets review (none needed — public model), graceful shutdown, Ingress Basic Auth + rate limiting
- [ ] **Week 6** — migration to EKS with GPU nodes (g5.xlarge), Karpenter node autoscaling. Terraform (`terraform/`) and EKS-specific Kubernetes manifests (`kubernetes-eks/`) written and validated; not yet applied/deployed (no AWS credentials, real cost — deliberately left for manual apply)
- [ ] **Week 7-8** — *prepared offline on 2026-09-21 (guide, EKS manifests, load/timeline scripts — see [`docs/week7 guide.md`](docs/week7%20guide.md)); runs after the Week 6 `apply`.* Prove on EKS the KEDA queue-depth autoscaling already validated on kind (Week 4), with load testing and latency benchmarks on real cloud GPUs
- [ ] **Week 9-10** — replicate the observability stack validated in Week 4 on EKS and add the cloud-only panel: cost per 1M tokens (TTFT, GPU util, throughput dashboards already exist)
- [ ] **Week 11-12** — architecture diagrams, clean README, lessons-learned article

---
## Observability targets

The goal is a Grafana dashboard tracking four key metrics in production:

- **TTFT** (time to first token) — P50 and P95
- **Throughput** — tokens per second per GPU
- **GPU utilization** — via DCGM Exporter
- **Cost efficiency** — estimated cost per 1M tokens based on cloud instance pricing

---

## Why Mistral

This project deliberately uses Mistral open-weight models rather than Meta's Llama or Alibaba's Qwen. 

Mistral AI is a Paris-based lab building sovereign European AI infrastructure — using and documenting their models in production is a concrete way to support that ecosystem. All models used in this project are released under the Apache 2.0 license.

This sovereignty-conscious approach aligns well with European corporates and financial institutions building their AI platforms.

---

## Week 1 — lessons learned

Getting vLLM running on a consumer GPU involved several non-obvious constraints worth documenting.

### **Model format matters more than model size.** 
Mistral 7B in FP16 requires ~14 GB VRAM — impossible on a 8 GB card. The AWQ 4-bit quantized version fits in ~4 GB and delivers usable throughput. Understanding the difference between FP16, BF16, FP8, and AWQ quantization is a prerequisite for any AI infrastructure work.


### **Fedora Silverblue requires a different mental model.** 
The **immutable OS** means no direct simple package install — everything goes through `rpm-ostree` with a mandatory reboot for OS changes, but most changes cannot happen. We need to create virtual environments with `toolbox`. As handy as it can be, it also come with additional management challenges !

The NVIDIA Container Toolkit SSL configuration needed manual adjustment because rpm-ostree runs in an isolated context that cannot access the system CA bundle at the expected path. 

Toolbox containers do not have GPU access by default — vLLM runs in a dedicated Podman container launched from the host, not from inside toolbox.

Because Fedora Silverblue is immutable, NVIDIA drivers are installed through rpm-ostree layering :
```
rpm-ostree install akmod-nvidia xorg-x11-drv-nvidia-cuda
nvidia-smi
```

It can surprise, but even after installation and reboot, it's still not available, as akmods requires some minutes to compile fully.

### **Secure Boot and NVIDIA drivers**

The Secure Boot option may need to be disabled in the BIOS when using proprietary NVIDIA drivers on Linux.

The NVIDIA kernel modules installed through RPM Fusion are not always signed with a key trusted by Secure Boot. If Secure Boot is enabled, the modules may fail to load, resulting in missing GPU acceleration.

Alternative approaches exist, such as manually enrolling a Machine Owner Key (MOK) and signing the NVIDIA modules, but disabling Secure Boot remains the simplest option for many workstation setups and temporary personal test labs.

### **Baseline metrics (Mistral 7B AWQ, RTX 4060):** 
See docs/week-01-baseline.md for the full benchmark results — captured against the original v0.2-AWQ setup (context 2048 tokens), before the switch to v0.1-AWQ (context 880 tokens) described above.

---
## Week 2 — lessons learned

### Immutable OS is too rigid for labs
After testing exensively Fedora Silverblue 43, I eventually chose to switch to the normal Fedora Workstation experience. Indeed, the immutable OS seemed great and stable at first sight, but its rigidity added a significant number of slowness and difficulties to labs. Also, I found that it would be less applicable and usable for people who would be interested to use and test my repository, as most people don't go that far in testing Linux distributions.
The concept is strong, though, I will come back to it in some years!

### Kind is the best local Kubernetes orchestrator for AI
- **k3s** is great, light and conveninent, but less adapted for GPU labs ;
- **minikube** was not available by default on my Fedora 44 and anyway it's a bit more complex.

=> **kind** is handy and it's the best of those three to handle GPU-based pods.
---

## Week 3 — lessons learned

Getting the GPU into `kind` itself, then keeping the cluster alive across restarts, turned out to be the real work of this week — Kubernetes deployment mechanics came second.

### `kind` doesn't relay GPU passthrough automatically, even when the host already has it working
Podman already exposes the RTX 4060 to plain containers via CDI, and I assumed the same would carry through to `kind`'s node containers. It doesn't — `kind` runs its "nodes" as regular containers with no awareness of the host's CDI setup. I had to mount the GPU device nodes and the driver's userspace libraries (`libcuda.so`, `libnvidia-ml.so`) into the node container by hand, then repeat the *same* manual mounts on the NVIDIA device plugin, and then *again* on every application pod that needs the GPU — the device plugin's default "envvar" strategy assumes a `nvidia-container-runtime` that simply isn't there to act on it.

### Loading a local image into `kind` under podman isn't a one-liner
`kind load docker-image` fails silently with the podman provider ("image not present locally", even though `podman images` lists it fine). The workaround is `podman save` to a tarball followed by `kind load image-archive` — and recreating the cluster means redoing this, since a fresh node has never seen the image.

### All pods on a `kind` node share one Linux `pids` cgroup
This one looked like random flakiness at first: `ingress-nginx` and the KEDA operator kept crashlooping with `pthread_create() failed (Resource temporarily unavailable)`. The actual cause was a shared, cluster-wide pid budget (2048) on the single node container — vLLM's CUDA runtime plus every system pod together were exhausting it. Not a Kubernetes problem at all; fixed with `podman update --pids-limit`.

### Host-level limits bite even when the problem "feels like" Kubernetes
`fs.inotify.max_user_instances`, shared with the desktop GNOME session, was the real blocker behind a KEDA install failure. A reminder that a local lab node isn't isolated from the workstation it runs on.

---

## Week 4 — lessons learned

Observability was mostly smooth engineering — the surprises were in the places where naming, defaults, and privilege quietly didn't do what I expected.

### A Service name that doesn't match the Deployment name breaks scraping silently
`vllm-server` is the Deployment and its pods; the actual Service is `vllm-service`. Prometheus failed to resolve the wrong name with no other symptom — worth double-checking `kubectl get svc` before writing a scrape config from memory.

### `RollingUpdate` doesn't mix with anything that has exactly one owner
Twice this project hit the same failure shape from two different causes: Prometheus's `RollingUpdate` tried to start a new pod before killing the old one, and both fought over the same TSDB lockfile on a `ReadWriteOnce` volume. Weeks later, the same thing happened to vLLM itself over the single GPU on the node. `strategy: Recreate` is the fix whenever a workload owns something that can't be shared, even briefly.

### `privileged: true` isn't free, even when it "should" just work
DCGM Exporter's container failed to even start under `privileged: true` — not because of anything GPU-related, but because privileged mode makes runc try to mirror *every* device node on the host, including one (`/dev/cpu/1/cpuid`) that happened to be broken on this particular `kind` node. Dropping to a single specific capability (`SYS_ADMIN`) instead of blanket privilege fixed it — and turned out to be better practice anyway.

### The most useful finding of the week wasn't a bug
Pushed vLLM to 128 concurrent requests expecting to find the KV-cache OOM limit. It never crashed. The scheduler throttled how many requests it actually admitted (down from 128 to 15 concurrent) and queued the rest, trading latency for stability. That's continuous batching doing exactly its job — worth knowing before assuming "more load = crash."

---

## Week 5 — lessons learned

Security hardening is where things stopped being "does it run" and became "does it actually do what the YAML claims."

### Writing a NetworkPolicy isn't the same as enforcing one
`kind`'s default CNI (`kindnetd`) accepts and stores `NetworkPolicy` objects via the API server without enforcing a single one of them — no error, no warning. I only caught this by deliberately testing: a pod outside every `allow` rule could still reach a supposedly locked-down service. The manifests stayed (they're correct, and will actually work on EKS's VPC CNI), but I wouldn't have trusted them without that test.

### Running as non-root exposes assumptions baked into the base image
Two separate failures, both from the same root cause: a UID (1000) with no corresponding entry in the image's `/etc/passwd`. First, a Python library (`torch`) crashed trying to resolve the current username — fixed by setting `USER`/`HOME` env vars, which Python checks before falling back to a passwd lookup. Second, and more subtly, `/root` itself turned out to be mode `700` in the base image — a non-root user can't even *traverse* into it, regardless of what's mounted underneath. `fsGroup` fixes ownership of a volume's contents; it does nothing for a parent directory inherited from the image. Had to relocate the cache path out of `/root` entirely.

### A real secret briefly ended up in this very conversation
While setting up Ingress Basic Auth, I echoed a freshly generated password to the terminal and then reused it in a follow-up command. Claude Code's own safety layer flagged and blocked the second use as credential re-exposure — correctly. I treated the leaked password as compromised, rotated it immediately, and re-ran the test without ever printing the real value again. Worth including here precisely because it's the kind of near-miss that's easy to leave out of a "lessons learned" section.

---

## Week 6 — lessons learned

This week's lesson wasn't about Kubernetes or AWS at all — it was about the shelf life of AI-generated infrastructure code.

### AI-authored Terraform goes stale the moment it's written
I asked Claude Code to write the EKS + Karpenter Terraform, and it pinned every provider and module version from its training data. A simple question — "why is the Helm provider resolving to 2.17.0 when Helm is well past 3.20 by now?" — turned out to conflate two things (a Terraform *provider's* version number has never tracked the wrapped tool's own version), but it also surfaced a real problem underneath: every single pinned dependency had a major version bump by the actual current date, roughly eight months past the assistant's training cutoff — `hashicorp/aws` 5→6, `hashicorp/kubernetes` 2→3, `hashicorp/helm` 2→3, the `terraform-aws-modules` EKS/VPC/IAM modules all majored up, and the Karpenter chart itself jumped from 1.0.6 to 1.14.1. None of this shows up as an error until you actually try to `init` against the real registry.

### "Valid" isn't the same as "supported"
A second pass against the official AWS and Karpenter docs found that the first draft targeted Kubernetes 1.30 with an `AL2` node image. Both `init` and `validate` were green; neither would have survived contact with a real `apply` — EKS no longer ships AL2 AMIs past 1.32, Karpenter's v1 API requires an explicit `amiSelectorTerms`, and 1.30 had already left standard support. Moved to Kubernetes 1.36 on AL2023, with the compatibility matrix checked first. The takeaway is a habit rather than a fix: before provisioning anything, read the vendor's support calendar and compatibility table for the exact environment being targeted — cheaper than any upgrade or surcharge discovered later.

### Major version bumps in "stable" modules can be one-way traps
Re-verifying against the actually-downloaded module source (not memory) caught two nasty ones: the EKS module dropped the `cluster_` prefix from its input variables but kept it on every output — an easy asymmetric mistake to miss — and Karpenter's own IAM submodule removed IRSA support entirely in favor of Pod Identity, which isn't a renamed field, it's a different security mechanism requiring a different EKS addon.

### Even AI review needs a second AI review
Before committing the EKS-specific Kubernetes manifests, I caught (or rather, Claude caught itself) that its first draft of the DCGM Exporter manifest requested `nvidia.com/gpu` as a resource — which would have made the monitoring DaemonSet compete with vLLM for the single GPU on a `g5.xlarge` node. The fix (an env-var-based device injection strategy instead of a resource claim) was already the pattern used on `kind`; the bug only existed because the new EKS version wasn't written by directly extending working code, it was reasoned from scratch. A reminder to diff against what's already proven to work, not just what looks idiomatic for the new environment.

---

## Week 7 (prepared) — lessons learned before touching the cluster

Preparing the autoscaling stage *without* a cluster turned up problems that a single-replica setup on `kind` can never show, none of which raises an error: an EBS-backed model cache that a second GPU node can't mount, Prometheus scraping one random pod behind a ClusterIP so the autoscaling signal would be wrong from two replicas up, a liveness probe that would kill a pod still downloading its weights on a fresh node, a DCGM exporter that would monitor only one of two GPU nodes, and vLLM arguments tuned for an 8 GB desktop card that would leave a 24 GB A10G mostly idle while looking perfectly healthy.

The full catalogue — every silent failure across the project, why it was invisible, and how it was finally caught — is in [`docs/retour-d-experience.md`](docs/retour-d-experience.md) (French). The vLLM argument changes for the AWS GPU are in [`docs/vllm-gpu-aws.md`](docs/vllm-gpu-aws.md).

---

## Author

Senior Infrastructure Engineer (AWS, Kubernetes, Terraform, GPU observability) transitioning into AI infrastructure (as of April 2026).

Documenting the full journey publicly — including dead ends, wrong turns, and real production constraints.

[LinkedIn](https://www.linkedin.com/in/julien-p-68834731/) · [GitHub](https://github.com/PhenixForge)