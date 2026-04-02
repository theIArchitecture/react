#!/usr/bin/env python3
"""
CloudFormation Layer Access Validator

CF-LAYER-001: A class outside the designated Data or Repository layer opens a
              database connection directly. All database access must be routed
              through the data access layer.

This rule is infrastructure-aware: the allowed namespaces are those that the
IAM policy and network security groups are designed to permit direct DB access
from. Bypassing the repository layer also bypasses that security boundary.

With neighborhood traversal (depth > 0), this rule catches violations not just
in the Lambda entry point but in any transitively reachable code file. A clean
entry point that calls a service that calls a helper with new SqlConnection()
is caught at the helper level, attributed to the originating CF stack.

Input context keys: neighborhoods (from neighborhood-builder), violations (optional)
                    Falls back to filtered-files if neighborhoods is absent.
Output context keys: violations (appended)
"""

import sys
import json
import re
import os


# ---------------------------------------------------------------------------
# Detection helpers
# ---------------------------------------------------------------------------

# Namespaces that are permitted to open database connections directly.
# Config key: cloudformation-layer-validator.allowed-namespaces (comma-separated)
_DEFAULT_ALLOWED_SUFFIXES = (
    '.data',
    '.data.',
    '.repository',
    '.repository.',
    '.infrastructure.data',
    '.infrastructure.data.',
    '.dal',
    '.dal.',
)

# Patterns that indicate a direct database connection is being opened.
_DB_CONNECTION_PATTERN = re.compile(
    r'\bnew\s+(SqlConnection|NpgsqlConnection|MySqlConnection|OracleConnection|'
    r'SQLiteConnection|DbConnection)\s*\('
)

# Namespace declaration in C# source.
_NAMESPACE_PATTERN = re.compile(r'^\s*namespace\s+([\w.]+)', re.MULTILINE)

# Class name declaration in C# source.
_CLASS_PATTERN = re.compile(r'^\s*(?:public|internal|private|protected)?\s*'
                             r'(?:static\s+|sealed\s+|abstract\s+)*'
                             r'class\s+(\w+)', re.MULTILINE)


def _is_allowed_namespace(namespace, allowed_suffixes):
    """Return True if the namespace is in an allowed data-layer namespace."""
    ns_lower = namespace.lower()
    for suffix in allowed_suffixes:
        if ns_lower.endswith(suffix.rstrip('.')):
            return True
        if suffix.endswith('.') and ('.' + suffix.rstrip('.') + '.') in ('.' + ns_lower + '.'):
            return True
    return False


def _make_violation(rule_id, rule_name, description, file_path,
                    line_number, violated_pattern, fix_suggestion):
    return {
        'id': rule_id,
        'name': rule_name,
        'description': description,
        'severity': 'Fatal',
        'file_path': file_path,
        'line_number': line_number,
        'violated_pattern': violated_pattern,
        'fix_suggestion': fix_suggestion,
        'can_auto_heal': False,
        'available_fixes': []
    }


# ---------------------------------------------------------------------------
# Per-file layer check
# ---------------------------------------------------------------------------

def _check_file(file_path, allowed_suffixes):
    """Return violations for a single code file. Empty list = clean."""
    violations = []
    ext = os.path.splitext(file_path)[1].lower()
    if ext != '.cs':
        return violations

    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            content = f.read()
    except Exception:
        return violations

    db_matches = list(_DB_CONNECTION_PATTERN.finditer(content))
    if not db_matches:
        return violations

    ns_match = _NAMESPACE_PATTERN.search(content)
    namespace = ns_match.group(1) if ns_match else ''

    if _is_allowed_namespace(namespace, allowed_suffixes):
        return violations  # permitted layer

    class_match = _CLASS_PATTERN.search(content)
    class_name = class_match.group(1) if class_match else os.path.splitext(
        os.path.basename(file_path))[0]

    for match in db_matches:
        line_number = content[:match.start()].count('\n') + 1
        connection_type = match.group(1)
        violations.append(_make_violation(
            rule_id='CF-LAYER-001',
            rule_name='CF-DIRECT-DB-ACCESS-OUTSIDE-DATA-LAYER',
            description=(
                "'{}' in namespace '{}' opens a {} directly. "
                "Database access must be in the Data or Repository layer. "
                "Controllers, services, and other non-data-layer classes "
                "must delegate to a repository.".format(
                    class_name, namespace or '(no namespace)', connection_type)
            ),
            file_path=file_path,
            line_number=line_number,
            violated_pattern='CF-LAYER-001',
            fix_suggestion=(
                "Move database access to a class in a .Data or .Repository "
                "namespace. Inject the repository via constructor into '{}' "
                "and call its methods instead of opening a connection "
                "directly.".format(class_name)
            )
        ))

    return violations


# ---------------------------------------------------------------------------
# Neighborhood-aware validation
# ---------------------------------------------------------------------------

def validate_neighborhood(cf_path, code_paths, allowed_suffixes):
    """
    Check every code file in the neighborhood for direct DB access outside
    the data layer. Returns violations attributed to the originating code file.
    """
    violations = []
    for code_path in code_paths:
        violations.extend(_check_file(code_path, allowed_suffixes))
    return violations


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main():
    raw = json.load(sys.stdin)
    context = raw.get('context', {})
    config = raw.get('config', {})

    custom_ns = config.get('cloudformation-layer-validator.allowed-namespaces', '')
    if custom_ns:
        allowed_suffixes = tuple(
            ('.' + s.strip().lower()).rstrip('.')
            for s in custom_ns.split(',') if s.strip()
        )
    else:
        allowed_suffixes = _DEFAULT_ALLOWED_SUFFIXES

    neighborhoods = context.get('neighborhoods', [])
    violations = []

    if neighborhoods:
        for hood in neighborhoods:
            cf_path = hood.get('subject_path', '')
            neighbor_paths = [n['file_path'] for n in hood.get('neighbors', [])]
            violations.extend(validate_neighborhood(cf_path, neighbor_paths, allowed_suffixes))
    else:
        # Fallback: no neighborhoods, scan all filtered files directly
        file_paths = context.get('filtered-files', [])
        code_files = [f for f in file_paths
                      if os.path.splitext(f)[1].lower() == '.cs']
        for code_path in code_files:
            violations.extend(_check_file(code_path, allowed_suffixes))

    print(json.dumps({
        'success': True,
        'context': {
            'violations': violations
        }
    }))


if __name__ == '__main__':
    main()
