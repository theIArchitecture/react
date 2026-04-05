#!/usr/bin/env python3
"""
Azure DevOps CA* Status Poller - polls ADO work items for governance proposal state changes.

Consumes the same ledger-state context key as jira-status-poller.
Produces the same ca-transitions context key — swap-in replacement at the seam.

Input (stdin JSON):
  context["ledger-state"] — list of GovernanceLedgerEntry objects (from governance-ledger-reader)
  config / env vars:
    ticket-base-url  / ADO_ORG_URL       e.g. https://dev.azure.com/myorg
    ticket-project   / ADO_PROJECT
    ticket-api-token / ADO_TOKEN         PAT or SYSTEM_ACCESSTOKEN
    ado-approval-state   — ADO state name meaning Approved   (default: "Approved")
    ado-rejection-state  — ADO state name meaning Rejected   (default: "Won't Fix")
    ado-promotion-state  — ADO state name meaning Promoted   (default: "Resolved")

State names are configurable because ADO process templates (Agile, Scrum, CMMI) use different names.

Output:
  context["ca-transitions"] — list of {proposal_id, generated_rule_id, new_status,
                                        review_notes, jira_ticket_key}
  (jira_ticket_key field reused as ado_work_item_id for downstream compatibility)
  Only entries whose ADO state changed to Approved, Rejected, or Promoted are included.
"""
import http.client
import json
import os
import sys
import urllib.parse


# ── HTTP helpers ───────────────────────────────────────────────────────────────

def _connect(url):
    parsed = urllib.parse.urlparse(url)
    use_https = parsed.scheme in ('', 'https')
    host = parsed.netloc or parsed.path.split('/')[0]
    cls = http.client.HTTPSConnection if use_https else http.client.HTTPConnection
    return cls(host)


def _request(conn, method, path, headers, body=None):
    conn.request(method, path, body=body, headers=headers)
    resp = conn.getresponse()
    raw = resp.read().decode('utf-8', errors='replace')
    try:
        return resp.status, json.loads(raw)
    except Exception:
        return resp.status, raw


def _cfg(config, key, env_var, default=''):
    return config.get(key) or os.environ.get(env_var, default)


# ── ADO helpers ────────────────────────────────────────────────────────────────

def _get_work_item(conn, org_url, project, token, work_item_id):
    """Fetch ADO work item fields: state and comments."""
    path = (
        f'/{urllib.parse.quote(project)}/_apis/wit/workitems/{work_item_id}'
        '?fields=System.State,System.History&api-version=7.1'
    )
    headers = {
        'Authorization': f'Bearer {token}',
        'Accept':        'application/json',
    }
    status, body = _request(conn, 'GET', path, headers)
    if status != 200 or not isinstance(body, dict):
        return None
    return body


def _get_work_item_comments(conn, org_url, project, token, work_item_id):
    """Fetch the most recent comment on an ADO work item."""
    path = (
        f'/{urllib.parse.quote(project)}/_apis/wit/workitems/{work_item_id}/comments'
        '?$top=1&$expand=all&api-version=7.1-preview.3'
    )
    headers = {
        'Authorization': f'Bearer {token}',
        'Accept':        'application/json',
    }
    status, body = _request(conn, 'GET', path, headers)
    if status != 200 or not isinstance(body, dict):
        return None
    comments = body.get('comments') or []
    if not comments:
        return None
    text = comments[-1].get('text') or ''
    # Strip HTML tags (ADO returns HTML in comment text)
    import re
    plain = re.sub(r'<[^>]+>', ' ', text).strip()
    return plain[:500] if plain else None


# ── Main ───────────────────────────────────────────────────────────────────────

def main():
    try:
        input_data = json.loads(sys.stdin.read())
        context = input_data.get('context') or {}
        config  = input_data.get('config') or {}

        ledger_state = context.get('ledger-state') or []
        warnings  = []
        errors    = []

        # Filter to Proposed entries that have an ADO work item ID stored in jira_ticket_key
        # (governance-ledger-jira-link stores the ticket key in jira_ticket_key regardless of provider)
        proposed = [
            e for e in ledger_state
            if e.get('status') == 'proposed' and e.get('jira_ticket_key')
        ]

        if not proposed:
            warnings.append('ado-status-poller: no Proposed entries with a linked work item - nothing to poll')
            print(json.dumps({'success': True, 'context': {'ca-transitions': []}, 'error': None, 'warnings': warnings}))
            return

        org_url  = _cfg(config, 'ticket-base-url',  'ADO_ORG_URL').rstrip('/')
        project  = _cfg(config, 'ticket-project',   'ADO_PROJECT')
        token    = _cfg(config, 'ticket-api-token', 'ADO_TOKEN') or os.environ.get('SYSTEM_ACCESSTOKEN', '')

        approval_state  = _cfg(config, 'ado-approval-state',  '', 'Approved')
        rejection_state = _cfg(config, 'ado-rejection-state', '', "Won't Fix")
        promotion_state = _cfg(config, 'ado-promotion-state', '', 'Resolved')

        missing = [k for k, v in [
            ('ADO_ORG_URL', org_url),
            ('ADO_PROJECT', project),
            ('ADO_TOKEN',   token),
        ] if not v]
        if missing:
            print(json.dumps({
                'success': False, 'context': {},
                'warnings': warnings,
                'error': '; '.join(f'ado-status-poller: {k} not set' for k in missing),
            }))
            return

        transitions = []

        conn = _connect(org_url)
        try:
            for entry in proposed:
                proposal_id   = entry.get('proposal_id', '')
                generated_id  = entry.get('generated_rule_id', '')
                work_item_id  = entry.get('jira_ticket_key', '')  # stored here regardless of provider

                item = _get_work_item(conn, org_url, project, token, work_item_id)
                if item is None:
                    warnings.append(f'ado-status-poller: could not fetch work item {work_item_id} - skipping')
                    continue

                state_name = item.get('fields', {}).get('System.State', '')
                warnings.append(f'ado-status-poller: work item {work_item_id} ({generated_id}) state={state_name!r}')

                if state_name == approval_state:
                    new_status = 'approved'
                elif state_name == rejection_state:
                    new_status = 'rejected'
                elif state_name == promotion_state:
                    new_status = 'library_promoted'
                else:
                    continue  # no decision yet

                review_notes = _get_work_item_comments(conn, org_url, project, token, work_item_id)
                transitions.append({
                    'proposal_id':       proposal_id,
                    'generated_rule_id': generated_id,
                    'new_status':        new_status,
                    'review_notes':      review_notes,
                    'jira_ticket_key':   work_item_id,  # keep field name for downstream compatibility
                })
        finally:
            conn.close()

        if transitions:
            warnings.append(
                f'ado-status-poller: {len(transitions)} transition(s) detected - '
                + ', '.join(f"{t['jira_ticket_key']}->{t['new_status']}" for t in transitions)
            )

        print(json.dumps({
            'success':  len(errors) == 0,
            'context':  {'ca-transitions': transitions},
            'error':    '; '.join(errors) if errors else None,
            'warnings': warnings,
        }))

    except Exception as exc:
        print(json.dumps({
            'success': False, 'context': {},
            'error':   f'ado-status-poller failed: {exc}',
            'warnings': [],
        }))
        sys.exit(1)


if __name__ == '__main__':
    main()
