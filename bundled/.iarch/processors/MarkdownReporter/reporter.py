#!/usr/bin/env python3
"""
Markdown Report Generator - Modulus pipeline output processor.

Reads from Modulus pipeline context (findings/violations, parsed-file-count, etc.)
and optional run metadata. Generates a markdown report and writes to a file.

Input (stdin JSON) - Modulus-style:
  {
    "context": { ... },   // Merged pipeline context (ProcessingResult.Context)
    "config": { ... },    // String key-value (e.g. output-file, include-timestamp)
    "metadata": { ... }   // Optional: runId, engineVersion, timestamp (ProcessingResult.Metadata)
  }

Context keys read:
  - findings, violations: list of violations (or any context key whose value is a list of dicts
    with ruleId/message/filePath/severity). Also gathers from *.*.findings, *.*.violations.
  - parsed-file-count: number of files parsed (summary).
  - dependency-graph-stats: optional; provided by DependencyGraphStatsProcessor (ArchitectureRules)
    when that processor runs in the pipeline. Dict with TotalTypes, TotalDependencies, TotalFiles,
    LanguageCount, TypesByLanguage, MaxFanIn, MaxFanInType, MaxFanInFile, MaxFanOut,
    MaxFanOutType, MaxFanOutFile, CycleCount, TypesInCycles (camelCase or PascalCase).
  - init-config: not fully serialized; used only to infer scope if needed.

Output: writes markdown file; prints { "success": true|false, "message": "..." } to stdout.
"""

import sys
import json
from datetime import datetime
from pathlib import Path


def _gather_violations(input_data):
    """Collect all violations/findings from Modulus context or legacy top-level keys."""
    violations = []

    # Legacy shape: top-level violations or findings
    for key in ("violations", "findings"):
        if key in input_data and isinstance(input_data[key], list):
            for v in input_data[key]:
                if isinstance(v, dict):
                    violations.append(_normalize_violation(v))

    context = input_data.get("context") or {}
    if not isinstance(context, dict):
        return violations

    # Prefer context["findings"] or context["violations"]
    for key in ("findings", "violations"):
        if key in context and isinstance(context[key], list):
            for v in context[key]:
                if isinstance(v, dict):
                    violations.append(_normalize_violation(v))
            if violations:
                return violations

    # Gather from any key whose value is a list of violation-like dicts
    for key, val in context.items():
        if not isinstance(val, list):
            continue
        for item in val:
            if isinstance(item, dict) and ("ruleId" in item or "message" in item or "rule_id" in item):
                violations.append(_normalize_violation(item))

    return violations


def _normalize_violation(v):
    """Ensure violation has ruleId, message, filePath, severity (strings)."""
    return {
        "ruleId": v.get("rule_id") or v.get("ruleId") or "unknown",
        "message": v.get("message") or v.get("description") or "No description",
        "filePath": v.get("file_path") or v.get("filePath") or "unknown",
        "line": v.get("line") or v.get("line_number") or v.get("lineNumber") or "",
        "severity": v.get("severity") or "Warning",
        "fixSuggestion": v.get("fix_suggestion") or v.get("fixSuggestion"),
    }


def _get_metadata(input_data):
    """Build metadata dict from Modulus metadata and context."""
    meta = input_data.get("metadata") or {}
    if not isinstance(meta, dict):
        meta = {}
    context = input_data.get("context") or {}
    if not isinstance(context, dict):
        context = {}

    total_violations = len(_gather_violations(input_data))
    total_files = context.get("parsed-file-count")
    if total_files is None and isinstance(context.get("parsed-files"), list):
        total_files = len(context["parsed-files"])
    if total_files is None:
        total_files = 0

    now = datetime.now()
    # Format as "Month Day, Year Hour:Minute AM/PM"
    formatted_time = now.strftime("%B %d, %Y %I:%M%p")

    return {
        "engineVersion": meta.get("engine_version") or meta.get("engineVersion") or meta.get("EngineVersion") or "unknown",
        "runId": meta.get("run_id") or meta.get("runId") or meta.get("RunId") or "",
        "timestamp": meta.get("timestamp") or formatted_time,
        "sourcePathScanned": meta.get("sourcePathScanned") or "",
        "totalViolations": total_violations,
        "totalFilesScanned": total_files,
        "totalRulesEvaluated": meta.get("totalRulesEvaluated") or 0,
        "scanScope": meta.get("scanScope") or "pipeline",
        "violationsBySeverity": _violations_by_severity(input_data),
    }

def _violations_by_severity(input_data):
    """Count violations by severity."""
    violations = _gather_violations(input_data)
    counts = {}
    for v in violations:
        sev = (v.get("severity") or "Warning")
        counts[sev] = counts.get(sev, 0) + 1
    return counts


def _get_rules_summary(input_data):
    """Build rules summary from violations (rule id -> count)."""
    violations = _gather_violations(input_data)
    by_rule = {}
    for v in violations:
        rid = v.get("ruleId") or "unknown"
        by_rule[rid] = by_rule.get(rid, 0) + 1
    return [{"ruleId": rid, "violationCount": count} for rid, count in by_rule.items()]


def _get_dependency_graph_stats(input_data):
    """Extract dependency-graph-stats from context. Supports camelCase or PascalCase keys."""
    context = input_data.get("context") or {}
    if not isinstance(context, dict):
        return None
    raw = context.get("dependency-graph-stats") or context.get("dependencyGraphStats")
    if not isinstance(raw, dict):
        return None

    def get(key_snake, key_camel, key_pascal):
        for k in (key_snake, key_camel, key_pascal):
            v = raw.get(k)
            if v is not None:
                return v
        return None

    skipped = get("skipped_reasons", "skippedReasons", "SkippedReasons")
    if skipped is not None and not isinstance(skipped, list):
        skipped = []
    return {
        "totalTypes": get("total_types", "totalTypes", "TotalTypes"),
        "totalDependencies": get("total_dependencies", "totalDependencies", "TotalDependencies"),
        "totalFiles": get("total_files", "totalFiles", "TotalFiles"),
        "languageCount": get("language_count", "languageCount", "LanguageCount"),
        "typesByLanguage": get("types_by_language", "typesByLanguage", "TypesByLanguage") or {},
        "maxFanIn": get("max_fan_in", "maxFanIn", "MaxFanIn"),
        "maxFanInType": get("max_fan_in_type", "maxFanInType", "MaxFanInType"),
        "maxFanInFile": get("max_fan_in_file", "maxFanInFile", "MaxFanInFile"),
        "maxFanOut": get("max_fan_out", "maxFanOut", "MaxFanOut"),
        "maxFanOutType": get("max_fan_out_type", "maxFanOutType", "MaxFanOutType"),
        "maxFanOutFile": get("max_fan_out_file", "maxFanOutFile", "MaxFanOutFile"),
        "cycleCount": get("cycle_count", "cycleCount", "CycleCount"),
        "typesInCycles": get("types_in_cycles", "typesInCycles", "TypesInCycles"),
        "skippedReasons": skipped or [],
    }


def generate_markdown_report(input_data):
    """Generate markdown report from Modulus context + metadata (or legacy OutputPluginInput)."""
    violations = _gather_violations(input_data)
    rules = _get_rules_summary(input_data)
    metadata = _get_metadata(input_data)
    context = input_data.get("context") or {}
    if not isinstance(context, dict):
        context = {}
    config = input_data.get("config") or {}
    if not isinstance(config, dict):
        config = {}

    lines = []

    now = datetime.now()
    # Format as "Month Day, Year Hour:Minute AM/PM"
    formatted_time = now.strftime("%B %d, %Y %I:%M%p")

    # Header
    lines.append("# IArchitecture Scan Report")
    lines.append("")
    lines.append(f"**Generated:** {formatted_time}")
    lines.append(f"**Engine Version:** {metadata.get('engineVersion', 'unknown')}")
    if metadata.get("runId"):
        lines.append(f"**Run ID:** {metadata.get('runId')}")
    if metadata.get("sourcePathScanned"):
        lines.append(f"**Source Path:** {metadata.get('sourcePathScanned')}")
    lines.append("")

    # Config (from ProcessingOptions.Config - string key-value)
    lines.append("## 🔧 Plugin Configuration")
    lines.append("")
    if config:
        lines.append("Configuration received by this plugin:")
        lines.append("")
        lines.append("```json")
        lines.append(json.dumps(config, indent=2, default=str))
        lines.append("```")
    else:
        lines.append("*No configuration provided*")
    lines.append("")

    # Summary
    lines.append("## 📊 Summary")
    lines.append("")
    lines.append(f"- **Total Violations:** {metadata.get('totalViolations', 0)}")
    lines.append(f"- **Total Files Scanned:** {metadata.get('totalFilesScanned', 0)}")
    lines.append(f"- **Total Rules Evaluated:** {metadata.get('totalRulesEvaluated', 0)}")
    lines.append(f"- **Scan Scope:** {metadata.get('scanScope', 'pipeline')}")
    lines.append("")

    # Dependency graph stats (when dependency-graph-stats processor ran)
    graph_stats = _get_dependency_graph_stats(input_data)
    if graph_stats and graph_stats.get("totalTypes") is not None:
        lines.append("## 📈 Dependency Graph")
        lines.append("")
        lines.append("Aggregate stats from the dependency graph (when `dependency-graph-stats` runs in the pipeline).")
        lines.append("")
        lines.append(f"- **Total Types:** {graph_stats.get('totalTypes', 0)}")
        lines.append(f"- **Total Dependencies:** {graph_stats.get('totalDependencies', 0)}")
        lines.append(f"- **Total Files:** {graph_stats.get('totalFiles', 0)}")
        lines.append(f"- **Languages:** {graph_stats.get('languageCount', 0)}")
        types_by_lang = graph_stats.get("typesByLanguage") or {}
        if isinstance(types_by_lang, dict) and types_by_lang:
            lines.append("")
            lines.append("### Types by Language")
            lines.append("")
            lines.append("| Language | Types |")
            lines.append("|----------|-------|")
            for lang, count in sorted(types_by_lang.items(), key=lambda x: -x[1]):
                lines.append(f"| {lang} | {count} |")
            lines.append("")
        lines.append(f"- **Max Fan-In:** {graph_stats.get('maxFanIn', 0)} — `{graph_stats.get('maxFanInType') or '-'}`")
        if graph_stats.get("maxFanInFile"):
            lines.append(f"  - File: `{graph_stats['maxFanInFile']}`")
        lines.append(f"- **Max Fan-Out:** {graph_stats.get('maxFanOut', 0)} — `{graph_stats.get('maxFanOutType') or '-'}`")
        if graph_stats.get("maxFanOutFile"):
            lines.append(f"  - File: `{graph_stats['maxFanOutFile']}`")
        lines.append(f"- **Cycles:** {graph_stats.get('cycleCount', 0)} distinct cycle(s), **{graph_stats.get('typesInCycles', 0)}** type(s) in cycles")
        skipped = graph_stats.get("skippedReasons") or []
        if isinstance(skipped, list) and skipped:
            lines.append("")
            lines.append("*Skipped for performance (large graph):*")
            for reason in skipped:
                lines.append(f"- {reason}")
        lines.append("")

    lines.append("## 📈 Dependency Graph - Meta file location")
    lines.append("")

    violations_by_severity = metadata.get("violationsBySeverity") or {}
    if violations_by_severity:
        lines.append("### Violations by Severity")
        lines.append("")
        for severity, count in sorted(violations_by_severity.items(), key=lambda x: x[1], reverse=True):
            emoji = {"Fatal": "🔴", "Error": "🟠", "Warning": "🟡", "Info": "🔵", "Educational": "📚"}.get(severity, "⚪")
            lines.append(f"- {emoji} **{severity}:** {count}")
        lines.append("")

    # Rules summary
    lines.append("## 📋 Rules")
    lines.append("")
    if rules:
        lines.append(f"Evaluated {len(rules)} rule(s):")
        lines.append("")
        lines.append("| Rule ID | Violations |")
        lines.append("|---------|------------|")
        for rule in sorted(rules, key=lambda r: r.get("violationCount", 0), reverse=True):
            rule_id = rule.get("ruleId", "unknown")
            count = rule.get("violationCount", 0)
            lines.append(f"| `{rule_id}` | {count} |")
        lines.append("")
    else:
        lines.append("*No rules evaluated*")
        lines.append("")

    # Violations detail
    lines.append("## ⚠️ Violations")
    lines.append("")
    if violations:
        by_severity = {}
        for v in violations:
            severity = v.get("severity", "Unknown")
            if severity not in by_severity:
                by_severity[severity] = []
            by_severity[severity].append(v)

        for severity in ["Fatal", "Error", "Warning", "Info", "Educational"]:
            if severity not in by_severity:
                continue
            severity_violations = by_severity[severity]
            emoji = {"Fatal": "🔴", "Error": "🟠", "Warning": "🟡", "Info": "🔵", "Educational": "📚"}.get(severity, "⚪")
            lines.append(f"### {emoji} {severity} ({len(severity_violations)})")
            lines.append("")
            for v in severity_violations[:20]:
                rule_id = v.get("ruleId", "unknown")
                file_path = v.get("filePath", "unknown")
                line = v.get("line", "")
                message = v.get("message", "No description")
                location = f"{file_path}:{line}" if line else file_path
                lines.append(f"**`{rule_id}`** - {location}")
                lines.append(f"> {message}")
                if v.get("fixSuggestion"):
                    lines.append(f">")
                    lines.append(f"> 💡 *Fix:* {v['fixSuggestion']}")
                lines.append("")
            if len(severity_violations) > 20:
                remaining = len(severity_violations) - 20
                lines.append(f"*... and {remaining} more {severity} violations*")
                lines.append("")
    else:
        lines.append("✅ **No violations found!**")
        lines.append("")

    # Metadata dump (debugging)
    lines.append("## 🔍 Scan Metadata")
    lines.append("")
    lines.append("```json")
    lines.append(json.dumps(metadata, indent=2, default=str))
    lines.append("```")
    lines.append("")

    return "\n".join(lines)


def main():
    """Read Modulus-style input from stdin; write markdown report; print result JSON to stdout."""
    try:
        input_json = sys.stdin.read()
        input_data = json.loads(input_json)

        # Processor config: fully qualified keys (e.g. markdown-reporter.output-file).
        config = input_data.get("config") or {}
        if not isinstance(config, dict):
            config = {}
        output_file = config.get("markdown-reporter.output-file", "iarch-report.md")
        if isinstance(output_file, dict):
            output_file = "iarch-report.md"
        include_timestamp = str(config.get("markdown-reporter.include-timestamp", "true")).lower() == "true"

        markdown_content = generate_markdown_report(input_data)

        if include_timestamp:
            path = Path(output_file)
            stem = path.stem
            suffix = path.suffix
            timestamp = datetime.utcnow().strftime("%Y%m%d-%H%M%S")
            output_file = f"{stem}-{timestamp}{suffix}"

        output_path = Path(output_file)
        output_path.write_text(markdown_content, encoding="utf-8")

        # ProcessorResult: success, context, error, warnings (engine deserializes this)
        result = {
            "success": True,
            "context": {"markdown-reporter-message": f"Markdown report generated: {output_path.absolute()}"},
            "error": None,
            "warnings": []
        }
        print(json.dumps(result))
        sys.exit(0)

    except Exception as e:
        result = {
            "success": False,
            "context": {},
            "error": f"Failed to generate markdown report: {str(e)}",
            "warnings": []
        }
        print(json.dumps(result))
        sys.exit(1)


if __name__ == "__main__":
    main()
