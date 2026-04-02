#!/usr/bin/env python3
"""
Context Dump - Debug processor that summarizes pipeline context.

Reads Modulus-style input from stdin, extracts context, and writes a short
summary of each key and value (type, size, preview) to a file. Use this to
inspect what is actually in context at a given point in the DAG (e.g. to
verify keys like dependency-graph-stats or spellings).

Input (stdin JSON) - Modulus-style:
  { "context": { ... }, "config": { ... }, "metadata": { ... } }

Output: writes context-dump.md (or config["outputFile"]); prints ProcessorResult JSON to stdout.
"""

import sys
import json
from datetime import datetime


def _summarize(value, max_str=120, max_list_preview=3, max_dict_keys=15):
    """Return a short summary of a value for debugging."""
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return f"{type(value).__name__}({value})"
    if isinstance(value, str):
        n = len(value)
        preview = value[:max_str] + ("..." if n > max_str else "")
        return f"str(len={n}) {repr(preview)}"
    if isinstance(value, list):
        n = len(value)
        if n == 0:
            return "list(0)"
        preview = []
        for i, item in enumerate(value[:max_list_preview]):
            try:
                preview.append(_summarize(item, max_str=60, max_list_preview=1, max_dict_keys=5))
            except Exception:
                preview.append(f"<{type(item).__name__}>")
        rest = f" ... +{n - max_list_preview} more" if n > max_list_preview else ""
        return f"list({n}) [ {', '.join(preview)}{rest} ]"
    if isinstance(value, dict):
        keys = list(value.keys())
        n = len(keys)
        head = keys[:max_dict_keys]
        rest = f" ... +{n - max_dict_keys} more keys" if n > max_dict_keys else ""
        return f"dict({n} keys) {head}{rest}"
    try:
        s = str(value)
        return f"{type(value).__name__}({len(s)} chars) {s[:80]}..."
    except Exception:
        return f"{type(value).__name__}(?)"


def generate_context_summary(input_data):
    """Build a markdown summary of context keys and value summaries."""
    context = input_data.get("context") or {}
    config = input_data.get("config") or {}
    metadata = input_data.get("metadata") or {}


    now = datetime.now()
    # Format as "Month Day, Year Hour:Minute AM/PM"
    formatted_time = now.strftime("%B %d, %Y %I:%M%p")

    lines = [
        "# Context Dump",
        "",
        f"**Generated:** { formatted_time }",
        "",
        "## Context keys",
        "",
        "| Key | Summary |",
        "|-----|--------|",
    ]

    if not context:
        lines.append("| *(empty)* | - |")
    else:
        for key in sorted(context.keys(), key=str.lower):
            try:
                summary = _summarize(context[key])
                # Escape pipe in summary for markdown
                summary_esc = summary.replace("|", "\\|")[:200]
                lines.append(f"| `{key}` | {summary_esc} |")
            except Exception as e:
                lines.append(f"| `{key}` | *(error: {e})* |")

    lines.extend([
        "",
        "## Config (string key-value)",
        "",
        "```json",
        json.dumps(config, indent=2, default=str),
        "```",
        "",
        "## Metadata",
        "",
        "```json",
        json.dumps(metadata, indent=2, default=str),
        "```",
    ])
    return "\n".join(lines)


def main():
    """Read stdin JSON; write context summary to file; print ProcessorResult to stdout."""
    try:
        input_json = sys.stdin.read()
        input_data = json.loads(input_json)

        config = input_data.get("config") or input_data.get("init-config") or {}
        output_file = config.get("outputFile") or config.get("contextDumpOutput") or "context-dump.md"
        if isinstance(output_file, dict):
            output_file = "context-dump.md"

        content = generate_context_summary(input_data)
        with open(output_file, "w", encoding="utf-8") as f:
            f.write(content)

        result = {
            "success": True,
            "context": {"context-dump.message": f"Context dump written: {output_file}"},
            "error": None,
            "warnings": [],
        }
        print(json.dumps(result))
        sys.exit(0)
    except Exception as e:
        result = {
            "success": False,
            "context": {},
            "error": f"Context dump failed: {str(e)}",
            "warnings": [],
        }
        print(json.dumps(result))
        sys.exit(1)


if __name__ == "__main__":
    main()
