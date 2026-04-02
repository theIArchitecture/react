# Markdown Reporter – Modulus pipeline output

Generates a markdown report from **Modulus pipeline** results. It runs **as a processor** in the pipeline: add `markdown-reporter` as the last (or any) processor and the engine will run it; the C# processor passes the merged context to the Python script and writes the report.

## Running as a processor (recommended)

Add **markdown-reporter** to your pipeline. The engine loads the C# processor, which invokes **reporter.py** with the current pipeline context and config.

**CLI example:**
```bash
iarch --source-path ./src --processor iarch-parallel-file-parse --processor markdown-reporter
```

**With dependency graph and stats in the report:**
```bash
iarch --source-path ./src --processor file-parser --processor dependency-graph-builder --processor dependency-graph-stats --processor markdown-reporter
```

**With config (output path, timestamp in filename):**
```bash
iarch --source-path ./src --processor iarch-parallel-file-parse --processor markdown-reporter \
  --config markdown-reporter.output-file=report.md --config markdown-reporter.include-timestamp=false
```

Deploy the processor so the engine can find it: the **DLL** and **reporter.py** must be in the same folder (e.g. `.iarch/processors/markdown-reporter/`). Build the project to copy both to the runtime directory. If the script is elsewhere, set **markdown-reporter.script-path** in config to the full path to `reporter.py`.

## Where context comes from

When the engine runs this processor, **ProcessorInput** contains the **merged pipeline context** (everything upstream processors have added: `parsed-file-count`, `parsed-files`, `findings`, `violations`, or keys like `todo-processor.findings`). The C# processor serializes that context (and **ProcessingOptions.Config**) and passes it to the Python script on stdin. The script writes the markdown file and returns success/failure; the processor reports that back to the engine.

---

## Input format (stdin JSON)

The script expects a single JSON object on stdin:

```json
{
  "context": { ... },
  "config": { ... },
  "metadata": { ... }
}
```

| Key | Description |
|-----|-------------|
| **context** | Merged pipeline context (same shape as `ProcessingResult.Context`). Serialize only the keys you need (findings, violations, parsed-file-count, etc.). |
| **config** | String key-value. Use `output-file` (path for the report) and `include-timestamp` (`true`/`false`). |
| **metadata** | Optional. `runId`, `engineVersion`, `timestamp`, `sourcePathScanned`, etc. (e.g. from `ProcessingResult.Metadata`). |

### Context keys the reporter uses

- **findings** or **violations** – list of violation objects. Also collects from any context value that is a list of dicts with `ruleId`/`message`/`filePath` (e.g. `todo-processor.findings`).
- **parsed-file-count** – number of files parsed (for “Total Files Scanned”).
- **dependency-graph-stats** – *(optional)* object from the `dependency-graph-stats` processor. When present, the report includes a **Dependency Graph** section with: total types, total dependencies, total files, language count, types by language, max fan-in/fan-out (type and file), cycle count, and types in cycles. Keys can be camelCase or PascalCase.
- Violation shape: `ruleId`, `message`, `filePath`, `line`, `severity`, `fixSuggestion` (or snake_case equivalents).

---

## Tack it on to the end of any test (or run standalone script)

**Option A – As a processor:** Add `markdown-reporter` to the pipeline in your test (e.g. `Pipeline = new[] { "iarch-parallel-file-parse", "markdown-reporter" }`). After `RunAsync`, the report file will already be written.

**Option B – From a test, invoke the script by hand:** After running the pipeline without the reporter:

1. Run the pipeline:  
   `var result = await engine.RunAsync(options);`
2. Build a JSON payload with the **context** and **metadata** you want in the report. You must serialize `result.Context` to a JSON-friendly form (e.g. only keys like `findings`, `violations`, `parsed-file-count`, or whatever your processors put there). Complex objects (e.g. `init-config`, `parsed-files`) can be omitted or summarized (e.g. `parsed-file-count` as an integer).
3. Invoke the script with that JSON on stdin; it writes the markdown file and prints `{"success": true, "message": "..."}` or failure to stdout.

### Example (C# test)

```csharp
// After: var result = await engine.RunAsync(options);

var payload = new Dictionary<string, object>
{
    ["context"] = new Dictionary<string, object>
    {
        ["parsed-file-count"] = result.Context.TryGetValue("parsed-file-count", out var c) ? c : 0,
        ["findings"] = result.Context.TryGetValue("findings", out var f) ? f : new List<object>(),
        // Add other keys you want in the report (violations, etc.)
    },
    ["config"] = new Dictionary<string, string>
    {
        ["output-file"] = "test-report.md",
        ["include-timestamp"] = "false"
    },
    ["metadata"] = new Dictionary<string, object>
    {
        ["runId"] = result.Metadata.RunId,
        ["engineVersion"] = result.Metadata.EngineVersion,
        ["timestamp"] = result.Metadata.Timestamp
    }
};

var json = JsonSerializer.Serialize(payload);
var process = Process.Start(new ProcessStartInfo
{
    FileName = "python",
    Arguments = "reporter.py",
    WorkingDirectory = "<path-to-MarkdownReporter>",
    RedirectStandardInput = true,
    RedirectStandardOutput = true
});
process.StandardInput.Write(json);
process.StandardInput.Close();
var output = await process.StandardOutput.ReadToEndAsync();
process.WaitForExit();
// Parse output for success/message; report file is written to config.output-file.
```

### Example (command line, with JSON file)

```bash
cd path/to/MarkdownReporter
echo '{"context":{"parsed-file-count":1,"findings":[]},"config":{"output-file":"out.md","include-timestamp":"false"},"metadata":{"runId":"test-1"}}' | python reporter.py
```

---

## Configuration

Pass via **ProcessingOptions.Config** (e.g. `--config markdown-reporter.output-file=...`). The C# processor forwards these to the script (with the `markdown-reporter.` prefix stripped).

| Key | Description | Default |
|-----|-------------|---------|
| **output-file** | Path to output markdown file | `iarch-report.md` |
| **include-timestamp** | Add timestamp to filename | `true` |
| **script-path** | Full path to `reporter.py` (if not next to the DLL) | (same folder as processor DLL) |

---

## Output format

The markdown report includes:

- **Plugin Configuration** – config received (for verification).
- **Summary** – total violations, files scanned, rules evaluated, scan scope.
- **Dependency Graph** – *(when `dependency-graph-stats` is in context)* total types, total dependencies, total files, language count, types-by-language table, max fan-in/fan-out (type and file), cycle count and types in cycles.
- **Violations by Severity** – counts by Fatal/Error/Warning/Info/Educational.
- **Rules** – table of rule IDs and violation counts.
- **Violations** – detail grouped by severity (file, line, message, fix suggestion).
- **Scan Metadata** – full metadata dump (RunId, etc.) for debugging.

---

## Backward compatibility

The script still accepts the **legacy** top-level shape: `violations`, `rules`, `metadata`, `context`, `config` (old OutputPluginInput). So existing callers that pass that shape continue to work.

---

## Requirements

- Python 3.6+
- No external dependencies (standard library only).
