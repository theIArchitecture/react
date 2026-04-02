#!/usr/bin/env python3
"""
Smoke test: generates a known payload and marks it as transformed so the
cache saver will persist it. Run before smoke-cache-read to seed the cache.
"""
import json
import sys
from datetime import datetime, timezone


def main():
    try:
        json.loads(sys.stdin.read())  # consume stdin; no inputs needed
        payload = {
            "smoke-test": True,
            "written-at": datetime.now(timezone.utc).isoformat(),
        }
        print(json.dumps({
            "success": True,
            "context": {
                "smoke-data": payload,
                "smoke-data.transformed": True,
            },
            "error": None,
            "warnings": [],
        }))
    except Exception as exc:
        print(json.dumps({"success": False, "context": {}, "error": str(exc), "warnings": []}))
        sys.exit(1)


if __name__ == "__main__":
    main()
