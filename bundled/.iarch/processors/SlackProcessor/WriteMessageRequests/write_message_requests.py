#!/usr/bin/env python3
"""
Write Message Requests - converts violations to system-agnostic message-requests.

Input (stdin JSON):
  context["violations"]        — list of violation objects
  context["ci-environment"]  — optional CI metadata (repository, sha, pr_number, etc.)
  context["created-tickets"]   — optional list of {key, url, summary} from jira-processor
  config["channel"]            — optional channel override (added to each request)
  config["priority-filter"]    — optional comma-separated severities to include (e.g. "Fatal,Error")
  config["max-violations"]     — max violations to include in body (default 20)

Output:
  context["message-requests"]  — system-agnostic list consumed by slack-processor
"""
import json
import os
import sys


def _severity_emoji(severity):
    return {
        'Fatal':   ':red_circle:',
        'Error':   ':large_orange_circle:',
        'Warning': ':large_yellow_circle:',
    }.get(severity, ':white_circle:')


def _build_text(total, errors, warns, wf_ctx):
    if wf_ctx and wf_ctx.get('repository'):
        repo = wf_ctx['repository'].rsplit('/', 1)[-1]
        if wf_ctx.get('pr_number'):
            return f"IArchitecture: *{total} violation(s)* in `{repo}` PR #{wf_ctx['pr_number']} ({errors} error(s))"
        if wf_ctx.get('sha'):
            return f"IArchitecture: *{total} violation(s)* in `{repo}` @ `{wf_ctx['sha'][:7]}` ({errors} error(s))"
        return f"IArchitecture: *{total} violation(s)* in `{repo}` ({errors} error(s))"
    return f"IArchitecture: *{total} architectural violation(s)* detected ({errors} error(s))"


def _build_blocks(violations, total, errors, warns, wf_ctx, max_violations, created_tickets=None):
    blocks = []

    # Header
    header_text = _build_text(total, errors, warns, wf_ctx)
    blocks.append({
        'type': 'section',
        'text': {'type': 'mrkdwn', 'text': header_text}
    })

    # Context line (repo/PR/commit details)
    ctx_elements = []
    if wf_ctx:
        if wf_ctx.get('repository'):
            ctx_elements.append({'type': 'mrkdwn', 'text': f"Repo: `{wf_ctx['repository']}`"})
        if wf_ctx.get('pr_number'):
            ctx_elements.append({'type': 'mrkdwn', 'text': f"PR: #{wf_ctx['pr_number']}"})
        if wf_ctx.get('sha'):
            ctx_elements.append({'type': 'mrkdwn', 'text': f"Commit: `{wf_ctx['sha'][:7]}`"})
    if ctx_elements:
        blocks.append({'type': 'context', 'elements': ctx_elements})

    blocks.append({'type': 'divider'})

    # Violation list
    shown = violations[:max_violations]
    if shown:
        lines = []
        for v in shown:
            file_path = v.get('file_path') or v.get('filePath') or 'unknown'
            file_name = os.path.basename(file_path)
            line_num  = v.get('line_number') or v.get('lineNumber') or ''
            loc       = f'{file_name}:{line_num}' if line_num else file_name
            name      = v.get('name') or v.get('rule_id') or v.get('violationId') or 'unknown'
            severity  = v.get('severity', 'Warning')
            lines.append(f"{_severity_emoji(severity)} *{name}*  —  `{loc}`")

        if total > max_violations:
            lines.append(f'_...and {total - max_violations} more_')

        blocks.append({
            'type': 'section',
            'text': {'type': 'mrkdwn', 'text': '\n'.join(lines)}
        })

    # Jira tickets (if jira-processor ran upstream)
    if created_tickets:
        links = '\n'.join(
            f"• <{t['url']}|{t['key']}> — {t.get('summary', '')}"
            for t in created_tickets
        )
        blocks.append({
            'type': 'section',
            'text': {'type': 'mrkdwn', 'text': f":jira: *Jira Tickets Created*\n{links}"}
        })

    # Summary footer
    blocks.append({
        'type': 'context',
        'elements': [{'type': 'mrkdwn', 'text': f":bar_chart: {total} total  |  {errors} error(s)  |  {warns} warning(s)"}]
    })

    return blocks


def main():
    try:
        input_data = json.loads(sys.stdin.read())
        context = input_data.get('context') or {}
        config  = input_data.get('config') or {}

        violations      = context.get('violations') or []
        wf_ctx          = context.get('ci-environment')
        created_tickets = context.get('created-tickets') or []

        # Optional severity filter
        priority_filter = config.get('priority-filter', '')
        if priority_filter:
            allowed = {s.strip() for s in priority_filter.split(',')}
            violations = [v for v in violations if v.get('severity') in allowed]

        total  = len(violations)
        errors = sum(1 for v in violations if v.get('severity') in ('Error', 'Fatal'))
        warns  = sum(1 for v in violations if v.get('severity') == 'Warning')

        max_violations = int(config.get('max-violations', 20))
        channel        = config.get('channel', '')

        text   = _build_text(total, errors, warns, wf_ctx)
        blocks = _build_blocks(violations, total, errors, warns, wf_ctx, max_violations, created_tickets)

        request = {
            'text':   text,
            'blocks': blocks,
            'metadata': {
                'violationCount': total,
                'errorCount':     errors,
                'warningCount':   warns,
                'repository': wf_ctx.get('repository') if wf_ctx else None,
                'sha':        wf_ctx.get('sha')        if wf_ctx else None,
                'prNumber':   wf_ctx.get('pr_number')  if wf_ctx else None,
            },
        }
        if channel:
            request['channel'] = channel

        print(json.dumps({
            'success':  True,
            'context':  {'message-requests': [request]},
            'error':    None,
            'warnings': [],
        }))

    except Exception as exc:
        print(json.dumps({
            'success':  False,
            'context':  {},
            'error':    f'write-message-requests failed: {exc}',
            'warnings': [],
        }))
        sys.exit(1)


if __name__ == '__main__':
    main()
