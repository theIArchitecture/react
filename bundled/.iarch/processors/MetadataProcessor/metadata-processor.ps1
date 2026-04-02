#!/usr/bin/env pwsh
<#
.SYNOPSIS
Metadata processor for the IArchitecture pipeline.

Dot-sourced by the Modulus PowerShell executor; entry points called directly.
Contract: stdin JSON { context, config, metadata } -> stdout JSON { success, context, error, warnings }

Processors:
  Invoke-UpdateMetadata  -  delta-updates .iarch/metadata.json from violations + input-files context.
                            In full-replace mode (config: full-replace=true), replaces all entries
                            for analyzed files. In delta mode (default), only updates changed files.
                            Provides metadata-updated=true for downstream ordering (e.g. github-bot-commit).
#>

function Invoke-UpdateMetadata {
    $payload      = [Console]::In.ReadToEnd() | ConvertFrom-Json -Depth 20
    $ctx          = $payload.context
    $cfg          = $payload.config

    $metadataPath = $cfg.'metadata-path'
    $fullReplace  = ($cfg.'full-replace' -eq 'true') -or ($cfg.'full-replace' -eq $true)

    $violations   = if ($ctx.violations)   { @($ctx.violations) }   else { @() }
    # input-files is the raw list of file paths fed into the engine (from --file-list-path)
    $inputFiles   = if ($ctx.'input-files') { @($ctx.'input-files') } else { @() }

    $warnings = [System.Collections.Generic.List[string]]::new()
    $errors   = [System.Collections.Generic.List[string]]::new()

    if ([string]::IsNullOrEmpty($metadataPath)) {
        $errors.Add('metadata-updater: metadata-path config key not set')
        @{ success = $false; context = @{}; error = $errors -join '; '; warnings = $warnings.ToArray() } | ConvertTo-Json -Depth 10
        return
    }

    # ── Load or create metadata ────────────────────────────────────────────────
    if (Test-Path $metadataPath) {
        $jsonMetadata = Get-Content $metadataPath -Raw | ConvertFrom-Json -Depth 20
        $metadata = @{
            generated_at = $jsonMetadata.generated_at
            summary      = @{
                total_files          = if ($jsonMetadata.summary.total_files)          { $jsonMetadata.summary.total_files }          else { 0 }
                fatal_files          = if ($jsonMetadata.summary.fatal_files)          { $jsonMetadata.summary.fatal_files }          else { 0 }
                warning_files        = if ($jsonMetadata.summary.warning_files)        { $jsonMetadata.summary.warning_files }        else { 0 }
                clean_files          = if ($jsonMetadata.summary.clean_files)          { $jsonMetadata.summary.clean_files }          else { 0 }
                total_violations     = if ($jsonMetadata.summary.total_violations)     { $jsonMetadata.summary.total_violations }     else { 0 }
                violations_by_rule   = @{}
            }
            files = if ($jsonMetadata.files) { @($jsonMetadata.files) } else { @() }
        }
        if ($jsonMetadata.summary.violations_by_rule) {
            foreach ($prop in $jsonMetadata.summary.violations_by_rule.PSObject.Properties) {
                $metadata.summary.violations_by_rule[$prop.Name] = $prop.Value
            }
        }
    } else {
        $warnings.Add("metadata-updater: $metadataPath not found — creating new metadata")
        $metadata = @{
            generated_at = $null
            summary      = @{
                total_files        = 0
                fatal_files        = 0
                warning_files      = 0
                clean_files        = 0
                total_violations   = 0
                violations_by_rule = @{}
            }
            files = @()
        }
    }

    # ── Group violations by normalized file path ───────────────────────────────
    $violationsByFile = @{}
    foreach ($v in $violations) {
        $filePath = ($v.file_path -replace '\\', '/') -replace '^[^/]+/', ''
        if (-not $violationsByFile.ContainsKey($filePath)) { $violationsByFile[$filePath] = @() }
        $violationsByFile[$filePath] += @{
            rule_id     = $v.name
            severity    = $v.severity
            line_number = $v.line_number
        }
    }

    # ── Build hash of existing metadata files for fast lookup ─────────────────
    $metadataFilesHash = @{}
    foreach ($f in $metadata.files) {
        $metadataFilesHash[$f.file_path] = $f
    }

    # ── Determine which files to process ──────────────────────────────────────
    $filesToProcess = if ($inputFiles.Count -gt 0) {
        $inputFiles | ForEach-Object { ($_ -replace '\\', '/') -replace '^[^/]+/', '' }
    } else {
        # Fall back to union of files in violations + files already in metadata
        @($violationsByFile.Keys) + @($metadataFilesHash.Keys) | Sort-Object -Unique
    }

    # ── Delta-update metadata ──────────────────────────────────────────────────
    $deltaFatalFiles   = 0
    $deltaWarningFiles = 0
    $deltaCleanFiles   = 0
    $deltaViolations   = 0
    $deltaByRule       = @{}

    foreach ($normalizedPath in $filesToProcess) {
        $oldEntry = $metadataFilesHash[$normalizedPath]

        # Remove old contributions from summary
        if ($oldEntry -and $oldEntry.violations) {
            $oldHasFatal   = $false
            $oldHasWarning = $false
            foreach ($ov in $oldEntry.violations) {
                $deltaViolations--
                $ruleId = $ov.rule_id
                if (-not $deltaByRule.ContainsKey($ruleId)) { $deltaByRule[$ruleId] = 0 }
                $deltaByRule[$ruleId]--
                if ($ov.severity -in @('Fatal', 'Error')) { $oldHasFatal   = $true }
                if ($ov.severity -eq 'Warning')           { $oldHasWarning = $true }
            }
            if ($oldHasFatal)        { $deltaFatalFiles-- }
            elseif ($oldHasWarning)  { $deltaWarningFiles-- }
            else                     { $deltaCleanFiles-- }
        } elseif (-not $oldEntry) {
            # File is new to the engine — was previously clean (not in metadata)
            $deltaCleanFiles--
        }

        # Add new contributions
        if ($violationsByFile.ContainsKey($normalizedPath)) {
            $newViolations = $violationsByFile[$normalizedPath]
            $newHasFatal   = $false
            $newHasWarning = $false
            foreach ($nv in $newViolations) {
                $deltaViolations++
                $ruleId = $nv.rule_id
                if (-not $deltaByRule.ContainsKey($ruleId)) { $deltaByRule[$ruleId] = 0 }
                $deltaByRule[$ruleId]++
                if ($nv.severity -in @('Fatal', 'Error')) { $newHasFatal   = $true }
                if ($nv.severity -eq 'Warning')           { $newHasWarning = $true }
            }
            if ($newHasFatal)        { $deltaFatalFiles++ }
            elseif ($newHasWarning)  { $deltaWarningFiles++ }
            else                     { $deltaCleanFiles++ }

            $metadataFilesHash[$normalizedPath] = @{
                file_path  = $normalizedPath
                violations = $newViolations
            }
        } else {
            # File is clean — remove from metadata (clean files are not stored)
            if ($metadataFilesHash.ContainsKey($normalizedPath)) {
                $metadataFilesHash.Remove($normalizedPath)
            }
            $deltaCleanFiles++
        }
    }

    # ── Apply deltas to summary ────────────────────────────────────────────────
    $metadata.summary.fatal_files     = [Math]::Max(0, $metadata.summary.fatal_files   + $deltaFatalFiles)
    $metadata.summary.warning_files   = [Math]::Max(0, $metadata.summary.warning_files + $deltaWarningFiles)
    $metadata.summary.total_violations = [Math]::Max(0, $metadata.summary.total_violations + $deltaViolations)

    foreach ($ruleId in $deltaByRule.Keys) {
        $current  = if ($metadata.summary.violations_by_rule.ContainsKey($ruleId)) { $metadata.summary.violations_by_rule[$ruleId] } else { 0 }
        $newCount = $current + $deltaByRule[$ruleId]
        if ($newCount -gt 0) {
            $metadata.summary.violations_by_rule[$ruleId] = $newCount
        } else {
            $metadata.summary.violations_by_rule.Remove($ruleId)
        }
    }

    # Rebuild files array and recalculate total_files + clean_files from facts
    $metadata.files                = @($metadataFilesHash.Values)
    $metadata.summary.total_files  = $metadata.summary.fatal_files + $metadata.summary.warning_files + $metadata.summary.clean_files
    $metadata.summary.clean_files  = [Math]::Max(0, $metadata.summary.clean_files + $deltaCleanFiles)
    $metadata.generated_at         = Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ'

    # ── Write to disk ──────────────────────────────────────────────────────────
    $dir = [System.IO.Path]::GetDirectoryName($metadataPath)
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $metadata | ConvertTo-Json -Depth 10 | Set-Content -Path $metadataPath -Encoding UTF8

    @{
        success  = $true
        context  = @{ 'metadata-updated' = $true }
        error    = $null
        warnings = $warnings.ToArray()
    } | ConvertTo-Json -Depth 10
}
