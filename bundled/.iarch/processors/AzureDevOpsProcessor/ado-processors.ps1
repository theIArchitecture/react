#!/usr/bin/env pwsh
<#
.SYNOPSIS
Azure DevOps processors for the IArchitecture pipeline.

Dot-sourced by the Modulus PowerShell executor; entry points called directly.
Contract: stdin JSON { context, config, metadata } -> stdout JSON { success, context, error, warnings }

Processors:
  Invoke-AdoContextProvider              -  reads ADO pipeline vars (+ config overrides), provides ci-environment
  Invoke-AdoPostPrComment                -  posts violation summary as PR thread via ADO REST API
  Invoke-AdoCreateStatus                 -  creates a PR status (pass/fail) via ADO REST API
  Invoke-AdoCommitMarkers                -  commits annotation-flushed files and pushes via git (ADO auth)
  Invoke-AdoBotCommit                    -  git config/add/commit/push for IArchHub files (ADO auth)
  Invoke-AdoCreatePR                     -  creates an ADO pull request via REST API
  Invoke-AdoTriggerPipeline              -  triggers an ADO pipeline run via REST API
  Invoke-AdoGovernanceRemediationCommit  -  creates remediation branch, commits ca-*-processor + healed files (ADO auth)
  Invoke-AdoWorkflowDispatcher           -  routes approved/promoted proposals to ADO pipeline triggers
  Invoke-AdoCreateWorkItem               -  creates an ADO work item from violation summary
  Invoke-AdoCreateCommitComment          -  posts a commit thread comment via ADO REST API

ADO REST API base: {org}/{project}/_apis/
ADO API version:   7.1

Auth: SYSTEM_ACCESSTOKEN (pipeline) or ADO_TOKEN (local/config override).
Git push auth: uses 'Authorization: Bearer <token>' HTTP extra header.
#>

# ── Shared helpers ─────────────────────────────────────────────────────────────

function Invoke-AdoApi {
    <#
    .SYNOPSIS
    Minimal ADO REST API wrapper. Returns parsed JSON response or throws on failure.
    #>
    param(
        [string]$Token,
        [string]$Method,
        [string]$Uri,
        [object]$Body = $null
    )
    $headers = @{
        'Authorization' = "Bearer $Token"
        'Accept'        = 'application/json'
    }
    $params = @{
        Method  = $Method
        Uri     = $Uri
        Headers = $headers
    }
    if ($Body -ne $null) {
        $params['Body']        = ($Body | ConvertTo-Json -Depth 20 -Compress)
        $params['ContentType'] = 'application/json'
    }
    $resp = Invoke-RestMethod @params -ErrorAction Stop
    return $resp
}

function Invoke-AdoApiPatch {
    <#
    .SYNOPSIS
    ADO JSON Patch wrapper used for Work Items (content-type: application/json-patch+json).
    #>
    param(
        [string]$Token,
        [string]$Uri,
        [array]$PatchDoc
    )
    $headers = @{
        'Authorization' = "Bearer $Token"
        'Accept'        = 'application/json'
        'Content-Type'  = 'application/json-patch+json'
    }
    $body = $PatchDoc | ConvertTo-Json -Depth 10 -Compress
    $resp = Invoke-RestMethod -Method Patch -Uri $Uri -Headers $headers -Body $body -ErrorAction Stop
    return $resp
}

function Set-AdoGitAuth {
    <#
    .SYNOPSIS
    Configures git to authenticate pushes using a Bearer token via HTTP extraHeader.
    Call before any git push in ADO-hosted pipelines.
    #>
    param([string]$Token, [string]$RepoUrl)
    if ([string]::IsNullOrEmpty($Token)) { return }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(":$Token"))
    git config --local http.extraHeader "Authorization: Basic $encoded" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Set-AdoGitAuth: failed to set http.extraHeader (exit $LASTEXITCODE) - push may fail"
    }
}

function Format-AdoViolationComment {
    param([array]$Violations, [int]$Total, [int]$Errors, [int]$Warnings)
    if ($Total -eq 0) {
        return "## IArchitecture Analysis`n`nNo architectural violations detected."
    }
    $lines = @(
        '## IArchitecture Analysis',
        '',
        "**$Total violation(s) detected** - $Errors error(s), $Warnings warning(s)",
        '',
        '| Severity | Rule | File | Line |',
        '|---|---|---|---|'
    )
    $Violations | Select-Object -First 20 | ForEach-Object {
        $file = if ($_.file_path) { [System.IO.Path]::GetFileName($_.file_path) } else { '' }
        $line = if ($_.line_number) { $_.line_number } else { '' }
        $lines += "| $($_.severity) | $($_.name) | $file | $line |"
    }
    if ($Total -gt 20) {
        $lines += ''
        $lines += "_...and $($Total - 20) more_"
    }
    $lines -join "`n"
}

# ── Environment Provider ───────────────────────────────────────────────────────

function Invoke-AdoContextProvider {
    $payload = [Console]::In.ReadToEnd() | ConvertFrom-Json
    $cfg     = $payload.config

    # Priority: config override > ADO_* generic vars > SYSTEM_*/BUILD_* platform vars
    $token      = if ($cfg.'ado-token')        { $cfg.'ado-token' }        elseif ($env:ADO_TOKEN)                  { $env:ADO_TOKEN }                  else { $env:SYSTEM_ACCESSTOKEN }
    $orgUrl     = if ($cfg.'ado-org-url')      { $cfg.'ado-org-url' }      elseif ($env:ADO_ORG_URL)               { $env:ADO_ORG_URL }                else { $env:SYSTEM_TEAMFOUNDATIONSERVERURI }
    $project    = if ($cfg.'ado-project')      { $cfg.'ado-project' }      elseif ($env:ADO_PROJECT)               { $env:ADO_PROJECT }                else { $env:SYSTEM_TEAMPROJECT }
    $repository = if ($cfg.'ado-repository')   { $cfg.'ado-repository' }   elseif ($env:ADO_REPOSITORY)            { $env:ADO_REPOSITORY }             else { $env:BUILD_REPOSITORY_NAME }
    $repositoryId = if ($cfg.'ado-repository-id') { $cfg.'ado-repository-id' } elseif ($env:ADO_REPOSITORY_ID)    { $env:ADO_REPOSITORY_ID }          else { $env:BUILD_REPOSITORY_ID }
    $prNumber   = if ($cfg.'ado-pr-number')    { $cfg.'ado-pr-number' }    elseif ($env:ADO_PR_NUMBER)             { $env:ADO_PR_NUMBER }              else { $env:SYSTEM_PULLREQUEST_PULLREQUESTID }
    $sha        = if ($cfg.'ado-sha')          { $cfg.'ado-sha' }          elseif ($env:ADO_SHA)                   { $env:ADO_SHA }                    else { $env:BUILD_SOURCEVERSION }
    $headRef    = if ($cfg.'ado-head-ref')     { $cfg.'ado-head-ref' }     elseif ($env:ADO_HEAD_REF)              { $env:ADO_HEAD_REF }               else { $env:SYSTEM_PULLREQUEST_SOURCEBRANCH }
    $runId      = if ($cfg.'ado-run-id')       { $cfg.'ado-run-id' }       elseif ($env:ADO_RUN_ID)                { $env:ADO_RUN_ID }                 else { $env:BUILD_BUILDID }

    # Synthesize event_name: pull_request when PR vars present, else push
    $eventName  = if ($prNumber) { 'pull_request' } else { 'push' }

    # Workflow dispatch inputs: passed as pipeline parameters (ADO) or env vars with prefix ADO_INPUT_
    $workflowInputs = @{}
    Get-ChildItem Env: | Where-Object { $_.Name -like 'ADO_INPUT_*' } | ForEach-Object {
        $key = $_.Name.Substring('ADO_INPUT_'.Length).ToLower()
        $workflowInputs[$key] = $_.Value
    }
    # Also read pipeline parameters surfaced as individual config keys (e.g. proposal_id passed via --config)
    if ($cfg.'proposal_id')    { $workflowInputs['proposal_id']    = $cfg.'proposal_id' }
    if ($cfg.'workspace_name') { $workflowInputs['workspace_name'] = $cfg.'workspace_name' }

    # Build the api_url: {orgUrl}/{project}/_apis
    $apiUrl = if ($orgUrl -and $project) {
        "$($orgUrl.TrimEnd('/'))/$project/_apis"
    } elseif ($orgUrl) {
        $orgUrl.TrimEnd('/')
    } else {
        $null
    }

    $warnings = @()
    if ([string]::IsNullOrEmpty($token))   { $warnings += 'ado-environment-provider: SYSTEM_ACCESSTOKEN / ADO_TOKEN not set - ADO operations will fail' }
    if ([string]::IsNullOrEmpty($orgUrl))  { $warnings += 'ado-environment-provider: SYSTEM_TEAMFOUNDATIONSERVERURI / ADO_ORG_URL not set - ADO operations will fail' }
    if ([string]::IsNullOrEmpty($project)) { $warnings += 'ado-environment-provider: SYSTEM_TEAMPROJECT / ADO_PROJECT not set - ADO operations will fail' }

    @{
        success  = $true
        context  = @{
            'ci-environment' = @{
                token         = $token
                repository    = $repository
                repository_id = $repositoryId
                pr_number     = $prNumber
                sha           = $sha
                head_ref      = $headRef
                event_name    = $eventName
                run_id        = $runId
                api_url       = $apiUrl
                org_url       = $orgUrl
                project       = $project
                inputs        = $workflowInputs
            }
        }
        error    = $null
        warnings = $warnings
    } | ConvertTo-Json -Depth 10
}

# ── PR Output Processors ───────────────────────────────────────────────────────

function Invoke-AdoPostPrComment {
    $payload    = [Console]::In.ReadToEnd() | ConvertFrom-Json
    $ctx        = $payload.context
    $ciEnv      = $ctx.'ci-environment'

    $violations = if ($ctx.violations) { @($ctx.violations) } else { @() }
    $token      = $ciEnv.token
    $prNumber   = $ciEnv.pr_number
    $repoId     = $ciEnv.repository_id
    $apiUrl     = $ciEnv.api_url

    $warnings = [System.Collections.Generic.List[string]]::new()
    $errors   = [System.Collections.Generic.List[string]]::new()

    if ([string]::IsNullOrEmpty($prNumber)) {
        $warnings.Add('ado-post-pr-comment: no PR number in ci-environment - skipping (not a pull request event)')
        @{ success = $true; context = @{}; error = $null; warnings = $warnings.ToArray() } | ConvertTo-Json -Depth 10
        return
    }
    if ([string]::IsNullOrEmpty($repoId) -or [string]::IsNullOrEmpty($apiUrl)) {
        $errors.Add('ado-post-pr-comment: repository_id or api_url missing from ci-environment')
        @{ success = $false; context = @{}; error = $errors -join '; '; warnings = $warnings.ToArray() } | ConvertTo-Json -Depth 10
        return
    }

    $total    = $violations.Count
    $errCount = @($violations | Where-Object { $_.severity -in @('Error', 'Fatal') }).Count
    $wrnCount = @($violations | Where-Object { $_.severity -eq 'Warning' }).Count

    $commentText = Format-AdoViolationComment $violations $total $errCount $wrnCount

    $uri  = "$apiUrl/git/repositories/$repoId/pullRequests/$prNumber/threads?api-version=7.1"
    $body = @{
        comments = @(@{ parentCommentId = 0; content = $commentText; commentType = 1 })
        status   = 1  # Active
    }

    try {
        Invoke-AdoApi -Token $token -Method Post -Uri $uri -Body $body | Out-Null
    } catch {
        $errors.Add("ado-post-pr-comment: failed to post PR thread - $_")
    }

    @{
        success  = ($errors.Count -eq 0)
        context  = @{}
        error    = if ($errors.Count -gt 0) { $errors -join '; ' } else { $null }
        warnings = $warnings.ToArray()
    } | ConvertTo-Json -Depth 10
}

function Invoke-AdoCreateStatus {
    $payload    = [Console]::In.ReadToEnd() | ConvertFrom-Json
    $ctx        = $payload.context
    $ciEnv      = $ctx.'ci-environment'

    $violations = if ($ctx.violations) { @($ctx.violations) } else { @() }
    $token      = $ciEnv.token
    $prNumber   = $ciEnv.pr_number
    $repoId     = $ciEnv.repository_id
    $apiUrl     = $ciEnv.api_url
    $sha        = $ciEnv.sha

    $warnings = [System.Collections.Generic.List[string]]::new()
    $errors   = [System.Collections.Generic.List[string]]::new()

    if ([string]::IsNullOrEmpty($sha) -and [string]::IsNullOrEmpty($prNumber)) {
        $warnings.Add('ado-create-status: no SHA or PR number in ci-environment - skipping')
        @{ success = $true; context = @{}; error = $null; warnings = $warnings.ToArray() } | ConvertTo-Json -Depth 10
        return
    }
    if ([string]::IsNullOrEmpty($apiUrl) -or [string]::IsNullOrEmpty($repoId)) {
        $errors.Add('ado-create-status: api_url or repository_id missing from ci-environment')
        @{ success = $false; context = @{}; error = $errors -join '; '; warnings = $warnings.ToArray() } | ConvertTo-Json -Depth 10
        return
    }

    $errCount = @($violations | Where-Object { $_.severity -in @('Error', 'Fatal') }).Count
    $state    = if ($errCount -gt 0) { 'failed' } else { 'succeeded' }
    $desc     = if ($errCount -gt 0) { "$errCount violation(s) detected" } else { 'No violations' }

    $body = @{
        state       = $state
        description = $desc
        context     = @{ name = 'IArchitecture'; genre = 'architecture' }
    }

    try {
        if ($prNumber -and $repoId) {
            # Post as PR status
            $uri = "$apiUrl/git/repositories/$repoId/pullRequests/$prNumber/statuses?api-version=7.1"
        } else {
            # Post as commit status
            $uri = "$apiUrl/git/repositories/$repoId/commits/$sha/statuses?api-version=7.1"
        }
        Invoke-AdoApi -Token $token -Method Post -Uri $uri -Body $body | Out-Null
    } catch {
        $errors.Add("ado-create-status: failed to post status - $_")
    }

    @{
        success  = ($errors.Count -eq 0)
        context  = @{}
        error    = if ($errors.Count -gt 0) { $errors -join '; ' } else { $null }
        warnings = $warnings.ToArray()
    } | ConvertTo-Json -Depth 10
}

function Invoke-AdoCreateCommitComment {
    $payload    = [Console]::In.ReadToEnd() | ConvertFrom-Json -Depth 20
    $ctx        = $payload.context
    $cfg        = $payload.config
    $ciEnv      = $ctx.'ci-environment'

    $violations  = if ($ctx.violations) { @($ctx.violations) } else { @() }
    $commentSha  = if ($cfg.'comment-sha') { $cfg.'comment-sha' } elseif ($ciEnv -and $ciEnv.sha) { $ciEnv.sha } else { $null }
    $token       = $ciEnv.token
    $repoId      = $ciEnv.repository_id
    $apiUrl      = $ciEnv.api_url

    $warnings = [System.Collections.Generic.List[string]]::new()
    $errors   = [System.Collections.Generic.List[string]]::new()

    if ([string]::IsNullOrEmpty($commentSha)) {
        $errors.Add('ado-create-commit-comment: no SHA available - set comment-sha config or ensure ci-environment contains sha')
        @{ success = $false; context = @{}; error = $errors -join '; '; warnings = $warnings.ToArray() } | ConvertTo-Json -Depth 10
        return
    }

    $total    = $violations.Count
    $errCount = @($violations | Where-Object { $_.severity -in @('Error', 'Fatal') }).Count
    $wrnCount = @($violations | Where-Object { $_.severity -eq 'Warning' }).Count
    $body     = Format-AdoViolationComment $violations $total $errCount $wrnCount

    try {
        $uri      = "$apiUrl/git/repositories/$repoId/commits/$commentSha/comments?api-version=7.1"
        $reqBody  = @{ content = $body }
        Invoke-AdoApi -Token $token -Method Post -Uri $uri -Body $reqBody | Out-Null
    } catch {
        $errors.Add("ado-create-commit-comment: failed to post commit comment - $_")
    }

    @{
        success  = ($errors.Count -eq 0)
        context  = @{}
        error    = if ($errors.Count -gt 0) { $errors -join '; ' } else { $null }
        warnings = $warnings.ToArray()
    } | ConvertTo-Json -Depth 10
}

# ── Git Operations ─────────────────────────────────────────────────────────────

function Invoke-AdoCommitMarkers {
    $payload      = [Console]::In.ReadToEnd() | ConvertFrom-Json
    $ctx          = $payload.context
    $cfg          = $payload.config
    $ciEnv        = $ctx.'ci-environment'

    $writtenFiles = if ($ctx.'annotation-flush-written') { @($ctx.'annotation-flush-written') } else { @() }
    $violations   = if ($ctx.violations) { @($ctx.violations) } else { @() }
    $targetPath   = $cfg.'target-path'

    $warnings = [System.Collections.Generic.List[string]]::new()
    $errors   = [System.Collections.Generic.List[string]]::new()

    if ($writtenFiles.Count -eq 0) {
        $warnings.Add('ado-commit-markers: no annotation-flush-written in context - skipping')
        @{ success = $true; context = @{}; error = $null; warnings = $warnings.ToArray() } | ConvertTo-Json -Depth 10
        return
    }
    if ([string]::IsNullOrEmpty($targetPath)) {
        $errors.Add('ado-commit-markers: target-path config key not set')
        @{ success = $false; context = @{}; error = $errors -join '; '; warnings = $warnings.ToArray() } | ConvertTo-Json -Depth 10
        return
    }

    if ($ciEnv -and $ciEnv.token) { Set-AdoGitAuth -Token $ciEnv.token }

    $violationCount = $violations.Count
    Push-Location $targetPath
    try {
        foreach ($writtenFile in $writtenFiles) {
            git add -f $writtenFile 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                $warnings.Add("ado-commit-markers: failed to stage '$writtenFile' (exit $LASTEXITCODE)")
            }
        }

        git diff --cached --quiet 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $warnings.Add('ado-commit-markers: nothing staged to commit — annotation files may already be committed or gitignored')
            @{ success = $true; context = @{}; error = $null; warnings = $warnings.ToArray() } | ConvertTo-Json -Depth 10
            return
        }

        git commit -m "IArchitecture: update violation markers ($violationCount violation(s))" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            $errors.Add("ado-commit-markers: git commit failed (exit $LASTEXITCODE)")
        } else {
            git push 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { $errors.Add("ado-commit-markers: git push failed (exit $LASTEXITCODE)") }
        }
    } finally {
        Pop-Location
    }

    @{
        success  = ($errors.Count -eq 0)
        context  = @{}
        error    = if ($errors.Count -gt 0) { $errors -join '; ' } else { $null }
        warnings = $warnings.ToArray()
    } | ConvertTo-Json -Depth 10
}

function Invoke-AdoBotCommit {
    $payload         = [Console]::In.ReadToEnd() | ConvertFrom-Json -Depth 20
    $ctx             = $payload.context
    $cfg             = $payload.config
    $ciEnv           = $ctx.'ci-environment'

    $targetPath      = $cfg.'bot-target-path'
    $commitMessage   = $cfg.'bot-commit-message'
    $botBranch       = $cfg.'bot-branch'
    $botFilesRaw     = $cfg.'bot-files'
    $commitCachesRaw = $cfg.'commit-caches'
    $botName         = if ($cfg.'bot-name')  { $cfg.'bot-name' }  else { 'IArchitecture Bot' }
    $botEmail        = if ($cfg.'bot-email') { $cfg.'bot-email' } else { 'iarch-bot@iarchitecture.com' }

    # Resolve bot-target-path: "project-root" / "discovery-root" token → absolute path from context
    if ($targetPath -eq 'project-root')       { $targetPath = $ctx.'project-root' }
    elseif ($targetPath -eq 'discovery-root') { $targetPath = if ($ctx.'discovery-root') { $ctx.'discovery-root' } else { $ctx.'project-root' } }
    if (![string]::IsNullOrEmpty($targetPath) -and ![System.IO.Path]::IsPathRooted($targetPath)) {
        $targetPath = Join-Path ($ctx.'project-root') $targetPath
    }

    # Resolve cache base path: --config cache.base-path (set by workflow, same pattern as full-scan)
    $rawCachePath = if ($cfg.'cache.base-path') { $cfg.'cache.base-path' }
                    else { 'cache' }
    $cacheBasePath = if ([System.IO.Path]::IsPathRooted($rawCachePath)) {
        $rawCachePath.TrimEnd('/\')
    } else {
        Join-Path $targetPath $rawCachePath.TrimEnd('/\')
    }

    $warnings = [System.Collections.Generic.List[string]]::new()
    $errors   = [System.Collections.Generic.List[string]]::new()

    if ([string]::IsNullOrEmpty($targetPath)) {
        $errors.Add('ado-bot-commit: bot-target-path config key not set')
        @{ success = $false; context = @{}; error = $errors -join '; '; warnings = $warnings.ToArray() } | ConvertTo-Json -Depth 10
        return
    }
    if ([string]::IsNullOrEmpty($commitMessage)) {
        $errors.Add('ado-bot-commit: bot-commit-message config key not set')
        @{ success = $false; context = @{}; error = $errors -join '; '; warnings = $warnings.ToArray() } | ConvertTo-Json -Depth 10
        return
    }

    $filesToAdd = [System.Collections.Generic.List[string]]::new()
    if ($botFilesRaw) {
        $botFilesRaw -split ',' | ForEach-Object { $f = $_.Trim(); if ($f) { $filesToAdd.Add($f) } }
    }
    if ($commitCachesRaw) {
        $commitCachesRaw -split ',' | ForEach-Object {
            $name      = $_.Trim(); if (-not $name) { return }
            $cacheType = $cfg."cache.$name.cache-type"
            if ($cacheType -and $cacheType -notin @('raw', '')) {
                $warnings.Add("ado-bot-commit: skipping cache '$name' (type '$cacheType' not committable)")
                return
            }
            $resolved = if ($name -match '\.') { "$cacheBasePath/$name" } else { "$cacheBasePath/$name.json" }
            $filesToAdd.Add($resolved)
        }
    }

    # Diagnostics: log resolved paths
    $warnings.Add("ado-bot-commit: targetPath=$targetPath")
    $warnings.Add("ado-bot-commit: cacheBasePath=$cacheBasePath")
    if ($filesToAdd.Count -gt 0) {
        $filesToAdd | ForEach-Object {
            $exists = Test-Path $_
            $warnings.Add("ado-bot-commit: file-to-add [exists=$exists] $_")
        }
    } else {
        $warnings.Add("ado-bot-commit: no specific files configured — will use git add -A")
    }

    if ($ciEnv -and $ciEnv.token) { Set-AdoGitAuth -Token $ciEnv.token }

    Push-Location $targetPath
    try {
        git config --local user.name  $botName
        git config --local user.email $botEmail

        if ($filesToAdd.Count -gt 0) {
            foreach ($f in $filesToAdd) {
                $gitAddOut = git add -f $f 2>&1
                if ($LASTEXITCODE -ne 0) {
                    $warnings.Add("ado-bot-commit: failed to stage '$f' (exit $LASTEXITCODE): $($gitAddOut -join ' ')")
                }
            }
        } else {
            git add -A 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                $errors.Add("ado-bot-commit: git add -A failed (exit $LASTEXITCODE)")
                @{ success = $false; context = @{}; error = $errors -join '; '; warnings = $warnings.ToArray() } | ConvertTo-Json -Depth 10
                return
            }
        }

        git diff --cached --quiet 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $warnings.Add('ado-bot-commit: nothing staged to commit - skipping')
            @{ success = $true; context = @{}; error = $null; warnings = $warnings.ToArray() } | ConvertTo-Json -Depth 10
            return
        }

        git commit -m $commitMessage 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            $errors.Add("ado-bot-commit: git commit failed (exit $LASTEXITCODE)")
        } else {
            if ($botBranch) { git push origin $botBranch 2>&1 | Out-Null }
            else            { git push 2>&1 | Out-Null }
            if ($LASTEXITCODE -ne 0) { $errors.Add("ado-bot-commit: git push failed (exit $LASTEXITCODE)") }
        }
    } finally {
        Pop-Location
    }

    @{
        success  = ($errors.Count -eq 0)
        context  = @{}
        error    = if ($errors.Count -gt 0) { $errors -join '; ' } else { $null }
        warnings = $warnings.ToArray()
    } | ConvertTo-Json -Depth 10
}

function Invoke-AdoGovernanceRemediationCommit {
    <#
    .SYNOPSIS
    Creates a remediation branch, commits the generated ca-*-processor + healed files, and pushes.
    Writes one entry to branch-list in context for branch-creator / ado-create-pr to consume.
    #>
    $payload    = [Console]::In.ReadToEnd() | ConvertFrom-Json -Depth 20
    $ctx        = $payload.context
    $cfg        = $payload.config
    $ciEnv      = $ctx.'ci-environment'

    $targetPath   = $cfg.'bot-target-path'
    $botName      = if ($cfg.'bot-name')  { $cfg.'bot-name' }  else { 'IArchitecture Bot' }
    $botEmail     = if ($cfg.'bot-email') { $cfg.'bot-email' } else { 'iarch-bot@iarchitecture.com' }
    $healedFiles  = if ($ctx.'annotation-flush-written') { @($ctx.'annotation-flush-written') } else { @() }

    $warnings = [System.Collections.Generic.List[string]]::new()
    $errors   = [System.Collections.Generic.List[string]]::new()

    if ([string]::IsNullOrEmpty($targetPath)) {
        $errors.Add('governance-remediation-commit-ado: bot-target-path config key not set')
        @{ success = $false; context = @{}; error = $errors -join '; '; warnings = $warnings.ToArray() } | ConvertTo-Json -Depth 10
        return
    }

    $caProcessorPath = $ctx.'ca-processor-path'
    if ([string]::IsNullOrEmpty($caProcessorPath)) {
        $errors.Add('governance-remediation-commit-ado: ca-processor-path not in context')
        @{ success = $false; context = @{}; error = $errors -join '; '; warnings = $warnings.ToArray() } | ConvertTo-Json -Depth 10
        return
    }

    $processorDirName = Split-Path $caProcessorPath -Leaf
    $branchName       = "iarch/remediation/$processorDirName"

    if ($ciEnv -and $ciEnv.token) { Set-AdoGitAuth -Token $ciEnv.token }

    Push-Location $targetPath
    try {
        git config --local user.name  $botName
        git config --local user.email $botEmail

        git checkout -B $branchName 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            $errors.Add("governance-remediation-commit-ado: git checkout -B $branchName failed (exit $LASTEXITCODE)")
            @{ success = $false; context = @{}; error = $errors -join '; '; warnings = $warnings.ToArray() } | ConvertTo-Json -Depth 10
            return
        }

        $absoluteTargetPath = (Resolve-Path $targetPath).Path
        $relPath = [System.IO.Path]::GetRelativePath($absoluteTargetPath, $caProcessorPath)
        git add -f $relPath 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            $errors.Add("governance-remediation-commit-ado: failed to stage processor directory '$relPath' (exit $LASTEXITCODE)")
            @{ success = $false; context = @{}; error = $errors -join '; '; warnings = $warnings.ToArray() } | ConvertTo-Json -Depth 10
            return
        }

        if ($healedFiles.Count -gt 0) {
            $stagedCount = 0
            foreach ($healedFile in $healedFiles) {
                $relHealedPath = [System.IO.Path]::GetRelativePath($absoluteTargetPath, $healedFile)
                git add -f $relHealedPath 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    $warnings.Add("governance-remediation-commit-ado: failed to stage healed file '$relHealedPath' (exit $LASTEXITCODE)")
                } else {
                    $stagedCount++
                }
            }
            $warnings.Add("governance-remediation-commit-ado: staged $stagedCount of $($healedFiles.Count) healed file(s)")
        }

        git diff --cached --quiet 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $warnings.Add('governance-remediation-commit-ado: nothing staged to commit - processor may already be committed')
        } else {
            $healedCount = $healedFiles.Count
            $commitMsg   = if ($healedCount -gt 0) {
                "IArchitecture: add $processorDirName ca-*-processor + $healedCount healed file(s) (cluster-remediation)"
            } else {
                "IArchitecture: add $processorDirName ca-*-processor (cluster-remediation)"
            }
            git commit -m $commitMsg 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                $errors.Add("governance-remediation-commit-ado: git commit failed (exit $LASTEXITCODE)")
            } else {
                git push --force-with-lease origin $branchName 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) { $errors.Add("governance-remediation-commit-ado: git push failed (exit $LASTEXITCODE)") }
            }
        }
    } finally {
        git checkout - 2>&1 | Out-Null
        Pop-Location
    }

    $branchEntry = @{
        'branch-name' = $branchName
        'repo'        = if ($ciEnv -and $ciEnv.repository) { $ciEnv.repository } else { $env:BUILD_REPOSITORY_NAME }
        'base'        = $cfg.'pr-base' ?? 'master'
        'files'       = $healedFiles
        'title'       = "IArchitecture: cluster-remediation $processorDirName"
        'body'        = $null
        'labels'      = @('iarchitecture', 'cluster-remediation')
        'pr-url'      = $null
    }

    @{
        success  = ($errors.Count -eq 0)
        context  = @{ 'branch-list' = @($branchEntry) }
        error    = if ($errors.Count -gt 0) { $errors -join '; ' } else { $null }
        warnings = $warnings.ToArray()
    } | ConvertTo-Json -Depth 10
}

# ── PR + Pipeline Processors ───────────────────────────────────────────────────

function Invoke-AdoCreatePR {
    $payload    = [Console]::In.ReadToEnd() | ConvertFrom-Json -Depth 20
    $ctx        = $payload.context
    $cfg        = $payload.config
    $ciEnv      = $ctx.'ci-environment'

    $token  = $ciEnv.token
    $repoId = $ciEnv.repository_id
    $apiUrl = $ciEnv.api_url

    $warnings = [System.Collections.Generic.List[string]]::new()
    $errors   = [System.Collections.Generic.List[string]]::new()

    # Read branch-list.created — list of branch descriptors to open PRs for
    $branchList = if ($ctx.'branch-list.created') { @($ctx.'branch-list.created') } else { @() }
    if ($branchList.Count -eq 0) {
        $errors.Add('ado-create-pr: branch-list.created not in context or empty')
        @{ success = $false; context = @{}; error = $errors -join '; '; warnings = $warnings.ToArray() } | ConvertTo-Json -Depth 10
        return
    }

    $updatedList = [System.Collections.Generic.List[object]]::new()

    foreach ($entry in $branchList) {
        $prHead  = $entry.'branch-name'
        $prBase  = if ($entry.'base')  { $entry.'base' }  else { $cfg.'pr-base' ?? 'master' }
        $prTitle = if ($entry.'title') { $entry.'title' } else { $cfg.'pr-title' ?? "IArchitecture: $prHead" }
        $prBody  = if ($entry.'body')  { $entry.'body' }  else { "## IArchitecture Auto-Generated PR`n`n*Generated by IArchitecture*" }
        $prLabels = if ($entry.'labels') { $entry.'labels' } else { $cfg.'pr-labels' }

        $sourceRef = if ($prHead -like 'refs/*') { $prHead } else { "refs/heads/$prHead" }
        $targetRef = if ($prBase -like 'refs/*') { $prBase } else { "refs/heads/$prBase" }

        $body = @{
            title         = $prTitle
            description   = $prBody
            sourceRefName = $sourceRef
            targetRefName = $targetRef
        }
        if ($prLabels) {
            $body['labels'] = @(@($prLabels) | ForEach-Object { @{ name = $_ } })
        }

        $prUrl = $null
        try {
            $uri  = "$apiUrl/git/repositories/$repoId/pullRequests?api-version=7.1"
            $resp = Invoke-AdoApi -Token $token -Method Post -Uri $uri -Body $body
            $prId = $resp.pullRequestId
            $orgUrl  = $ciEnv.org_url
            $project = $ciEnv.project
            $repo    = $ciEnv.repository
            if ($orgUrl -and $project -and $repo -and $prId) {
                $prUrl = "$($orgUrl.TrimEnd('/'))/$project/_git/$repo/pullrequest/$prId"
            }
            $warnings.Add("ado-create-pr: created PR $prId - $prTitle")
        } catch {
            $errors.Add("ado-create-pr: failed to create PR for '$prHead' - $_")
        }

        $updated = @{}
        $entry.PSObject.Properties | ForEach-Object { $updated[$_.Name] = $_.Value }
        $updated['pr-url'] = $prUrl
        $updatedList.Add($updated)
    }

    @{
        success  = ($errors.Count -eq 0)
        context  = @{ 'branch-list.pr-created' = $updatedList.ToArray() }
        error    = if ($errors.Count -gt 0) { $errors -join '; ' } else { $null }
        warnings = $warnings.ToArray()
    } | ConvertTo-Json -Depth 10
}

function Invoke-AdoTriggerPipeline {
    <#
    .SYNOPSIS
    Triggers an ADO pipeline run via REST API.

    Config:
      trigger-pipeline-id    — ADO pipeline definition ID (required)
      trigger-pipeline-ref   — branch to run on (default: main)
      trigger-pipeline-repo  — optional repo override
    Fan-out mode: triggers once per proposal ID in approved-proposal-ids,
    passing proposal_id and workspace_name as templateParameters.
    #>
    $payload      = [Console]::In.ReadToEnd() | ConvertFrom-Json -Depth 20
    $ctx          = $payload.context
    $cfg          = $payload.config
    $ciEnv        = $ctx.'ci-environment'

    $pipelineId   = $cfg.'trigger-pipeline-id'
    $pipelineRef  = if ($cfg.'trigger-pipeline-ref') { $cfg.'trigger-pipeline-ref' } else { 'main' }
    $token        = $ciEnv.token
    $apiUrl       = $ciEnv.api_url

    $warnings = [System.Collections.Generic.List[string]]::new()
    $errors   = [System.Collections.Generic.List[string]]::new()

    if ([string]::IsNullOrEmpty($pipelineId)) {
        $errors.Add('ado-trigger-pipeline: trigger-pipeline-id config key not set')
        @{ success = $false; context = @{}; error = $errors -join '; '; warnings = $warnings.ToArray() } | ConvertTo-Json -Depth 10
        return
    }

    $uri = "$apiUrl/pipelines/$pipelineId/runs?api-version=7.1"

    $approvedIds = if ($ctx.'approved-proposal-ids') { @($ctx.'approved-proposal-ids') } else { @() }

    if ($approvedIds.Count -gt 0) {
        # Fan-out: one run per approved proposal
        foreach ($proposalId in $approvedIds) {
            $body = @{
                resources         = @{ repositories = @{ self = @{ refName = "refs/heads/$pipelineRef" } } }
                templateParameters = @{ proposal_id = $proposalId }
            }
            try {
                Invoke-AdoApi -Token $token -Method Post -Uri $uri -Body $body | Out-Null
                $warnings.Add("ado-trigger-pipeline: triggered pipeline $pipelineId for proposal $proposalId")
            } catch {
                $errors.Add("ado-trigger-pipeline: failed for proposal $proposalId - $_")
            }
        }
    } else {
        # Single trigger
        $body = @{
            resources = @{ repositories = @{ self = @{ refName = "refs/heads/$pipelineRef" } } }
        }
        try {
            Invoke-AdoApi -Token $token -Method Post -Uri $uri -Body $body | Out-Null
            $warnings.Add("ado-trigger-pipeline: triggered pipeline $pipelineId")
        } catch {
            $errors.Add("ado-trigger-pipeline: failed to trigger pipeline $pipelineId - $_")
        }
    }

    @{
        success  = ($errors.Count -eq 0)
        context  = @{}
        error    = if ($errors.Count -gt 0) { $errors -join '; ' } else { $null }
        warnings = $warnings.ToArray()
    } | ConvertTo-Json -Depth 10
}

function Invoke-AdoWorkflowDispatcher {
    <#
    .SYNOPSIS
    Routes approved/promoted proposal IDs to the appropriate ADO pipeline triggers.

    Config:
      cluster-remediation-pipeline-id  — ADO pipeline definition ID for cluster-remediation
      governance-promote-pipeline-id   — ADO pipeline definition ID for governance-promote
      trigger-pipeline-ref             — branch to run on (default: main)
    #>
    $payload    = [Console]::In.ReadToEnd() | ConvertFrom-Json -Depth 20
    $ctx        = $payload.context
    $cfg        = $payload.config
    $ciEnv      = $ctx.'ci-environment'

    $remediationPipelineId = $cfg.'cluster-remediation-pipeline-id'
    $promotePipelineId     = $cfg.'governance-promote-pipeline-id'
    $pipelineRef           = if ($cfg.'trigger-pipeline-ref') { $cfg.'trigger-pipeline-ref' } else { 'main' }
    $token                 = $ciEnv.token
    $apiUrl                = $ciEnv.api_url

    $approvedIds = if ($ctx.'approved-proposal-ids') { @($ctx.'approved-proposal-ids') } else { @() }
    $promotedIds = if ($ctx.'promoted-proposal-ids') { @($ctx.'promoted-proposal-ids') } else { @() }

    $warnings = [System.Collections.Generic.List[string]]::new()
    $errors   = [System.Collections.Generic.List[string]]::new()

    if ($approvedIds.Count -eq 0 -and $promotedIds.Count -eq 0) {
        $warnings.Add('ado-workflow-dispatcher: no approved or promoted proposal IDs - nothing to trigger')
        @{ success = $true; context = @{}; error = $null; warnings = $warnings.ToArray() } | ConvertTo-Json -Depth 10
        return
    }

    # Build workspace lookup from ledger-state
    $ledgerState = if ($ctx.'ledger-state') { @($ctx.'ledger-state') } else { @() }
    $workspaceMap = @{}
    foreach ($le in $ledgerState) {
        if ($le.proposal_id) { $workspaceMap[$le.proposal_id] = $le.workspace_name }
    }

    foreach ($proposalId in $approvedIds) {
        if ([string]::IsNullOrEmpty($remediationPipelineId)) {
            $errors.Add('ado-workflow-dispatcher: cluster-remediation-pipeline-id config key not set')
            break
        }
        $params = @{ proposal_id = $proposalId }
        $wn = $workspaceMap[$proposalId]
        if ($wn) { $params['workspace_name'] = $wn }

        $uri  = "$apiUrl/pipelines/$remediationPipelineId/runs?api-version=7.1"
        $body = @{
            resources          = @{ repositories = @{ self = @{ refName = "refs/heads/$pipelineRef" } } }
            templateParameters = $params
        }
        try {
            Invoke-AdoApi -Token $token -Method Post -Uri $uri -Body $body | Out-Null
            $warnings.Add("ado-workflow-dispatcher: triggered cluster-remediation pipeline for proposal $proposalId")
        } catch {
            $errors.Add("ado-workflow-dispatcher: failed to trigger cluster-remediation for $proposalId - $_")
        }
    }

    foreach ($proposalId in $promotedIds) {
        if ([string]::IsNullOrEmpty($promotePipelineId)) {
            $errors.Add('ado-workflow-dispatcher: governance-promote-pipeline-id config key not set')
            break
        }
        $params = @{ proposal_id = $proposalId }
        $wn = $workspaceMap[$proposalId]
        if ($wn) { $params['workspace_name'] = $wn }

        $uri  = "$apiUrl/pipelines/$promotePipelineId/runs?api-version=7.1"
        $body = @{
            resources          = @{ repositories = @{ self = @{ refName = "refs/heads/$pipelineRef" } } }
            templateParameters = $params
        }
        try {
            Invoke-AdoApi -Token $token -Method Post -Uri $uri -Body $body | Out-Null
            $warnings.Add("ado-workflow-dispatcher: triggered governance-promote pipeline for proposal $proposalId")
        } catch {
            $errors.Add("ado-workflow-dispatcher: failed to trigger governance-promote for $proposalId - $_")
        }
    }

    @{
        success  = ($errors.Count -eq 0)
        context  = @{}
        error    = if ($errors.Count -gt 0) { $errors -join '; ' } else { $null }
        warnings = $warnings.ToArray()
    } | ConvertTo-Json -Depth 10
}

# ── Work Item Processor ────────────────────────────────────────────────────────

function Invoke-AdoCreateWorkItem {
    <#
    .SYNOPSIS
    Creates an ADO work item from violation summary.
    Config: issue-title, issue-labels, work-item-type (default: Task).
    #>
    $payload      = [Console]::In.ReadToEnd() | ConvertFrom-Json -Depth 20
    $ctx          = $payload.context
    $cfg          = $payload.config
    $ciEnv        = $ctx.'ci-environment'

    $violations   = if ($ctx.violations) { @($ctx.violations) } else { @() }
    $issueTitle   = $cfg.'issue-title'
    $issueLabels  = $cfg.'issue-labels'
    $workItemType = if ($cfg.'work-item-type') { $cfg.'work-item-type' } else { 'Task' }
    $token        = $ciEnv.token
    $apiUrl       = $ciEnv.api_url

    $warnings = [System.Collections.Generic.List[string]]::new()
    $errors   = [System.Collections.Generic.List[string]]::new()

    if ([string]::IsNullOrEmpty($issueTitle)) {
        $errors.Add('ado-create-work-item: issue-title config key not set')
        @{ success = $false; context = @{}; error = $errors -join '; '; warnings = $warnings.ToArray() } | ConvertTo-Json -Depth 10
        return
    }

    $total    = $violations.Count
    $errCount = @($violations | Where-Object { $_.severity -in @('Error', 'Fatal') }).Count
    $wrnCount = @($violations | Where-Object { $_.severity -eq 'Warning' }).Count
    $descText = Format-AdoViolationComment $violations $total $errCount $wrnCount

    $patchDoc = @(
        @{ op = 'add'; path = '/fields/System.Title';       value = $issueTitle }
        @{ op = 'add'; path = '/fields/System.Description'; value = $descText }
    )
    if ($issueLabels) {
        $patchDoc += @{ op = 'add'; path = '/fields/System.Tags'; value = ($issueLabels -replace ',', ';') }
    }

    try {
        $typeEncoded = [Uri]::EscapeDataString($workItemType)
        $uri = "$apiUrl/wit/workitems/`$$typeEncoded?api-version=7.1"
        Invoke-AdoApiPatch -Token $token -Uri $uri -PatchDoc $patchDoc | Out-Null
        $warnings.Add("ado-create-work-item: created $workItemType '$issueTitle'")
    } catch {
        $errors.Add("ado-create-work-item: failed to create work item - $_")
    }

    @{
        success  = ($errors.Count -eq 0)
        context  = @{}
        error    = if ($errors.Count -gt 0) { $errors -join '; ' } else { $null }
        warnings = $warnings.ToArray()
    } | ConvertTo-Json -Depth 10
}
