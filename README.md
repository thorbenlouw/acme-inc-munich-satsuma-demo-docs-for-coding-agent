# ACME Inc Munich — Satsuma Demo

This repo is a demo environment for showing a coding agent (Claude Code) working with [Satsuma](https://satsuma.io), a data mapping specification tool.

## What's here

| Folder | Purpose |
|---|---|
| `analysis-output/` | Pretend output of a source and target analysis — PRD, architecture overview, source system analysis, governance docs, and the raw Excel mapping spreadsheet a stakeholder handed over. Treat this as the "prior work" the team has done before involving the coding agent. |
| `docs-for-coding-agent/` | Context documents loaded into the coding agent's session — the Satsuma primer, ACME coding conventions, and the project scenario. |
| `spec/` | Satsuma `.stm` mapping specs at various stages of refinement. |
| `demo-steps/` | Guided prompts to walk through the demo, step by step. |
| `agent-skills/` | Custom Claude Code skills for this demo (`excel-to-satsuma`, `satsuma-to-dbt`). |

## Before you start

To get the most out of the demo, **delete the pre-baked outputs** so the agent builds them from scratch:

```
sample-data/
spec/first_attempt.stm
spec/reverse_engineered_spec.stm
implementation/
```

Then open a fresh Claude Code session and work through the prompts in [demo-steps/01-show-satsuma-setup.md](demo-steps/01-show-satsuma-setup.md).
