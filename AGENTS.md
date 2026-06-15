# AGENTS.md

Guidance for AI coding agents working in this repository.

## What this repo is

A demo of [Satsuma](https://github.com/EqualExperts/satsuma-lang) — a data-mapping
language for human- **and** AI-friendly source-to-target mappings in data
engineering. It ships a `satsuma` CLI and two agent skills. The worked example is
the **Acme Inc "Customer 360"** migration (ATLAS PostgreSQL + a billing REST API →
Salesforce). See [docs-for-coding-agent/SCENARIO.md](docs-for-coding-agent/SCENARIO.md)
for the full scenario.

Key locations:

- [docs-for-coding-agent/about-satsuma.md](docs-for-coding-agent/about-satsuma.md) — the grammar, conventions, common mistakes, and full CLI reference. **Read this before writing or reading any `.stm` file.**
- [agent-skills/excel-to-satsuma/](agent-skills/excel-to-satsuma/) — skill: convert Excel mapping spreadsheets → Satsuma.
- [agent-skills/satsuma-to-dbt/](agent-skills/satsuma-to-dbt/) — skill: scaffold a dbt project from Satsuma specs.
- [analysis-output/](analysis-output/) — the scenario brief and source spreadsheet.

## First moves

1. **Load Satsuma knowledge.** Run `satsuma agent-reference` (or read [about-satsuma.md](docs-for-coding-agent/about-satsuma.md)) before touching `.stm` files. Don't generate Satsuma from memory of the grammar — verify against the reference.
2. **Confirm the CLI is available.** `satsuma --version` (this repo uses 0.9.0). Every command supports `--help` with its flags, JSON shape, and examples — use it instead of guessing.
3. **For a task that matches a skill** (Excel → Satsuma, Satsuma → dbt), use the skill rather than reinventing its workflow.

## Use the CLI for structured search — don't grep `.stm` files

The `satsuma` CLI is a deterministic structural extractor. It is faster, more
accurate, and more token-efficient than reading or grepping raw `.stm` text.
**Default to the CLI for any structural question.** Prefer `--json` when you'll
process the output; `--compact` to minimise tokens.

| Need | Command |
| --- | --- |
| Whole-workspace topology in one call | `satsuma graph <file>.stm --json` |
| Workspace overview / counts | `satsuma summary <file>.stm` |
| A schema or mapping definition | `satsuma schema <name>` / `satsuma mapping "<name>"` |
| Arrows for a specific field | `satsuma arrows <schema.field>` |
| Full upstream/downstream of a field | `satsuma field-lineage <schema.field> --json` |
| All references to a name | `satsuma where-used <name>` |
| Fields carrying a tag (e.g. PII) | `satsuma find --tag pii --json` |
| NL transform / note content | `satsuma nl <scope>` |
| `@ref`s embedded in NL | `satsuma nl-refs <file>.stm --json` |
| Metadata on a field | `satsuma meta <schema.field>` |
| Target fields with no arrows | `satsuma fields <target> --unmapped-by "<mapping>"` |
| Warnings (`//!`) and TODOs (`//?`) | `satsuma warnings` |
| Compare two snapshots | `satsuma diff <old>.stm <new>.stm` |

Reach for the file tools (Read/Grep) only when you need the **raw text to edit it**,
or for non-`.stm` files. The CLI does not interpret natural language — reading and
reasoning about NL transform/`note` content is your job.

Scope is **file-based**: CLI commands operate on entry files and their
import-reachable graph, not directories. Pass the entry `.stm` file, not a folder.

## After every edit to a `.stm` file

Run this loop and fix what it reports before moving on:

1. `satsuma fmt <file>.stm` — apply canonical formatting.
2. `satsuma validate <file>.stm` — parse errors + semantic reference checks.
3. `satsuma lint <file>.stm` — policy/convention checks. Use `satsuma lint --fix <file>.stm` for safe auto-fixes (e.g. adding undeclared `@ref` schemas to a mapping's source list).
4. `satsuma fields <target> --unmapped-by "<mapping>"` — confirm coverage of target fields.

Treat `validate` errors as blocking. Don't report a `.stm` change as done until
`validate` and `lint` are clean (or you've explained any remaining warnings).

## Writing idiomatic Satsuma

Follow the conventions in [about-satsuma.md](docs-for-coding-agent/about-satsuma.md). The high-value rules:

- **Three delimiters, three jobs:** `( )` = metadata, `{ }` = structural content, `" "` = natural language.
- **`::` is namespace→schema only.** Fields use dots: `ns::schema.field.nested`. Never `schema::field`.
- **Always use `@ref`** for field/schema names inside NL strings — e.g. `"Sum @mrr_eur grouped by @customer_ref"`. Tooling extracts these for lineage; bare names are invisible. Backtick only the unsafe segment, not the whole path.
- **Never invent transform functions.** Use the documented vocabulary (`trim`, `lowercase`, `validate_email`, `map { ... }`, etc.) or fall back to a `"natural language"` string. A bare NL string is a valid transform body.
- **snake_case** schemas/fields/namespaces to avoid backtick quoting.
- **Schemas only** — no `source`/`target`/`table`/`metric`/`report`/`model` block keywords. Role is contextual; `metric`/`report`/`model` are metadata tags on a `schema`.
- **Document, don't hide:** `//!` for data-quality warnings, `//?` for open questions/ambiguities, `(note "...")` for field docs, `note { }` for block-level context.
- Check the **Common mistakes** table in [about-satsuma.md](docs-for-coding-agent/about-satsuma.md) — these are the errors agents make despite knowing the grammar.

## Scenario-specific care

This migration involves personal data and deliberate business rules. When working
the Acme example, preserve the governance intent rather than smoothing it away:

- **PII** (email, phone) must carry its governance treatment (mask/encrypt); the no-purpose date-of-birth column is deliberately **not** migrated (data minimisation).
- The **consent inversion** (`werbung_ok='J'` → `HasOptedOutOfEmail=false`) is intentional and high-risk — capture it explicitly and flag it for review, don't "correct" it.
- **Never silently drop** the ~0.4% billing orphans — they route to remediation. Record exclusions with a reason, not by omission.
- Capture business rules (salutation map, asset-status derivation, the KD-REF crosswalk join) as explicit, testable Satsuma — not as implicit prose.

## Reporting

Be transparent about what came from the CLI's structural extraction versus your
own interpretation of natural-language content. Keep structural facts separate
from interpretation when you summarise results to a human.

## ACME internal conventions
Always read ACME's conventions in docs-for-coding-agent/ACME-CONVENTIONS.md and comploy with conventions and policies. 
* Don't make assumptions -- ask for clarification first. 

