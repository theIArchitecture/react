#!/usr/bin/env python3
"""
Azure DevOps Work Item Processor - creates ADO work items from ticket-requests.

Consumes the same ticket-requests context key as jira-processor.
Produces the same created-tickets context key — swap-in replacement at the seam.

Input (stdin JSON):
  context["ticket-requests"] — list of ticket-request objects (from write-*-ticket-requests)
  config / env vars:
    ticket-base-url   / ADO_ORG_URL       e.g. https://dev.azure.com/myorg
    ticket-project    / ADO_PROJECT
    ticket-api-token  / ADO_TOKEN         PAT or SYSTEM_ACCESSTOKEN
    ticket-work-item-type / ADO_WORK_ITEM_TYPE  defaults to "Task"

ticket-requests field mapping:
  summary     -> System.Title
  description -> System.Description
  priority    -> Microsoft.VSTS.Common.Priority (mapped: Critical=1, High=2, Medium=3, Low=4)
  labels      -> System.Tags (semicolon-separated)
  metadata.ruleContent / metadata.ruleFileName -> attached as text in description (ADO has no file attachment on creation)

Output:
  context["created-tickets"] — list of {key, url, summary} (identical schema to jira-processor output)
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


def _priority_to_ado(priority_str):
    """Map ticket-requests priority string to ADO integer priority (1-4)."""
    mapping = {'critical': 1, 'high': 2, 'medium': 3, 'low': 4}
    return mapping.get((priority_str or 'medium').lower(), 3)


# ── Main ───────────────────────────────────────────────────────────────────────

def main():
    try:
        input_data = json.loads(sys.stdin.read())
        context = input_data.get('context') or {}
        config  = input_data.get('config') or {}

        ticket_requests = context.get('ticket-requests') or []
        warnings = []
        errors   = []
        created_tickets = []

        if not ticket_requests:
            warnings.append('ado-work-item-processor: no ticket-requests in context - skipping')
            print(json.dumps({'success': True, 'context': {}, 'error': None, 'warnings': warnings}))
            return

        def _cfg(key, env_var, default=''):
            return config.get(key) or os.environ.get(env_var, default)

        org_url       = _cfg('ticket-base-url',        'ADO_ORG_URL').rstrip('/')
        project       = _cfg('ticket-project',         'ADO_PROJECT')
        token         = _cfg('ticket-api-token',       'ADO_TOKEN') or os.environ.get('SYSTEM_ACCESSTOKEN', '')
        work_item_type = _cfg('ticket-work-item-type', 'ADO_WORK_ITEM_TYPE') or 'Task'

        missing = [k for k, v in [
            ('ADO_ORG_URL',  org_url),
            ('ADO_PROJECT',  project),
            ('ADO_TOKEN',    token),
        ] if not v]
        if missing:
            print(json.dumps({
                'success': False, 'context': {}, 'warnings': warnings,
                'error': '; '.join(f'ado-work-item-processor: {k} not set' for k in missing),
            }))
            return

        auth_headers = {
            'Authorization': f'Bearer {token}',
            'Accept':        'application/json',
            'Content-Type':  'application/json-patch+json',
        }

        # ADO work item creation uses JSON Patch
        # POST {orgUrl}/{project}/_apis/wit/workitems/${type}?api-version=7.1
        type_encoded = urllib.parse.quote(work_item_type)
        api_path = f'/{urllib.parse.quote(project)}/_apis/wit/workitems/${type_encoded}?api-version=7.1'

        conn = _connect(org_url)
        try:
            for ticket in ticket_requests:
                summary     = ticket.get('summary', '')
                description = ticket.get('description', '')
                priority    = _priority_to_ado(ticket.get('priority'))
                labels      = ticket.get('labels') or []
                meta        = ticket.get('metadata') or {}

                # Append rule content to description if present
                rule_content  = meta.get('ruleContent') or ''
                rule_filename = meta.get('ruleFileName') or ''
                if rule_content and rule_filename:
                    description = f"{description}\n\n---\n**Rule file: {rule_filename}**\n```\n{rule_content[:2000]}\n```"

                patch_doc = [
                    {'op': 'add', 'path': '/fields/System.Title',       'value': summary},
                    {'op': 'add', 'path': '/fields/System.Description', 'value': description},
                    {'op': 'add', 'path': '/fields/Microsoft.VSTS.Common.Priority', 'value': priority},
                ]
                if labels:
                    patch_doc.append({
                        'op': 'add',
                        'path': '/fields/System.Tags',
                        'value': '; '.join(labels),
                    })

                body = json.dumps(patch_doc).encode('utf-8')
                status, resp = _request(conn, 'POST', api_path, auth_headers, body)

                if status not in (200, 201):
                    errors.append(
                        f"ado-work-item-processor: failed to create '{summary}' - HTTP {status}: {resp}"
                    )
                    continue

                work_item_id  = resp.get('id', '?') if isinstance(resp, dict) else '?'
                work_item_url = f"{org_url}/{urllib.parse.quote(project)}/_workitems/edit/{work_item_id}"

                warnings.append(f'ado-work-item-processor: created work item {work_item_id} - {summary}')
                created_tickets.append({
                    'key':     str(work_item_id),
                    'url':     work_item_url,
                    'summary': summary,
                })
        finally:
            conn.close()

        print(json.dumps({
            'success':  len(errors) == 0,
            'context':  {'created-tickets': created_tickets} if created_tickets else {},
            'error':    '; '.join(errors) if errors else None,
            'warnings': warnings,
        }))

    except Exception as exc:
        print(json.dumps({
            'success': False, 'context': {},
            'error':   f'ado-work-item-processor failed: {exc}',
            'warnings': [],
        }))
        sys.exit(1)


if __name__ == '__main__':
    main()
