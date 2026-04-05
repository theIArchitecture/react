#!/usr/bin/env python3
"""
Teams Processor - posts message-requests to Microsoft Teams via Incoming Webhook.

Swap-in replacement for slack-processor at the message-requests seam.
Ignores Slack-specific `blocks` field; builds Teams Adaptive Cards from
`text` and `metadata` (violation counts, repository, PR number, SHA).

Auth: Teams Incoming Webhook only (no bot token mode - Teams webhooks are self-contained).

Config / env vars:
  messaging-webhook-url / MESSAGING_WEBHOOK_URL  — Teams Incoming Webhook URL (required)

Input (stdin JSON):
  context["message-requests"] — list of message-request objects (from write-message-requests)
    Each request uses:
      text     — plain text summary (used as card title/fallback)
      metadata — {violationCount, errorCount, warningCount, repository, sha, prNumber}
      channel  — ignored (channel is baked into Teams webhook URL)

Output:
  warnings listing posted messages; errors for any failures
"""
import http.client
import json
import os
import sys
import urllib.parse


# ── Teams Adaptive Card builder ────────────────────────────────────────────────

def _severity_color(error_count):
    """Map error count to Teams card theme colour (hex, no #)."""
    if error_count > 0:
        return 'attention'   # red
    return 'good'            # green


def _build_adaptive_card(text, metadata, created_tickets=None):
    """
    Build a Teams Adaptive Card payload from message-request fields.

    Uses Adaptive Card schema 1.4 — supported by all modern Teams clients.
    Outer envelope is the Teams Incoming Webhook message format.
    """
    meta          = metadata or {}
    total         = meta.get('violationCount', 0)
    error_count   = meta.get('errorCount', 0)
    warn_count    = meta.get('warningCount', 0)
    repository    = meta.get('repository') or ''
    sha           = meta.get('sha') or ''
    pr_number     = meta.get('prNumber') or ''

    repo_short    = repository.rsplit('/', 1)[-1] if repository else ''
    sha_short     = sha[:7] if sha else ''

    # Title line
    if total == 0:
        title = 'IArchitecture: No violations detected'
        title_color = 'good'
    else:
        title = f'IArchitecture: {total} violation(s) detected'
        title_color = _severity_color(error_count)

    # Build card body elements
    body = [
        {
            'type':   'TextBlock',
            'text':   title,
            'weight': 'Bolder',
            'size':   'Medium',
            'color':  title_color,
            'wrap':   True,
        }
    ]

    # Context facts (repo, PR, commit)
    facts = []
    if repo_short:
        facts.append({'title': 'Repository', 'value': repo_short})
    if pr_number:
        facts.append({'title': 'Pull Request', 'value': f'#{pr_number}'})
    if sha_short:
        facts.append({'title': 'Commit', 'value': sha_short})
    if total > 0:
        facts.append({'title': 'Errors',   'value': str(error_count)})
        facts.append({'title': 'Warnings', 'value': str(warn_count)})

    if facts:
        body.append({'type': 'FactSet', 'facts': facts})

    # Linked tickets section (if jira-processor or ado-work-item-processor ran upstream)
    if created_tickets:
        ticket_lines = '\n\n'.join(
            f"[{t.get('key', '?')}]({t.get('url', '#')}) - {t.get('summary', '')}"
            for t in created_tickets[:10]
        )
        body.append({'type': 'TextBlock', 'text': 'Tickets Created', 'weight': 'Bolder', 'spacing': 'Medium'})
        body.append({'type': 'TextBlock', 'text': ticket_lines, 'wrap': True})

    # Actions
    actions = []
    if repository and pr_number:
        # Best-effort PR URL — works for GitHub; ADO URL is different but text fallback covers it
        pr_url = f'https://github.com/{repository}/pull/{pr_number}'
        actions.append({
            'type':  'Action.OpenUrl',
            'title': 'View Pull Request',
            'url':   pr_url,
        })
    elif repository and sha:
        commit_url = f'https://github.com/{repository}/commit/{sha}'
        actions.append({
            'type':  'Action.OpenUrl',
            'title': 'View Commit',
            'url':   commit_url,
        })

    card = {
        '$schema': 'http://adaptivecards.io/schemas/adaptive-card.json',
        'type':    'AdaptiveCard',
        'version': '1.4',
        'body':    body,
    }
    if actions:
        card['actions'] = actions

    # Teams Incoming Webhook envelope
    return {
        'type': 'message',
        'attachments': [
            {
                'contentType': 'application/vnd.microsoft.card.adaptive',
                'contentUrl':  None,
                'content':     card,
            }
        ],
    }


# ── HTTP helpers ───────────────────────────────────────────────────────────────

def _post_json(url, body_dict):
    """POST JSON to a full URL. Returns (status, raw_response)."""
    parsed = urllib.parse.urlparse(url)
    use_https = parsed.scheme in ('', 'https')
    host = parsed.netloc
    path = parsed.path
    if parsed.query:
        path += '?' + parsed.query

    cls = http.client.HTTPSConnection if use_https else http.client.HTTPConnection
    conn = cls(host)
    try:
        body = json.dumps(body_dict).encode('utf-8')
        conn.request('POST', path, body=body, headers={
            'Content-Type': 'application/json; charset=utf-8',
        })
        resp = conn.getresponse()
        raw  = resp.read().decode('utf-8', errors='replace')
        return resp.status, raw
    finally:
        conn.close()


# ── Main ───────────────────────────────────────────────────────────────────────

def main():
    try:
        input_data = json.loads(sys.stdin.read())
        context = input_data.get('context') or {}
        config  = input_data.get('config') or {}

        message_requests = context.get('message-requests') or []
        created_tickets  = context.get('created-tickets') or []
        warnings = []
        errors   = []

        if not message_requests:
            warnings.append('teams-processor: no message-requests in context - skipping')
            print(json.dumps({'success': True, 'context': {}, 'error': None, 'warnings': warnings}))
            return

        def _cfg(key, env_var, default=''):
            return config.get(key) or os.environ.get(env_var, default)

        webhook_url = _cfg('messaging-webhook-url', 'MESSAGING_WEBHOOK_URL')

        if not webhook_url:
            print(json.dumps({
                'success': False, 'context': {}, 'warnings': warnings,
                'error': 'teams-processor: MESSAGING_WEBHOOK_URL must be set',
            }))
            return

        for req in message_requests:
            text     = req.get('text', '')
            metadata = req.get('metadata') or {}
            # Pass created_tickets from context (may have come from jira-processor or ado-work-item-processor)
            tickets  = req.get('created_tickets') or created_tickets

            card_payload = _build_adaptive_card(text, metadata, tickets)

            status, resp = _post_json(webhook_url, card_payload)

            # Teams webhook returns HTTP 202 with body "1" on success
            if status in (200, 202):
                warnings.append(f'teams-processor: message posted (HTTP {status})')
            else:
                errors.append(f'teams-processor: webhook POST failed - HTTP {status}: {resp[:200]}')

        print(json.dumps({
            'success':  len(errors) == 0,
            'context':  {},
            'error':    '; '.join(errors) if errors else None,
            'warnings': warnings,
        }))

    except Exception as exc:
        print(json.dumps({
            'success':  False,
            'context':  {},
            'error':    f'teams-processor failed: {exc}',
            'warnings': [],
        }))
        sys.exit(1)


if __name__ == '__main__':
    main()
