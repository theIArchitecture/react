# Concept Adapters

## Purpose

Concept Adapters enable **polyglot rule expansion** without hardcoding language-specific knowledge in IArchitecture tools. They define how programming **concepts** (not specific rules) map across different programming languages.

## Philosophy

```
┌─────────────────────────────────────────────────────────────────┐
│                    DATA-DRIVEN, NOT CODE-DRIVEN                 │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  BAD (hardcoded in tool):                                       │
│  if (language == "java") pattern = "MessageDigest.getInstance"; │
│                                                                 │
│  GOOD (in loadable adapter file):                               │
│  crypto-concepts.adapter.json:                                  │
│    MD5_HASH_CREATION → java → "MessageDigest.getInstance"       │
│                                                                 │
│  The engine/tools remain language-agnostic.                     │
│  All intelligence lives in data files customers can control.    │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

## How It Works

1. **Language Plugins** (`.iarch/languages/*.json`) - Define syntax, parsing rules
2. **Concept Adapters** (`.iarch/adapters/*.adapter.json`) - Define concept mappings
3. **IArchPolyglotTranslator** - Uses both to expand rules across languages

## File Structure

```
.iarch/adapters/
├── concept-adapter.schema.json     # JSON Schema for validation
├── crypto-concepts.adapter.json    # Security/cryptography concepts
├── datetime-concepts.adapter.json  # Date/time handling concepts
├── http-concepts.adapter.json      # HTTP client concepts (future)
├── logging-concepts.adapter.json   # Logging patterns (future)
└── CONTEXT.md                      # This file
```

## Adapter Format

```json
{
  "name": "Cryptography Concepts",
  "version": "1.0.0",
  "domain": "security",
  
  "concepts": {
    "MD5_HASH_CREATION": {
      "description": "Creating an MD5 hash instance",
      "risk": "high",
      "cwe": "CWE-328",
      "languageMappings": {
        "csharp": {
          "patterns": ["MD5\\.Create\\s*\\("],
          "imports": ["System.Security.Cryptography"],
          "replacement": { "pattern": "SHA256.Create()" }
        },
        "java": {
          "patterns": ["MessageDigest\\.getInstance\\s*\\(.*MD5.*\\)"],
          "imports": ["java.security.MessageDigest"],
          "replacement": { "pattern": "MessageDigest.getInstance(\"SHA-256\")" }
        }
        // ... more languages
      },
      "recommendedConcept": "SHA256_HASH_CREATION"
    }
  }
}
```

## Customer Workflow

### Adding Go Support

```bash
# 1. Download Go language plugin (or create your own)
# 2. Add Go mappings to relevant concept adapters
# 3. Run polyglot translator
IArchPolyglotTranslator --rule AWS-SEC-MD5-001.iarch --target go

# No vendor release needed! Full customer control.
```

### Custom Internal Patterns

```json
// my-company-crypto.adapter.json
{
  "concepts": {
    "INTERNAL_WEAK_HASH": {
      "languageMappings": {
        "csharp": {
          "patterns": ["MyCompany\\.Crypto\\.WeakHash\\("]
        }
      }
    }
  }
}
```

## Included Adapters

| Adapter | Domain | Concepts |
|---------|--------|----------|
| `crypto-concepts` | Security | MD5, SHA1, SHA256, weak random |
| `datetime-concepts` | Reliability | Local time, UTC time, timezones |

## Future Adapters (Planned)

- `http-concepts` - HttpClient disposal, connection pooling
- `logging-concepts` - Static loggers, log injection
- `sql-concepts` - SQL injection, parameterized queries
- `serialization-concepts` - Insecure deserialization

## Schema

All adapters must conform to `concept-adapter.schema.json`.

## Related

- Language plugins: `.iarch/languages/`
- Backlog design: `docs/backlog/POLYGLOT-RULE-EXPANSION.md`
- Engine philosophy: `claude.md`
