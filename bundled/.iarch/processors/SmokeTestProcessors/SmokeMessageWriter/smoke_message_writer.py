#!/usr/bin/env python3
"""
Smoke test: emits one hardcoded message-request to verify Slack connectivity.
No upstream dependencies — drops straight into the slack-processor.
"""
import json
import sys


def main():
    try:
        json.loads(sys.stdin.read())  # consume stdin; no inputs needed
        print(json.dumps({
            "success": True,
            "context": {
                "message-requests": [{
                    "text": ":white_check_mark: IArchitecture smoke test — Slack connectivity confirmed.",
                    "blocks": [
                        {
                            "type": "section",
                            "text": {
                                "type": "mrkdwn",
                                "text": (
                                    ":white_check_mark: *IArchitecture Smoke Test*\n"
                                    "Slack connectivity confirmed. "
                                    "This message was sent by the `test-smoke-slack` workflow."
                                ),
                            },
                        }
                    ],
                    "metadata": {"smokeTest": True},
                }]
            },
            "error": None,
            "warnings": [],
        }))
    except Exception as exc:
        print(json.dumps({"success": False, "context": {}, "error": str(exc), "warnings": []}))
        sys.exit(1)


if __name__ == "__main__":
    main()
