# Status

Single source of truth for "where this project actually stands." Picking this project back up — yourself, or briefing an assistant — starts here, not by re-reading every doc.

This file replaced four things that used to say the same thing slightly differently and drifted out of sync (`summary.md`, plus three separate sections in `README.md`: Status, Timeline, "Validated so far", Roadmap) — see the ["statuts désynchronisés" entry](docs/retour-d-experience.md) for the actual incident. There is now exactly one table below. If project state changes, update it here first; `README.md` only links to this file, it doesn't restate it.

**Week 6/12 — in progress** · last updated 2026-09-28

## Right now

Local vLLM inference running on a single personal Nvidia GPU (RTX 4060, 8 GB VRAM) from a Podman container, Mistral 7B Instruct v0.1 AWQ quantization, baseline latency/throughput captured.

Deployed on a local Kubernetes cluster (`kind`) with GPU passthrough: Deployment, Service, Ingress (SSE streaming validated end to end), PVC and KEDA autoscaling manifests applied.

Full observability stack live: Prometheus + DCGM Exporter (GPU metrics) + Grafana. KEDA's Prometheus trigger is healthy end to end (`HPAActive=True`). Load benchmarking swept up to 128 concurrent requests with zero failures — vLLM's scheduler throttles admission under KV cache pressure instead of OOMing.

Security hardening done: `vllm-server` runs non-root (UID 1000), no capabilities, read-only root filesystem, no `privileged`. NetworkPolicies written and applied (inert on this cluster's CNI — no policy engine — documented, not hidden). Ingress locked down with Basic Auth + rate limiting.

EKS migration: Terraform written for VPC + EKS + Karpenter-managed GPU node pool ([`terraform/`](terraform/)) — validated (`init`/`validate`/`plan` up to the expected missing-credentials wall) but **not applied**. EKS-specific Kubernetes manifests also written ([`kubernetes-eks/`](kubernetes-eks/)) but not deployed to a real cluster. No AWS credentials configured, and real GPU nodes cost real money — deliberately left for a deployer with an AWS account and budget sign-off, not automated.

CI pipeline live: GitHub Actions runs YAML lint, `terraform fmt`/`validate`, Containerfile lint (hadolint), and builds+pushes the container image to GHCR on every merge to `main` — see [`.github/workflows/ci.yml`](.github/workflows/ci.yml).

## How to read the table below

This is a **multi-month, part-time project**, not a 12-calendar-week sprint — "Week N" is a unit of *content* inherited from the original plan, not a calendar week. Dates are the real ones, from the commit history, including a genuine 6-week gap in commits (2026-07-03 → 08-18) before a documentation catch-up pass. Nothing here restarts from zero: each week was validated when it was done and the result is committed; later weeks build on these, they do not redo them. The commit history itself is kept as-is, unrewritten — including a known misleading commit message (see the footnote on Week 6).

| Week | Dates | Commits | What was validated | Carries over to EKS | Status |
|---|---|---|---|---|---|
| 1 | 2026-05-09 | `77b313e`, `d4ab0e4` | Baseline latency/throughput captured ([`week-01-baseline.md`](docs/week-01-baseline.md)) | Benchmark script, model choice | ✅ done |
| 2 | 2026-05-26 → 07-03 | `5dafe1e`, `0f8befd`, `e965b81`…`dfd515e` | Containerised vLLM answering OpenAI-compatible requests | `container/Containerfile` (image pushed to ECR) | ✅ done |
| 3 | 2026-09-13 → 09-15 | `c0ae78a`…`44f1db3`, closed by `fba5c9d` | Real inference from a pod on kind (09-14); Ingress + SSE streaming; validation closed 09-15 | Service, PVC, ConfigMap, Ingress manifests | ✅ done |
| 4 | 2026-09-16 | `b17cdbe` | KEDA `HPAActive=True` on a live Prometheus value; 128 concurrent requests, 0 failures | Prometheus, Grafana, KEDA `ScaledObject`, DCGM (EKS variant) | ✅ done |
| 5 | 2026-09-16 | `d1490b1` | Non-root inference end to end; Basic Auth 401/401/200; ~7 s graceful shutdown; NetworkPolicy inertness proven on kindnet | `network-policy.yaml` unchanged (enforced by VPC CNI on EKS), hardened Deployment | ✅ done |
| 6 | 2026-09-17, revised 09-21 | `6405b71`*, `be4b0a6` | `terraform init` + `validate` green; `plan` stops at the expected missing-credentials wall | — (this is the new work) | ⏳ written, not applied |
| 7-8 | prepared 2026-09-21 | — | Guide + EKS manifests + load/timeline scripts ready ([`docs/week7 guide.md`](docs/week7%20guide.md)) | Proves on EKS what Week 4 proved on kind | ⏳ blocked on Week 6 `apply` |
| 9-10 | — | — | Replicate the Week 4 observability stack on EKS, add cost-per-1M-tokens panel | — | ⏳ pending |
| 11 | done incrementally | various | Architecture diagrams (ASCII + Mermaid, incl. 2 security views) and lessons-learned article ([`docs/retour-d-experience.md`](docs/retour-d-experience.md)) | — | ✅ done |
| 12 | 2026-09-28 | `f6170cc`+ | README cleanup — this file replacing 4 overlapping trackers | — | 🔄 in progress |
| CI/CD | 2026-09-28 | `5125f06`, `3a9a22c`, `f6170cc` | GitHub Actions: yamllint, `terraform fmt`/`validate`, hadolint, image build+push to GHCR on merge to `main` | Also lints `kubernetes-eks/` and validates `terraform/` | ✅ done |

\* The message of `6405b71` reads "week5: Terraform code" but the content is the Week 6 Terraform; history was not rewritten to change it.

## What's next

The real `apply`, then proving on EKS what was already proven on kind: KEDA scaling and load testing on cloud GPUs, the same observability stack, cost per 1M tokens.

- **Re-verify before provisioning.** The EKS layer was written months before any real `apply` is expected. A pre-apply checklist (support calendar, compatibility matrix, current module/provider versions) lives in [`terraform/README.md`](terraform/README.md#avant-de-lancer-un-apply--re-vérifier-les-versions).
- **Deferred work is deliberate, not forgotten.** The real `apply` needs AWS credentials and a budget sign-off; extensions (MCP, RAG, evaluation, Vault, Packer) are scheduled after the core project — see [`docs/extensions/EXTENSIONS_ROADMAP.md`](docs/extensions/EXTENSIONS_ROADMAP.md).
- **Everything above is a dated snapshot.** Versions, support windows and "latest" claims are true *as of the date stated next to them* — upstream moves on during a months-long project (the EKS/Terraform layer had drifted from its first-pinned versions by the time Week 6 was reviewed). Each week's own notes (`docs/week-*-notes.md`) are a chronological log, not a description of the current state — this file is the current state.
