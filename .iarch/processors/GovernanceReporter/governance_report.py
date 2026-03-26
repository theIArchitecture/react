#!/usr/bin/env python3
"""
Governance Intelligence Reporter - sink processor for the topology-signal pipeline.

Reads entropy-score, anomaly-clusters, and topology-health from context and writes:
  - {project-root}/.iarch/governance/anomaly-clusters-latest.json  (machine-readable, for evaluation)
  - {project-root}/.iarch/governance/governance-report-{timestamp}.md  (human-readable summary)

Input (stdin JSON) - Modulus-style:
  { "context": { ... }, "config": { ... }, "metadata": { ... } }

Output: writes both files; prints ProcessorResult JSON to stdout.
"""

import sys
import json
import os
from datetime import datetime, timezone
from pathlib import Path


ANOMALY_LABELS = {
    0: "UnexpectedCoupling",
    1: "CrossLayerMixing",
    2: "OrphanedType",
    3: "SemanticDuplicate",
    4: "ConceptBleed",
}

ANOMALY_DESCRIPTIONS = {
    "UnexpectedCoupling": "Types from different scopes cluster together — suggests hidden coupling or misplaced responsibility.",
    "CrossLayerMixing": "Types from different architectural layers cluster together — layer boundary is being violated.",
    "OrphanedType": "Type is isolated in embedding space but has dependency edges — semantically misaligned with its dependents.",
    "SemanticDuplicate": "Types in different scopes have nearly identical embedding vectors — may be duplicate concepts.",
    "ConceptBleed": "Concept from one scope bleeds into another via similar semantics.",
}


def anomaly_type_name(cluster):
    """Return the string name of the anomaly type, handling int or string values."""
    # Use explicit None checks — 0 is falsy so `or` would skip UnexpectedCoupling (value 0).
    for key in ("AnomalyType", "anomalyType", "anomaly_type"):
        raw = cluster.get(key)
        if raw is not None:
            if isinstance(raw, int):
                return ANOMALY_LABELS.get(raw, f"Anomaly({raw})")
            return str(raw)
    return "Unknown"


def get(d, *keys, default=None):
    """Try multiple key casings; return first hit."""
    for k in keys:
        if k in d and d[k] is not None:
            return d[k]
    return default


def write_json_dump(path, clusters, entropy, health, health_ratio, cluster_count):
    """Write the clusters JSON for machine consumption and go/no-go evaluation."""
    payload = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "entropy_score": entropy,
        "topology_health": health,
        "embedding_health_ratio": health_ratio,
        "total_cluster_count": cluster_count,
        "anomaly_cluster_count": len(clusters),
        "anomaly_clusters": clusters,
    }
    path.write_text(json.dumps(payload, indent=2, default=str), encoding="utf-8")
    return path


def extract_governance_config(context):
    """
    Pull governance parameters from the iarch-config context key.
    Returns a dict with the governance section, or {} if not present.
    Tries multiple serialisation forms (kebab-case keys from JsonPropertyName,
    camelCase, and PascalCase) so the report works regardless of how Modulus
    serialises the C# object.
    """
    raw = context.get("iarch-config") or {}
    gov = (
        raw.get("governance")
        or raw.get("Governance")
        or {}
    )
    return gov


def write_markdown_report(path, clusters, entropy, health, health_ratio, cluster_count, timestamp, gov_config=None, analysis_warnings=None):
    """Write a human-readable governance report."""
    lines = []

    now_fmt = datetime.now().strftime("%B %d, %Y %I:%M %p")
    lines += [
        "# Governance Intelligence Report",
        "",
        f"**Generated:** {now_fmt}",
        "",
    ]

    # ── Governance configuration ──────────────────────────────────────────────
    # Included so every report is self-contained and runs are reproducible.
    if gov_config:
        def _gv(key, alt=None, default="—"):
            """Try kebab-case, camelCase, and PascalCase variants."""
            camel = key.replace("-", "_")
            pascal = "".join(w.title() for w in key.split("-"))
            for k in (key, camel, pascal):
                v = gov_config.get(k)
                if v is not None:
                    return v
            if alt:
                v = gov_config.get(alt)
                if v is not None:
                    return v
            return default

        model      = _gv("embedding-model")
        host       = _gv("ollama-host")
        max_types  = _gv("embedding-max-types")
        eps        = _gv("dbscan-epsilon")
        min_pts    = _gv("dbscan-min-pts")
        purity     = _gv("min-cluster-purity")
        dup_thresh = _gv("duplicate-threshold")

        lines += [
            "## Governance Configuration",
            "",
            "| Parameter | Value |",
            "|-----------|-------|",
            f"| Embedding model | `{model}` |",
            f"| Ollama host | `{host}` |",
            f"| Max types embedded | `{max_types}` |",
            f"| DBSCAN epsilon | `{eps}` |",
            f"| DBSCAN minPts | `{min_pts}` |",
            f"| Min cluster purity | `{purity}` |",
            f"| Duplicate threshold | `{dup_thresh}` |",
            "",
        ]

    # ── Warnings ─────────────────────────────────────────────────────────────
    if analysis_warnings:
        lines += [
            "## Analysis Warnings",
            "",
        ]
        for w in analysis_warnings:
            lines += [f"> **Warning:** {w}", ""]

    # ── Topology health ──────────────────────────────────────────────────────
    if health:
        is_healthy = get(health, "IsHealthy", "isHealthy", "is_healthy", default=False)
        type_count = get(health, "TypeCount", "typeCount", "type_count", default=0)
        scope_count = get(health, "ScopeCount", "scopeCount", "scope_count", default=0)
        layer_count = get(health, "LayerCount", "layerCount", "layer_count", default=0)
        dep_count = get(health, "DependencyCount", "dependencyCount", "dependency_count", default=0)
        diag = get(health, "DiagnosticMessage", "diagnosticMessage", "diagnostic_message", default="")

        status = "Healthy" if is_healthy else "Insufficient signal"
        lines += [
            "## Topology Health",
            "",
            f"**Status:** {status}",
            f"- Types: {type_count}",
            f"- Scopes: {scope_count}",
            f"- Layers: {layer_count}",
            f"- Dependencies: {dep_count}",
        ]
        if diag:
            lines += [f"- Diagnostic: *{diag}*"]
        lines += [""]

    # ── Embedding signal quality ─────────────────────────────────────────────
    if health_ratio is not None:
        ratio_label = "Strong" if health_ratio >= 1.2 else ("Weak (< 1.2 — clusters may be unreliable)" if health_ratio > 0 else "N/A")
        lines += [
            "## Embedding Signal Quality",
            "",
            f"**Health Ratio** (intra-scope cohesion / inter-scope separation): `{health_ratio:.3f}` — {ratio_label}",
            f"**Total Clusters Detected:** {cluster_count}",
            "",
        ]

    # ── Entropy score ────────────────────────────────────────────────────────
    if entropy:
        score = get(entropy, "Score", "score", default=0.0)
        cycle = get(entropy, "CycleNumber", "cycleNumber", "cycle_number", default=1)
        baseline = get(entropy, "BaselineScore", "baselineScore", "baseline_score")
        delta_baseline = get(entropy, "DeltaFromBaseline", "deltaFromBaseline", "delta_from_baseline")
        delta_prev = get(entropy, "DeltaFromPreviousCycle", "deltaFromPreviousCycle", "delta_from_previous_cycle")
        comp_size = get(entropy, "ComponentSize", "componentSize", "component_size", default=0.0)
        comp_freq = get(entropy, "ComponentFrequency", "componentFrequency", "component_frequency", default=0.0)
        comp_density = get(entropy, "ComponentDensity", "componentDensity", "component_density", default=0.0)

        score_bar = "#" * int(score * 20)
        score_pct = f"{score * 100:.1f}%"

        lines += [
            "## Entropy Score",
            "",
            f"**Score:** `{score:.4f}` ({score_pct})  `[{score_bar:<20}]`",
            f"**Cycle:** {cycle}",
        ]
        if baseline is not None:
            delta_str = f"{delta_baseline:+.4f}" if delta_baseline is not None else "—"
            lines += [f"**Baseline:** `{baseline:.4f}`  Delta from baseline: `{delta_str}`"]
        if delta_prev is not None:
            lines += [f"**Delta from previous cycle:** `{delta_prev:+.4f}`"]
        lines += [
            "",
            "### Score Components",
            "",
            "| Component | Value | Weight |",
            "|-----------|-------|--------|",
            f"| Anomalous size (% of codebase) | `{comp_size:.4f}` | 0.40 |",
            f"| Anomaly frequency (% of clusters) | `{comp_freq:.4f}` | 0.30 |",
            f"| Intra-cluster disorder (1 − cohesion) | `{comp_density:.4f}` | 0.30 |",
            "",
        ]

    # ── Anomaly clusters ─────────────────────────────────────────────────────
    lines += [
        "## Anomaly Clusters",
        "",
    ]

    if not clusters:
        lines += ["*No anomalous clusters detected.*", ""]
    else:
        lines += [f"**{len(clusters)} anomalous cluster(s) found:**", ""]

        # Group by anomaly type
        by_type = {}
        for c in clusters:
            t = anomaly_type_name(c)
            by_type.setdefault(t, []).append(c)

        for atype, group in sorted(by_type.items()):
            desc = ANOMALY_DESCRIPTIONS.get(atype, "")
            lines += [
                f"### {atype} ({len(group)})",
                "",
                f"*{desc}*" if desc else "",
                "",
            ]
            for c in group:
                cluster_id = get(c, "ClusterId", "clusterId", "cluster_id", default="?")
                dominant_scope = get(c, "DominantScope", "dominantScope", "dominant_scope", default="?")
                dominant_layer = get(c, "DominantLayer", "dominantLayer", "dominant_layer", default="?")
                purity = get(c, "ClusterPurity", "clusterPurity", "cluster_purity", default=0.0)
                cohesion = get(c, "IntraClusterCohesion", "intraClusterCohesion", "intra_cluster_cohesion", default=0.0)
                raw_score = get(c, "RawAnomalyScore", "rawAnomalyScore", "raw_anomaly_score", default=0.0)
                members = get(c, "MemberTypeNames", "memberTypeNames", "member_type_names") or []
                samples = get(c, "SampleMembers", "sampleMembers", "sample_members") or members[:5]
                mixed_scopes = get(c, "MixedScopes", "mixedScopes", "mixed_scopes") or []
                mixed_layers = get(c, "MixedLayers", "mixedLayers", "mixed_layers") or []

                lines += [
                    f"**Cluster `{cluster_id[:8]}`** — {len(members)} types",
                    f"- Dominant scope: `{dominant_scope}` / layer: `{dominant_layer}`",
                    f"- Purity: `{purity:.2f}`  Cohesion: `{cohesion:.2f}`  Raw score: `{raw_score:.3f}`",
                ]
                if mixed_scopes:
                    lines += [f"- Mixed scopes: {', '.join(f'`{s}`' for s in mixed_scopes)}"]
                if mixed_layers:
                    lines += [f"- Mixed layers: {', '.join(f'`{l}`' for l in mixed_layers)}"]
                if samples:
                    sample_str = ", ".join(f"`{m}`" for m in samples[:8])
                    more = f" +{len(members) - 8} more" if len(members) > 8 else ""
                    lines += [f"- Sample members: {sample_str}{more}"]
                lines += [""]

    # ── Footer ───────────────────────────────────────────────────────────────
    lines += [
        "---",
        "",
        "*Generated by IArchitecture Governance Intelligence pipeline.*",
        f"*Run timestamp: {timestamp}*",
    ]

    path.write_text("\n".join(lines), encoding="utf-8")
    return path


def main():
    try:
        input_data = json.loads(sys.stdin.read())
        context = input_data.get("context") or {}
        config = input_data.get("config") or {}

        # Resolve output paths from config, defaulting to cwd.
        clusters_file = config.get("governance-reporter.clusters-file", "./anomaly-clusters-latest.json")
        report_file = config.get("governance-reporter.report-file", "./governance-report.md")

        # Pull governance keys from context
        entropy = context.get("entropy-score")
        clusters = context.get("anomaly-clusters") or []
        health = context.get("topology-health")
        health_ratio = context.get("embedding-health-ratio")
        cluster_count = context.get("topology-cluster-count") or 0

        timestamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
        gov_config = extract_governance_config(context)
        analysis_warnings = context.get("topology-analysis-warnings") or []

        json_path = write_json_dump(Path(clusters_file), clusters, entropy, health, health_ratio, cluster_count)
        md_path = write_markdown_report(Path(report_file), clusters, entropy, health, health_ratio, cluster_count, timestamp, gov_config, analysis_warnings)

        result = {
            "success": True,
            "context": {
                "governance-reporter.clusters-path": str(json_path.absolute()),
                "governance-reporter.report-path": str(md_path.absolute()),
            },
            "error": None,
            "warnings": [],
        }
        sys.stderr.write(f"Governance report written:\n")
        sys.stderr.write(f"  {json_path.absolute()}\n")
        sys.stderr.write(f"  {md_path.absolute()}\n")
        print(json.dumps(result))
        sys.exit(0)

    except Exception as e:
        result = {
            "success": False,
            "context": {},
            "error": f"Governance reporter failed: {str(e)}",
            "warnings": [],
        }
        print(json.dumps(result))
        sys.exit(1)


if __name__ == "__main__":
    main()
