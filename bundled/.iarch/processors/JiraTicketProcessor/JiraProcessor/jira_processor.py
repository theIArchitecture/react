#!/usr/bin/env python3
"""
Jira Processor - creates Jira issues from ticket-requests via REST API.

Input (stdin JSON):
  context["ticket-requests"] — list of ticket-request objects (from write-*-ticket-requests processors)
  config / env vars:
    ticket-base-url   / TICKET_BASE_URL
    ticket-user-email / TICKET_USER_EMAIL
    ticket-api-token  / TICKET_API_TOKEN
    ticket-project-key/ TICKET_PROJECT_KEY
    ticket-assignee-id/ TICKET_ASSIGNEE_ID  (optional)
    ticket-issue-type — defaults to "Task"

Output:
  context["created-tickets"] — list of {key, url, summary} for each created issue
  warnings listing created issue keys; errors for any failures
"""
import base64
import http.client
import json
import os
import sys
import urllib.parse


# ── HTTP helpers ──────────────────────────────────────────────────────────────

def _connect(base_url):
    """Return (connection, base_path) for the given Jira base URL."""
    parsed = urllib.parse.urlparse(base_url)
    use_https = parsed.scheme in ('', 'https')
    host = parsed.netloc or parsed.path.split('/')[0]
    base_path = parsed.path.rstrip('/')
    cls = http.client.HTTPSConnection if use_https else http.client.HTTPConnection
    return cls(host), base_path


def _request(conn, method, path, headers, body=None):
    """Send request, return (status, parsed_body)."""
    conn.request(method, path, body=body, headers=headers)
    resp = conn.getresponse()
    raw = resp.read().decode('utf-8', errors='replace')
    try:
        return resp.status, json.loads(raw)
    except Exception:
        return resp.status, raw


def _multipart_body(boundary, file_name, content):
    """Minimal multipart/form-data body for a single file field named 'file'."""
    data = content.encode('utf-8') if isinstance(content, str) else content
    b = boundary.encode()
    return (
        b'--' + b + b'\r\n'
        + f'Content-Disposition: form-data; name="file"; filename="{file_name}"\r\n'.encode()
        + b'Content-Type: text/plain; charset=utf-8\r\n\r\n'
        + data + b'\r\n'
        + b'--' + b + b'--\r\n'
    )


# ── Main ──────────────────────────────────────────────────────────────────────

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
            warnings.append('jira-processor: no ticket-requests in context - skipping')
            print(json.dumps({'success': True, 'context': {}, 'error': None, 'warnings': warnings}))
            return

        def _cfg(key, env_var, default=''):
            return config.get(key) or os.environ.get(env_var, default)

        base_url    = _cfg('ticket-base-url',    'TICKET_BASE_URL')
        user_email  = _cfg('ticket-user-email',  'TICKET_USER_EMAIL')
        api_token   = _cfg('ticket-api-token',   'TICKET_API_TOKEN')
        project_key = _cfg('ticket-project-key', 'TICKET_PROJECT_KEY')
        assignee_id = _cfg('ticket-assignee-id', 'TICKET_ASSIGNEE_ID')
        issue_type  = _cfg('ticket-issue-type',  '',                  'Task')

        missing = [k for k, v in [
            ('TICKET_BASE_URL', base_url),
            ('TICKET_USER_EMAIL', user_email),
            ('TICKET_API_TOKEN', api_token),
            ('TICKET_PROJECT_KEY', project_key),
        ] if not v]
        if missing:
            print(json.dumps({
                'success': False, 'context': {}, 'warnings': warnings,
                'error': '; '.join(f'jira-processor: {k} not set' for k in missing),
            }))
            return

        credentials = base64.b64encode(f'{user_email}:{api_token}'.encode()).decode()
        auth_headers = {
            'Authorization': f'Basic {credentials}',
            'Content-Type':  'application/json',
            'Accept':        'application/json',
        }

        for ticket in ticket_requests:
            conn, base_path = _connect(base_url)
            try:
                fields = {
                    'project':   {'key': project_key},
                    'summary':   ticket.get('summary', ''),
                    'description': {
                        'type': 'doc', 'version': 1,
                        'content': [{'type': 'paragraph', 'content': [
                            {'type': 'text', 'text': ticket.get('description', '')}
                        ]}],
                    },
                    'issuetype': {'name': issue_type},
                    'labels':    ticket.get('labels') or [],
                    'priority':  {'name': ticket.get('priority', 'Medium')},
                }
                if assignee_id:
                    fields['assignee'] = {'accountId': assignee_id}

                body = json.dumps({'fields': fields}).encode('utf-8')
                status, resp = _request(conn, 'POST', f'{base_path}/rest/api/3/issue', auth_headers, body)

                if status not in (200, 201):
                    errors.append(
                        f"jira-processor: failed to create '{ticket.get('summary', '')}' — HTTP {status}: {resp}"
                    )
                    continue

                issue_key = resp.get('key', '?') if isinstance(resp, dict) else '?'
                warnings.append(f'jira-processor: created issue {issue_key} - {ticket.get("summary", "")}')
                created_tickets.append({
                    'key':     issue_key,
                    'url':     f'{base_url.rstrip("/")}/browse/{issue_key}',
                    'summary': ticket.get('summary', ''),
                })

                # Attach .iarch rule file if present
                meta         = ticket.get('metadata') or {}
                rule_content  = meta.get('ruleContent') or ''
                rule_file_name = meta.get('ruleFileName') or ''
                if rule_content and rule_file_name:
                    a_conn, _ = _connect(base_url)
                    try:
                        boundary = f'iarch_{issue_key.replace("-", "_")}'
                        mp_body  = _multipart_body(boundary, rule_file_name, rule_content)
                        a_headers = {
                            'Authorization':     f'Basic {credentials}',
                            'X-Atlassian-Token': 'no-check',
                            'Accept':            'application/json',
                            'Content-Type':      f'multipart/form-data; boundary={boundary}',
                        }
                        a_status, _ = _request(
                            a_conn, 'POST',
                            f'{base_path}/rest/api/3/issue/{issue_key}/attachments',
                            a_headers, mp_body,
                        )
                        if a_status in (200, 201):
                            warnings.append(f'jira-processor: attached {rule_file_name} to {issue_key}')
                        else:
                            warnings.append(
                                f'jira-processor: issue {issue_key} created but attachment failed — HTTP {a_status}'
                            )
                    except Exception as ae:
                        warnings.append(
                            f'jira-processor: issue {issue_key} created but attachment failed — {ae}'
                        )
                    finally:
                        a_conn.close()

            except Exception as ex:
                errors.append(f"jira-processor: failed to create '{ticket.get('summary', '')}' — {ex}")
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
            'error':   f'jira-processor failed: {exc}',
            'warnings': [],
        }))
        sys.exit(1)


if __name__ == '__main__':
    main()
