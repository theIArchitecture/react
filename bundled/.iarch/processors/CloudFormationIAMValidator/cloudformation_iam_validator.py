#!/usr/bin/env python3
"""
CloudFormation IAM Policy Validator

CF-IAM-001: A Lambda function's execution role is missing rds:Connect but the
            application code opens database connections. The connection will be
            refused by IAM at runtime.

CF-IAM-002: An IAM policy statement grants permissions on Resource: '*' for a
            service whose specific resource is defined in the same stack. The
            role violates least-privilege; the ARN should be scoped.

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

# SQL client patterns that indicate direct database connection usage (any depth)
_DB_CONNECTION_PATTERN = re.compile(
    r'\b(SqlConnection|NpgsqlConnection|MySqlConnection|OracleConnection|'
    r'SQLiteConnection|DbConnection)\s*\('
)

# Service action prefixes that have specific resources in common stacks
_SCOPEABLE_ACTION_PREFIXES = {
    'sqs': 'AWS::SQS::Queue',
    's3': 'AWS::S3::Bucket',
    'dynamodb': 'AWS::DynamoDB::Table',
    'sns': 'AWS::SNS::Topic',
    'kinesis': 'AWS::Kinesis::Stream',
    'secretsmanager': 'AWS::SecretsManager::Secret',
}


def _is_cloudformation(content):
    return 'AWSTemplateFormatVersion' in content or (
        'Resources' in content and 'AWS::' in content
    )


def _get_logical_id_of_role(role_ref):
    """Extract logical resource ID from a role reference (handles !GetAtt and !Ref)."""
    if isinstance(role_ref, CFTag):
        if role_ref.tag == 'GetAtt':
            val = role_ref.value
            if isinstance(val, str) and '.' in val:
                return val.split('.')[0]
            if isinstance(val, list) and len(val) >= 1:
                return str(val[0])
        elif role_ref.tag == 'Ref':
            return str(role_ref.value)
    if isinstance(role_ref, str):
        return role_ref
    return None


def _normalise_actions(action_val):
    """Return list of action strings from a scalar or list."""
    if isinstance(action_val, str):
        return [action_val]
    if isinstance(action_val, list):
        return [str(a) for a in action_val]
    return []


def _is_wildcard_resource(resource_val):
    """Return True if the IAM statement resource is a plain wildcard."""
    if isinstance(resource_val, str):
        return resource_val.strip() == '*'
    if isinstance(resource_val, list):
        return any(isinstance(r, str) and r.strip() == '*' for r in resource_val)
    return False


def _resource_types_in_stack(resources):
    """Return set of CloudFormation resource types present in the stack."""
    return {res.get('Type', '') for res in resources.values()
            if isinstance(res, dict)}


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
    Validate IAM rules for one CF file against its resolved code neighborhood.
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

    resources = template.get('Resources', {}) if isinstance(template, dict) else {}
    resource_types = _resource_types_in_stack(resources)

    # Build map of role logical ID -> role resource
    roles = {name: res for name, res in resources.items()
             if isinstance(res, dict) and res.get('Type') == 'AWS::IAM::Role'}

    # Build set of IAM actions granted by each role
    role_actions = {}       # role_name -> set of action strings
    role_statements = {}    # role_name -> list of (sid, actions, resource_val)

    for role_name, role in roles.items():
        props = role.get('Properties', {}) or {}
        all_actions = set()
        statements_info = []

        for policy in (props.get('Policies') or []):
            doc = policy.get('PolicyDocument', {}) or {}
            for stmt in (doc.get('Statement') or []):
                if not isinstance(stmt, dict):
                    continue
                if stmt.get('Effect', 'Allow') != 'Allow':
                    continue
                actions = _normalise_actions(stmt.get('Action', []))
                resource_val = stmt.get('Resource', '')
                sid = stmt.get('Sid', '(no Sid)')
                all_actions.update(actions)
                statements_info.append((sid, actions, resource_val))

        role_actions[role_name] = all_actions
        role_statements[role_name] = statements_info

    # Determine whether any reachable code (including transitive) opens DB connections
    code_opens_db = False
    db_file = None
    for code_path in code_paths:
        ext = os.path.splitext(code_path)[1].lower()
        if ext not in ('.cs', '.java', '.py', '.ts', '.js'):
            continue
        try:
            with open(code_path, 'r', encoding='utf-8') as f:
                code_content = f.read()
            if _DB_CONNECTION_PATTERN.search(code_content):
                code_opens_db = True
                db_file = code_path
                break
        except Exception:
            continue

    # CF-IAM-001: Lambda connects to RDS but role missing rds:Connect
    if code_opens_db:
        has_rds = any('AWS::RDS::' in t for t in resource_types)
        for func_name, resource in resources.items():
            if not isinstance(resource, dict):
                continue
            if resource.get('Type') not in ('AWS::Lambda::Function', 'AWS::Serverless::Function'):
                continue
            props = resource.get('Properties', {}) or {}
            role_ref = props.get('Role')
            role_logical_id = _get_logical_id_of_role(role_ref)

            if role_logical_id not in role_actions:
                continue

            actions = role_actions[role_logical_id]
            has_rds_connect = any(
                a.lower() in ('rds:connect', 'rds:*', '*') for a in actions
            )

            if has_rds and not has_rds_connect:
                db_detail = ' (found in {})'.format(os.path.basename(db_file)) if db_file else ''
                violations.append(_make_violation(
                    rule_id='CF-IAM-001',
                    rule_name='CF-IAM-RDS-CONNECT-MISSING',
                    description=(
                        "IAM role '{}' attached to Lambda function '{}' is missing "
                        "rds:Connect but the reachable code opens database "
                        "connections{}. The Lambda will be refused by IAM when it "
                        "attempts to authenticate to RDS.".format(
                            role_logical_id, func_name, db_detail)
                    ),
                    file_path=cf_path,
                    line_number=None,
                    violated_pattern='CF-IAM-001',
                    fix_suggestion=(
                        "Add a policy statement granting rds:Connect on the "
                        "specific DBInstance ARN to role '{}'.".format(role_logical_id)
                    )
                ))

    # CF-IAM-002: IAM wildcard resource where specific ARN is available
    for role_name, statements_info in role_statements.items():
        for sid, actions, resource_val in statements_info:
            if not _is_wildcard_resource(resource_val):
                continue
            # Collect distinct scoped resource types affected by this statement
            scoped_types = {}  # resource_type -> first matching action
            for action in actions:
                service_prefix = action.split(':')[0].lower() if ':' in action else ''
                scoped_type = _SCOPEABLE_ACTION_PREFIXES.get(service_prefix)
                if scoped_type and scoped_type in resource_types:
                    scoped_types.setdefault(scoped_type, action)
            # One violation per statement (not per action)
            for scoped_type, example_action in scoped_types.items():
                violations.append(_make_violation(
                    rule_id='CF-IAM-002',
                    rule_name='CF-IAM-WILDCARD-RESOURCE',
                    description=(
                        "IAM policy statement '{}' in role '{}' grants actions "
                        "including '{}' on Resource: '*'. A {} resource is defined "
                        "in this stack and its ARN should be used instead.".format(
                            sid, role_name, example_action, scoped_type)
                    ),
                    file_path=cf_path,
                    line_number=None,
                    violated_pattern='CF-IAM-002',
                    fix_suggestion=(
                        "Replace Resource: '*' with the specific {} ARN "
                        "using !GetAtt or !Ref on the resource defined in "
                        "this stack.".format(scoped_type)
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
