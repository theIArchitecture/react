#!/usr/bin/env python3
"""
Write Ticket Requests - converts violations to system-agnostic ticket-requests.

Input (stdin JSON):
  context["violations"]        — list of violation objects
  context["ci-environment"]  — optional CI metadata (repository, sha, pr_number, etc.)
  config["priority"], config["labels"], config["summary"] — optional overrides

Output:
  context["ticket-requests"] — system-agnostic list consumed by jira-processor
"""
import json
import os
import sys


def _build_summary(total, errors, wf_ctx):
    if wf_ctx and wf_ctx.get('repository'):
        repo = wf_ctx['repository'].rsplit('/', 1)[-1]
        if wf_ctx.get('pr_number'):
            return f"IArchitecture: {total} violation(s) in {repo} PR #{wf_ctx['pr_number']} ({errors} error(s))"
        if wf_ctx.get('sha'):
            return f"IArchitecture: {total} violation(s) in {repo} @ {wf_ctx['sha'][:7]} ({errors} error(s))"
        return f"IArchitecture: {total} violation(s) in {repo} ({errors} error(s))"
    return f"IArchitecture: {total} architectural violation(s) detected ({errors} error(s))"


def _build_description(violations, total, errors, warns, wf_ctx):
    lines = []
    if wf_ctx:
        if wf_ctx.get('repository'): lines.append(f"Repository: {wf_ctx['repository']}")
        if wf_ctx.get('pr_number'):  lines.append(f"PR: #{wf_ctx['pr_number']}")
        if wf_ctx.get('sha'):        lines.append(f"Commit: {wf_ctx['sha'][:7]}")
        if lines:
            lines.append('')

    lines.append(f"Violations: {total} total ({errors} error(s), {warns} warning(s))")
    lines.append('')

    for v in violations[:20]:
        file_path = v.get('file_path') or 'unknown'
        file_name = os.path.basename(file_path)
        line_num  = v.get('line_number') or ''
        loc       = f'{file_name}:{line_num}' if line_num else file_name
        name      = v.get('name') or v.get('rule_id') or 'unknown'
        lines.append(f"[{v.get('severity', 'Warning')}] {name}  -  {loc}")

    if total > 20:
        lines.append(f'...and {total - 20} more violations')

    return '\n'.join(lines)


def main():
    try:
        input_data = json.loads(sys.stdin.read())
        context = input_data.get('context') or {}
        config  = input_data.get('config') or {}

        violations = context.get('violations') or []
        wf_ctx     = context.get('ci-environment')

        total  = len(violations)
        errors = sum(1 for v in violations if v.get('severity') in ('Error', 'Fatal'))
        warns  = sum(1 for v in violations if v.get('severity') == 'Warning')

        priority   = config.get('priority', 'Medium')
        labels_raw = config.get('labels', 'iarchitecture')
        labels     = [l.strip() for l in labels_raw.split(',')]
        summary    = config.get('summary') or _build_summary(total, errors, wf_ctx)
        description = _build_description(violations, total, errors, warns, wf_ctx)

        print(json.dumps({
            'success': True,
            'context': {
                'ticket-requests': [{
                    'summary':     summary,
                    'description': description,
                    'priority':    priority,
                    'labels':      labels,
                    'metadata': {
                        'violationCount': total,
                        'errorCount':     errors,
                        'warningCount':   warns,
                        'repository': wf_ctx.get('repository') if wf_ctx else None,
                        'sha':        wf_ctx.get('sha')        if wf_ctx else None,
                        'prNumber':   wf_ctx.get('pr_number')  if wf_ctx else None,
                    },
                }]
            },
            'error':   None,
            'warnings': [],
        }))

    except Exception as exc:
        print(json.dumps({
            'success': False,
            'context': {},
            'error':   f'write-ticket-requests failed: {exc}',
            'warnings': [],
        }))
        sys.exit(1)


if __name__ == '__main__':
    main()
