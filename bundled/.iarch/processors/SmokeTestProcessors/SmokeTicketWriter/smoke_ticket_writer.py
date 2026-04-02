#!/usr/bin/env python3
"""
Smoke test: emits one hardcoded ticket-request to verify Jira connectivity.
No upstream dependencies — drops straight into the jira-processor.
"""
import json
import sys


def main():
    try:
        json.loads(sys.stdin.read())  # consume stdin; no inputs needed
        print(json.dumps({
            "success": True,
            "context": {
                "ticket-requests": [{
                    "summary": "[IArch Smoke Test] Jira connectivity check — please delete",
                    "description": (
                        "This ticket was created by the IArchitecture smoke-jira workflow "
                        "to verify Jira connectivity.\n\nSafe to delete."
                    ),
                    "priority": "Low",
                    "labels": ["iarch-smoke-test"],
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
