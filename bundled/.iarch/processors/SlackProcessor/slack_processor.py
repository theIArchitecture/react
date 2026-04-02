#!/usr/bin/env python3
"""
Slack Processor - posts message-requests to Slack.

Two auth modes (checked in order):
  1. Incoming webhook  — MESSAGING_WEBHOOK_URL / messaging-webhook-url
     Simple: POST JSON directly to the webhook URL. No token needed.
  2. Bot token         — MESSAGING_BOT_TOKEN / messaging-bot-token
                       + MESSAGING_CHANNEL  / messaging-channel
     Uses chat.postMessage on the Slack Web API.

Config / env vars:
  messaging-webhook-url / MESSAGING_WEBHOOK_URL  — incoming webhook URL (mode 1)
  messaging-bot-token   / MESSAGING_BOT_TOKEN    — OAuth bot token (mode 2)
  messaging-channel     / MESSAGING_CHANNEL      — channel ID or name, e.g. #arch-alerts (mode 2)
  messaging-username    / MESSAGING_USERNAME      — display name override (optional)
  messaging-icon-emoji  / MESSAGING_ICON_EMOJI    — bot icon, e.g. :robot_face: (optional)

Input (stdin JSON):
  context["message-requests"] — list of message-request objects (from write-message-requests)

Output:
  warnings listing posted message timestamps; errors for any failures
"""
import http.client
import json
import os
import sys
import urllib.parse


# ── HTTP helpers ──────────────────────────────────────────────────────────────

def _post_json(url, body_dict):
    """POST JSON to a full URL. Returns (status, parsed_body)."""
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
            'Accept':       'application/json',
        })
        resp = conn.getresponse()
        raw  = resp.read().decode('utf-8', errors='replace')
        try:
            return resp.status, json.loads(raw)
        except Exception:
            return resp.status, raw
    finally:
        conn.close()


def _post_api(token, body_dict):
    """POST to Slack Web API (api.slack.com). Returns (status, parsed_body)."""
    conn = http.client.HTTPSConnection('slack.com')
    try:
        body = json.dumps(body_dict).encode('utf-8')
        conn.request('POST', '/api/chat.postMessage', body=body, headers={
            'Authorization': f'Bearer {token}',
            'Content-Type':  'application/json; charset=utf-8',
            'Accept':        'application/json',
        })
        resp = conn.getresponse()
        raw  = resp.read().decode('utf-8', errors='replace')
        try:
            return resp.status, json.loads(raw)
        except Exception:
            return resp.status, raw
    finally:
        conn.close()


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    try:
        input_data = json.loads(sys.stdin.read())
        context = input_data.get('context') or {}
        config  = input_data.get('config') or {}

        message_requests = context.get('message-requests') or []
        warnings = []
        errors   = []

        if not message_requests:
            warnings.append('slack-processor: no message-requests in context - skipping')
            print(json.dumps({'success': True, 'context': {}, 'error': None, 'warnings': warnings}))
            return

        def _cfg(key, env_var, default=''):
            return config.get(key) or os.environ.get(env_var, default)

        webhook_url = _cfg('messaging-webhook-url', 'MESSAGING_WEBHOOK_URL')
        bot_token   = _cfg('messaging-bot-token',   'MESSAGING_BOT_TOKEN')
        channel     = _cfg('messaging-channel',     'MESSAGING_CHANNEL')
        username    = _cfg('messaging-username',    'MESSAGING_USERNAME')
        icon_emoji  = _cfg('messaging-icon-emoji',  'MESSAGING_ICON_EMOJI')

        if not webhook_url and not bot_token:
            print(json.dumps({
                'success': False, 'context': {}, 'warnings': warnings,
                'error': 'slack-processor: MESSAGING_WEBHOOK_URL or MESSAGING_BOT_TOKEN must be set',
            }))
            return

        if bot_token and not channel:
            print(json.dumps({
                'success': False, 'context': {}, 'warnings': warnings,
                'error': 'slack-processor: MESSAGING_CHANNEL must be set when using bot token auth',
            }))
            return

        for req in message_requests:
            # Build the Slack payload from the message-request
            payload = {
                'text':   req.get('text', ''),
                'blocks': req.get('blocks', []),
            }
            # Channel: request-level override, then config/env
            effective_channel = req.get('channel') or channel
            if username:
                payload['username'] = username
            if icon_emoji:
                payload['icon_emoji'] = icon_emoji

            if webhook_url:
                # Mode 1: incoming webhook — channel is baked into the webhook URL
                status, resp = _post_json(webhook_url, payload)
                if status == 200 and resp == 'ok':
                    warnings.append('slack-processor: message posted via webhook')
                elif status == 200 and isinstance(resp, dict) and resp.get('ok'):
                    warnings.append('slack-processor: message posted via webhook')
                else:
                    errors.append(f'slack-processor: webhook POST failed — HTTP {status}: {resp}')

            else:
                # Mode 2: bot token + chat.postMessage
                if effective_channel:
                    payload['channel'] = effective_channel
                status, resp = _post_api(bot_token, payload)
                if status == 200 and isinstance(resp, dict) and resp.get('ok'):
                    ts = resp.get('ts', '')
                    warnings.append(f'slack-processor: message posted, ts={ts}')
                else:
                    api_error = resp.get('error', resp) if isinstance(resp, dict) else resp
                    errors.append(f'slack-processor: chat.postMessage failed — HTTP {status}: {api_error}')

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
            'error':    f'slack-processor failed: {exc}',
            'warnings': [],
        }))
        sys.exit(1)


if __name__ == '__main__':
    main()
