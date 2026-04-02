#!/usr/bin/env pwsh
<#
.SYNOPSIS
Jira ticketing processors for the IArchitecture pipeline.

Dot-sourced by the Modulus PowerShell executor; entry points called directly.
Contract: stdin JSON { context, config, metadata } -> stdout JSON { success, context, error, warnings }

Processors:
  Invoke-WriteTicketRequests   -  builds generic ticket-requests from violations (+ optional ci-environment)
  Invoke-JiraProcessor         -  creates Jira issues from ticket-requests via REST API

The ticket-requests format is system-agnostic. Any downstream ticketing processor
(Jira, ServiceNow, Linear, etc.) can consume the same upstream data.

Credentials are read from env vars (TICKET_*) with config key overrides (ticket-*).
#>

function Invoke-WriteGovernanceTicketRequests {
    <#
    .SYNOPSIS
    Converts governance-ledger-entries (proposed rules awaiting architect review)
    into the system-agnostic ticket-requests format consumed by Invoke-JiraProcessor.
    One ticket per proposed rule.
    #>
    $raw     = [Console]::In.ReadToEnd()
    $payload = $raw | ConvertFrom-Json
    $ctx     = $payload.context
    $cfg     = $payload.config

    $entries = if ($ctx.'governance-ledger-entries') { @($ctx.'governance-ledger-entries') } else { @() }

    if ($entries.Count -eq 0) {
        @{
            success  = $true
            context  = @{ 'ticket-requests' = @() }
            error    = $null
            warnings = @('write-governance-ticket-requests: no governance-ledger-entries in context - skipping')
        } | ConvertTo-Json -Depth 10
        return
    }

    $priority = if ($cfg.priority) { $cfg.priority } else { 'Medium' }
    $labels   = if ($cfg.labels) {
        @($cfg.labels -split ',' | ForEach-Object { $_.Trim() })
    } else {
        @('iarchitecture', 'governance', 'needs-architect-review')
    }

    # Strip control characters that PS5.1 ConvertTo-Json doesn't escape (LLM output can contain them)
    # Keeps \t (0x09) \n (0x0A) \r (0x0D); removes everything else in 0x00-0x1F and 0x7F
    function Remove-ControlChars([string]$s) {
        return [regex]::Replace($s, '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]', '')
    }

    $warnings = [System.Collections.Generic.List[string]]::new()
    $warnings.Add("write-governance-ticket-requests: stdin-len=$($raw.Length) entry-count=$($entries.Count)")

    $ticketRequests = @()
    foreach ($entry in $entries) {
        $warnings.Add("write-governance-ticket-requests: entry-props=$($entry.PSObject.Properties.Name -join ',')")

        # Diagnostic: check raw values BEFORE truthiness coercion (null vs empty string matters)
        $rawRuleLen    = if ($null -eq $entry.rule_content)        { 'null' } else { "$($entry.rule_content.Length)" }
        $rawAnomalyLen = if ($null -eq $entry.anomaly_description) { 'null' } else { "$($entry.anomaly_description.Length)" }
        $warnings.Add("write-governance-ticket-requests: raw-rule-len=$rawRuleLen raw-anomaly-len=$rawAnomalyLen")
        # Diagnostic: direct Remove-ControlChars call vs inline-if call
        $rcDirect = Remove-ControlChars $entry.rule_content
        $condResult = if ($entry.rule_content) { 'truthy' } else { 'falsy' }
        $warnings.Add("write-governance-ticket-requests: rc-direct-len=$($rcDirect.Length) cond=$condResult")

        $ruleId      = if ($entry.generated_rule_id) { $entry.generated_rule_id } else { 'AUTO-UNKNOWN' }
        $clusterRaw  = if ($entry.cluster_id) { $entry.cluster_id } else { '' }
        $clusterId   = $clusterRaw.Substring(0, [Math]::Min(8, $clusterRaw.Length))
        $anomalyDesc = Remove-ControlChars (if ($entry.anomaly_description) { $entry.anomaly_description } else { '' })
        $ruleContent = Remove-ControlChars (if ($entry.rule_content) { $entry.rule_content } else { '' })
        $confidence  = if ($null -ne $entry.entropy_at_proposal) { $entry.entropy_at_proposal } else { 0 }
        $warnings.Add("write-governance-ticket-requests: rule-id='$ruleId' anomaly-len=$($anomalyDesc.Length) rule-len=$($ruleContent.Length)")

        $summary = "IArchitecture Governance: Review proposed rule $ruleId (cluster $clusterId)"

        $descLines = @(
            "Proposed rule awaiting architect review.",
            "",
            "Rule ID: $ruleId",
            "Cluster ID: $clusterId",
            "Entropy at proposal: $([math]::Round($confidence, 3))",
            "",
            "=== ANOMALY DESCRIPTION ===",
            $anomalyDesc,
            "",
            "=== PROPOSED RULE ===",
            $ruleContent,
            "",
            "To approve: rename rule ID from AUTO- prefix to ARCH- and add to .iarch/rules/.",
            "To reject: add a rejection entry to .iarch/governance-ledger.jsonl with status 'rejected'."
        )

        $ticketRequests += @{
            summary     = $summary
            description = $descLines -join "`n"
            priority    = $priority
            labels      = $labels
            metadata    = @{
                ruleId      = $ruleId
                clusterId   = $clusterId
                ruleContent = $ruleContent
                ruleFileName = "$ruleId.iarch"
            }
        }
    }

    @{
        success  = $true
        context  = @{ 'ticket-requests' = $ticketRequests }
        error    = $null
        warnings = $warnings.ToArray()
    } | ConvertTo-Json -Depth 10
}

function Invoke-WriteTicketRequests {
    $payload   = [Console]::In.ReadToEnd() | ConvertFrom-Json
    $ctx       = $payload.context
    $cfg       = $payload.config
    $wfCtx     = $ctx.'ci-environment'

    $violations     = if ($ctx.violations) { @($ctx.violations) } else { @() }
    $violationCount = $violations.Count
    $errorCount     = @($violations | Where-Object { $_.severity -in @('Error', 'Fatal') }).Count
    $warningCount   = @($violations | Where-Object { $_.severity -eq 'Warning' }).Count

    # Config: all optional with sensible defaults
    $priority = if ($cfg.priority) { $cfg.priority } else { 'Medium' }
    $labels   = if ($cfg.labels)   { @($cfg.labels -split ',' | ForEach-Object { $_.Trim() }) } `
                else               { @('iarchitecture') }
    $summary  = if ($cfg.summary)  { $cfg.summary } else { Build-DefaultSummary $violationCount $errorCount $wfCtx }

    $description = Build-Description $violations $violationCount $errorCount $warningCount $wfCtx

    $ticketRequest = @{
        summary     = $summary
        description = $description
        priority    = $priority
        labels      = $labels
        metadata    = @{
            violationCount = $violationCount
            errorCount     = $errorCount
            warningCount   = $warningCount
            repository     = if ($wfCtx) { $wfCtx.repository } else { $null }
            sha            = if ($wfCtx) { $wfCtx.sha }        else { $null }
            prNumber       = if ($wfCtx) { $wfCtx.pr_number }   else { $null }
        }
    }

    @{
        success  = $true
        context  = @{ 'ticket-requests' = @($ticketRequest) }
        error    = $null
        warnings = @()
    } | ConvertTo-Json -Depth 10
}

function Invoke-JiraProcessor {
    $payload = [Console]::In.ReadToEnd() | ConvertFrom-Json
    $ctx     = $payload.context
    $cfg     = $payload.config

    $ticketRequests = if ($ctx.'ticket-requests') { @($ctx.'ticket-requests') } else { @() }

    $warnings = [System.Collections.Generic.List[string]]::new()
    $errors   = [System.Collections.Generic.List[string]]::new()

    if ($ticketRequests.Count -eq 0) {
        $warnings.Add('jira-processor: no ticket-requests in context  -  skipping')
        @{
            success  = $true
            context  = @{}
            error    = $null
            warnings = $warnings.ToArray()
        } | ConvertTo-Json -Depth 10
        return
    }

    # Config overrides take precedence over env vars
    $baseUrl    = if ($cfg.'ticket-base-url')    { $cfg.'ticket-base-url' }    else { $env:TICKET_BASE_URL }
    $userEmail  = if ($cfg.'ticket-user-email')  { $cfg.'ticket-user-email' }  else { $env:TICKET_USER_EMAIL }
    $apiToken   = if ($cfg.'ticket-api-token')   { $cfg.'ticket-api-token' }   else { $env:TICKET_API_TOKEN }
    $projectKey = if ($cfg.'ticket-project-key') { $cfg.'ticket-project-key' } else { $env:TICKET_PROJECT_KEY }
    $assigneeId = if ($cfg.'ticket-assignee-id') { $cfg.'ticket-assignee-id' } else { $env:TICKET_ASSIGNEE_ID }
    $issueType  = if ($cfg.'ticket-issue-type')  { $cfg.'ticket-issue-type' }  else { 'Task' }

    if ([string]::IsNullOrEmpty($baseUrl))    { $errors.Add('jira-processor: TICKET_BASE_URL not set') }
    if ([string]::IsNullOrEmpty($userEmail))  { $errors.Add('jira-processor: TICKET_USER_EMAIL not set') }
    if ([string]::IsNullOrEmpty($apiToken))   { $errors.Add('jira-processor: TICKET_API_TOKEN not set') }
    if ([string]::IsNullOrEmpty($projectKey)) { $errors.Add('jira-processor: TICKET_PROJECT_KEY not set') }

    if ($errors.Count -gt 0) {
        @{
            success  = $false
            context  = @{}
            error    = $errors -join '; '
            warnings = $warnings.ToArray()
        } | ConvertTo-Json -Depth 10
        return
    }

    $credentials = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${userEmail}:${apiToken}"))
    $headers = @{
        Authorization  = "Basic $credentials"
        'Content-Type' = 'application/json'
        Accept         = 'application/json'
    }

    foreach ($ticket in $ticketRequests) {
        $fields = @{
            project     = @{ key = $projectKey }
            summary     = $ticket.summary
            description = @{
                type    = 'doc'
                version = 1
                content = @(@{
                    type    = 'paragraph'
                    content = @(@{ type = 'text'; text = $ticket.description })
                })
            }
            issuetype   = @{ name = $issueType }
            labels      = @($ticket.labels)
            priority    = @{ name = $ticket.priority }
        }

        if (-not [string]::IsNullOrEmpty($assigneeId)) {
            $fields.assignee = @{ accountId = $assigneeId }
        }

        $body = @{ fields = $fields } | ConvertTo-Json -Depth 10

        try {
            $response = Invoke-RestMethod `
                -Uri "$baseUrl/rest/api/3/issue" `
                -Method POST `
                -Headers $headers `
                -Body $body `
                -ErrorAction Stop
            $warnings.Add("jira-processor: created issue $($response.key) - $($ticket.summary)")

            # Attach the .iarch rule file if this ticket carries rule content
            $ruleContent  = if ($ticket.metadata) { $ticket.metadata.ruleContent  } else { $null }
            $ruleFileName = if ($ticket.metadata) { $ticket.metadata.ruleFileName } else { $null }

            if (-not [string]::IsNullOrEmpty($ruleContent) -and -not [string]::IsNullOrEmpty($ruleFileName)) {
                $tempFile = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), $ruleFileName)
                try {
                    [System.IO.File]::WriteAllText($tempFile, $ruleContent, [System.Text.Encoding]::UTF8)
                    $attachHeaders = @{
                        Authorization        = "Basic $credentials"
                        'X-Atlassian-Token'  = 'no-check'   # required by Jira attachment endpoint
                        Accept               = 'application/json'
                    }
                    Invoke-RestMethod `
                        -Uri "$baseUrl/rest/api/3/issue/$($response.key)/attachments" `
                        -Method POST `
                        -Headers $attachHeaders `
                        -Form @{ file = Get-Item $tempFile } `
                        -ErrorAction Stop | Out-Null
                    $warnings.Add("jira-processor: attached $ruleFileName to $($response.key)")
                } catch {
                    $warnings.Add("jira-processor: issue $($response.key) created but attachment failed  -  $($_.Exception.Message)")
                } finally {
                    if (Test-Path $tempFile) { Remove-Item $tempFile -Force }
                }
            }
        } catch {
            $errors.Add("jira-processor: failed to create issue '$($ticket.summary)'  -  $($_.Exception.Message)")
        }
    }

    @{
        success  = ($errors.Count -eq 0)
        context  = @{}
        error    = if ($errors.Count -gt 0) { $errors -join '; ' } else { $null }
        warnings = $warnings.ToArray()
    } | ConvertTo-Json -Depth 10
}

function Build-DefaultSummary {
    param([int]$Total, [int]$Errors, $WfCtx)

    if ($WfCtx -and $WfCtx.repository) {
        $repo = $WfCtx.repository -replace '^.*/', ''
        if ($WfCtx.pr_number) {
            return "IArchitecture: $Total violation(s) in $repo PR #$($WfCtx.pr_number) ($Errors error(s))"
        }
        if ($WfCtx.sha) {
            $shortSha = $WfCtx.sha.Substring(0, [Math]::Min(7, $WfCtx.sha.Length))
            return "IArchitecture: $Total violation(s) in $repo @ $shortSha ($Errors error(s))"
        }
        return "IArchitecture: $Total violation(s) in $repo ($Errors error(s))"
    }

    return "IArchitecture: $Total architectural violation(s) detected ($Errors error(s))"
}

function Build-Description {
    param([array]$Violations, [int]$Total, [int]$Errors, [int]$Warnings, $WfCtx)

    $lines = @()

    if ($WfCtx) {
        if ($WfCtx.repository) { $lines += "Repository: $($WfCtx.repository)" }
        if ($WfCtx.pr_number)   { $lines += "PR: #$($WfCtx.pr_number)" }
        if ($WfCtx.sha)        { $lines += "Commit: $($WfCtx.sha.Substring(0, [Math]::Min(7, $WfCtx.sha.Length)))" }
        if ($lines.Count -gt 0) { $lines += '' }
    }

    $lines += "Violations: $Total total ($Errors error(s), $Warnings warning(s))"
    $lines += ''

    $Violations | Select-Object -First 20 | ForEach-Object {
        $file = if ($_.file_path) { [System.IO.Path]::GetFileName($_.file_path) } else { 'unknown' }
        $line = if ($_.line_number) { ":$($_.line_number)" } else { '' }
        $lines += "[$($_.severity)] $($_.name)  -  $file$line"
    }

    if ($Total -gt 20) {
        $lines += "...and $($Total - 20) more violations"
    }

    $lines -join "`n"
}
