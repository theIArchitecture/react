#!/usr/bin/env python3
"""
CloudFormation Environment Variable Validator

CF-ENV-001: Lambda function defines an environment variable in CloudFormation
            that no application code reads. Flags as a potential rename mismatch
            when a similarly-purposed variable IS read by the code.

CF-ENV-002: Application code reads an environment variable that is not defined
            in any Lambda function in the CloudFormation stack. The value will
            be null or missing at runtime.

Input context keys: neighborhoods (from neighborhood-builder), violations (optional)
                    Falls back to filtered-files if neighborhoods is absent.
Output context keys: violations (appended)
"""

import sys
import json
import re
import os
import yaml


# ---------------------------------------------------------------------------
# CloudFormation YAML tag support
# ---------------------------------------------------------------------------

class CFTag:
    def __init__(self, tag, value):
        self.tag = tag
        self.value = value


def _cf_constructor(loader, tag_suffix, node):
    if isinstance(node, yaml.ScalarNode):
        return CFTag(tag_suffix, loader.construct_scalar(node))
    elif isinstance(node, yaml.SequenceNode):
        return CFTag(tag_suffix, loader.construct_sequence(node, deep=True))
    elif isinstance(node, yaml.MappingNode):
        return CFTag(tag_suffix, loader.construct_mapping(node, deep=True))
    return CFTag(tag_suffix, None)


yaml.SafeLoader.add_multi_constructor('!', _cf_constructor)


# ---------------------------------------------------------------------------
# Detection helpers
# ---------------------------------------------------------------------------

_ENV_VAR_PATTERN = re.compile(
    r'GetEnvironmentVariable\s*\(\s*["\']([A-Za-z0-9_]+)["\']\s*\)'
)

_PYTHON_ENV_PATTERN = re.compile(
    r'os\.environ(?:\.get)?\s*\(\s*["\']([A-Za-z0-9_]+)["\']\s*\)'
)


def _is_cloudformation(content):
    return 'AWSTemplateFormatVersion' in content or (
        'Resources' in content and 'AWS::' in content
    )


def _extract_cf_lambda_env_vars(template):
    """Return dict mapping FunctionLogicalId -> set of env var names defined."""
    result = {}
    resources = template.get('Resources', {}) if isinstance(template, dict) else {}
    for name, resource in resources.items():
        if not isinstance(resource, dict):
            continue
        rtype = resource.get('Type', '')
        if rtype not in ('AWS::Lambda::Function', 'AWS::Serverless::Function'):
            continue
        props = resource.get('Properties', {}) or {}
        env_section = props.get('Environment', {}) or {}
        variables = env_section.get('Variables', {}) or {}
        result[name] = set(variables.keys()) if isinstance(variables, dict) else set()
    return result


def _extract_code_env_vars(file_path, content):
    """Return list of (var_name, line_number) read from application code."""
    found = []
    for pattern in (_ENV_VAR_PATTERN, _PYTHON_ENV_PATTERN):
        for match in pattern.finditer(content):
            var_name = match.group(1)
            line_number = content[:match.start()].count('\n') + 1
            found.append((var_name, line_number))
    return found


def _make_violation(rule_id, rule_name, description, file_path,
                    line_number, violated_pattern, fix_suggestion, severity='Fatal'):
    return {
        'id': rule_id,
        'name': rule_name,
        'description': description,
        'severity': severity,
        'file_path': file_path,
        'line_number': line_number,
        'violated_pattern': violated_pattern,
        'fix_suggestion': fix_suggestion,
        'can_auto_heal': False,
        'available_fixes': []
    }


# ---------------------------------------------------------------------------
# Neighborhood-aware validation
# ---------------------------------------------------------------------------

def validate_neighborhood(cf_path, code_paths):
    """
    Validate one CF file against its resolved code neighborhood.
    code_paths: all neighbor file paths (depth 0 = direct, depth 1+ = transitive).
    Returns list of violations.
    """
    violations = []

    # Parse the CloudFormation template
    try:
        with open(cf_path, 'r', encoding='utf-8') as f:
            content = f.read()
        if not _is_cloudformation(content):
            return violations
        template = yaml.safe_load(content)
    except Exception:
        return violations

    lambda_vars = _extract_cf_lambda_env_vars(template)
    if not lambda_vars:
        return violations

    all_cf_env_vars = set()
    for var_set in lambda_vars.values():
        all_cf_env_vars.update(var_set)

    # Collect env var reads from every file in the neighborhood
    code_env_reads = {}  # var_name -> list of (file_path, line_number)
    for code_path in code_paths:
        ext = os.path.splitext(code_path)[1].lower()
        if ext not in ('.cs', '.java', '.py', '.ts', '.js'):
            continue
        try:
            with open(code_path, 'r', encoding='utf-8') as f:
                code_content = f.read()
            for var_name, line_no in _extract_code_env_vars(code_path, code_content):
                code_env_reads.setdefault(var_name, []).append((code_path, line_no))
        except Exception:
            continue

    # CF-ENV-002: code reads X but X is not defined in any CF Lambda env block
    for var_name, occurrences in code_env_reads.items():
        if var_name not in all_cf_env_vars:
            for file_path, line_no in occurrences:
                violations.append(_make_violation(
                    rule_id='CF-ENV-002',
                    rule_name='CF-ENV-VAR-UNDEFINED',
                    description=(
                        "Application code reads environment variable '{}' in '{}' "
                        "but it is not defined in any Lambda function in '{}'. "
                        "The value will be null or missing at runtime.".format(
                            var_name, os.path.basename(file_path),
                            os.path.basename(cf_path))
                    ),
                    file_path=file_path,
                    line_number=line_no,
                    violated_pattern='CF-ENV-002',
                    fix_suggestion=(
                        "Add '{}' to the Lambda function's Environment.Variables "
                        "block in '{}'.".format(var_name, os.path.basename(cf_path))
                    )
                ))

    # CF-ENV-001: CF defines X but no code in this neighborhood reads X
    for func_name, var_set in lambda_vars.items():
        for var_name in var_set:
            if var_name not in code_env_reads:
                violations.append(_make_violation(
                    rule_id='CF-ENV-001',
                    rule_name='CF-ENV-VAR-NAME-MISMATCH',
                    description=(
                        "Lambda function '{}' defines environment variable '{}' in '{}' "
                        "but no code in its reachable neighborhood reads this variable. "
                        "This may indicate a rename mismatch.".format(
                            func_name, var_name, os.path.basename(cf_path))
                    ),
                    file_path=cf_path,
                    line_number=None,
                    violated_pattern='CF-ENV-001',
                    fix_suggestion=(
                        "Verify that '{}' matches the exact name used in "
                        "GetEnvironmentVariable() or os.environ calls in the "
                        "Lambda code. Rename it in CloudFormation if it differs.".format(var_name)
                    ),
                    severity='Error'
                ))

    return violations


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main():
    raw = json.load(sys.stdin)
    context = raw.get('context', {})

    neighborhoods = context.get('neighborhoods', [])
    violations = []

    if neighborhoods:
        for hood in neighborhoods:
            cf_path = hood.get('subject_path', '')
            neighbor_paths = [n['file_path'] for n in hood.get('neighbors', [])]
            violations.extend(validate_neighborhood(cf_path, neighbor_paths))
    else:
        # Fallback: no neighborhoods, scan all filtered files together
        file_paths = context.get('filtered-files', [])
        cf_files = [f for f in file_paths
                    if os.path.splitext(f)[1].lower() in ('.yaml', '.yml', '.template')]
        code_files = [f for f in file_paths
                      if os.path.splitext(f)[1].lower() in ('.cs', '.java', '.py', '.ts', '.js')]
        for cf_path in cf_files:
            violations.extend(validate_neighborhood(cf_path, code_files))

    print(json.dumps({
        'success': True,
        'context': {
            'violations': violations
        }
    }))


if __name__ == '__main__':
    main()
