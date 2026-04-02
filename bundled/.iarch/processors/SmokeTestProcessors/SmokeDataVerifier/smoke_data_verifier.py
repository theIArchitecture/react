#!/usr/bin/env python3
"""
Smoke test: verifies that smoke-data was loaded from the cache.
Fails the pipeline if smoke-data is absent — meaning the cache load did not work.
"""
import json
import sys


def main():
    try:
        input_data = json.loads(sys.stdin.read())
        context = input_data.get("context") or {}

        smoke_data = context.get("smoke-data")
        if smoke_data is None:
            print(json.dumps({
                "success": False,
                "context": {},
                "error": "smoke-data not found in context — cache load failed or cache is empty (run smoke-cache-write first)",
                "warnings": [],
            }))
            sys.exit(1)

        preview = str(smoke_data)[:120]
        print(json.dumps({
            "success": True,
            "context": {},
            "error": None,
            "warnings": [f"smoke-data verified: {preview}"],
        }))
    except Exception as exc:
        print(json.dumps({"success": False, "context": {}, "error": str(exc), "warnings": []}))
        sys.exit(1)


if __name__ == "__main__":
    main()
