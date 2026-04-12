# Pipeline Chunks

Composable building blocks for IArchitecture pipelines. Include via `@folder/name` syntax.
Runnable pipelines live in the root of `pipelines/` and `.iarch-hub/pipelines/`.

## Cache root path
Configured in `.iarch-hub/config.json`:
```json
{ "engine-config": { "cache-root-path": "{workspace-name}/cache" } }
```
`{workspace-name}` is the workspace folder name, resolved at runtime by the engine.
Default resolves to: `<repo-root>/<workspace-name>/cache/`

## Composite chunks (start here when building a pipeline)

| Ref | Expands to | Use for |
|---|---|---|
| `@scan/pr` | `@core` + `@intake/pr-diff` + `@validate/files` | PR pipelines |
| `@scan/full` | `@core` + `@intake/directory` + `@data/scan` + `@parse/graph` + `@validate/files` + `@validate/tree` + `@violations/finalize` | Full-scan pipelines |
| `@pr/github` | `@platform/github` + `@platform/github-pr` + `@history/pr-scan` | GitHub PR reporting |
| `@pr/ado` | `@platform/ado` + `@platform/ado-pr` + `@history/pr-scan` | ADO PR reporting |
| `@publish/github` | `@history/pipeline-run` + `@platform/github-commit` | Wrap up + commit to GitHub |
| `@publish/ado` | `@history/pipeline-run` + `@platform/ado-commit` | Wrap up + commit to ADO |

A processor or chunk may appear in more than one composite chunk — the DAG deduplicates at runtime.

### Typical compositions

```
PR pipeline (GitHub):   @scan/pr + @heal/all + @annotate + @pr/github + @publish/github
PR pipeline (ADO):      @scan/pr + @heal/all + @annotate + @pr/ado   + @publish/ado
Local validate:         @scan/pr + @heal/all + @annotate
Full scan:              @scan/full + @output/metadata + @data/governance-readonly + @output/dashboard + @publish/github
Governance cycle:       @core + @intake/directory + @data/scan-readonly + @data/governance + @parse/graph + @governance/intelligence + @output/dashboard + @publish/github
```

## Atomic chunk reference

| Ref | Description |
|---|---|
| `@core` | **Always first. No exceptions.** iarch-init + all cache type declarations. |
| `@intake/directory` | Full-codebase file intake (file-filter, dg-evaluator, file-parser) |
| `@intake/pr-diff` | PR-scoped intake — same processors, CI supplies file list via --file-list-path |
| `@parse/graph` | Build dependency graph (dg-builder). Required before @validate/tree. |
| `@data/scan` | Scan data cache I/O — DG, stats, violations, source-metadata (load+save) |
| `@data/scan-readonly` | Scan data loaders only |
| `@data/governance` | Governance data cache I/O — ledger, entropy, stats, cochange (load+save) |
| `@data/governance-readonly` | Governance + history loaders — for display-only pipelines |
| `@validate/files` | File-level validators: regex + semgrep |
| `@validate/tree` | Tree-level validators: dg-stats + 13 structural rules |
| `@heal/pattern` | Pattern-based healing only |
| `@heal/ai` | AI healing only (claude-healer) |
| `@heal/all` | Pattern then AI — use in most pipelines |
| `@annotate` | annotation-marker + annotation-flush |
| `@violations/finalize` | violation-index-builder + violation-filter (full-scan only) |
| `@history/pr-scan` | Load + record + save PR scan history entry |
| `@history/pipeline-run` | Load + record + save pipeline run history entry |
| `@platform/github` | GitHub CI environment provider |
| `@platform/github-pr` | GitHub PR reporting: check run + PR comment + commit markers |
| `@platform/github-commit` | github-bot-commit — commit data files back to repo |
| `@platform/ado` | ADO CI environment provider |
| `@platform/ado-pr` | ADO PR reporting: status + PR comment + commit markers |
| `@platform/ado-commit` | ado-bot-commit — commit data files back to repo |
| `@output/metadata` | Compute source metadata (metadata-aggregator) |
| `@output/dashboard` | Render + cache all dashboard HTML pages |
| `@governance/intelligence` | Full governance intelligence cycle processors |
| `@governance/remediation` | Cluster remediation processors |
| `@notifications/general` | General Jira + Slack notifications |
| `@notifications/governance` | Governance-specific Jira + Slack notifications |

## Swapping platforms (GitHub → ADO)
Replace `@platform/github` → `@platform/ado`, `@platform/github-pr` → `@platform/ado-pr`,
`@platform/github-commit` → `@platform/ado-commit`. Everything else stays the same.
