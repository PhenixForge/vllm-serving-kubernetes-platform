# MCP Server — Observability Queries

**Status**: Planned, not started (Phase A of the extensions roadmap).

Full scope, tools, and timeline are defined in [`EXTENSIONS_ROADMAP.md`](EXTENSIONS_ROADMAP.md#phase-a-mcp-server-for-observability-queries).

Short version: an MCP server exposing Prometheus/DCGM metrics (TTFT, tokens/s, GPU utilization, cost per 1M tokens) as tools (`query_prometheus`, `get_gpu_metrics`) so they can be queried in natural language from Claude Code or claude.ai. Scheduled to start once Week 4 (Prometheus/Grafana) is stable.
