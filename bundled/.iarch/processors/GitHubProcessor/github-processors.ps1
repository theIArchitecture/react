#!/usr/bin/env pwsh
<#
.SYNOPSIS
GitHub processors for the IArchitecture pipeline.

Dot-sourced by the Modulus PowerShell executor; entry points called directly.
Contract: stdin JSON { context, config, metadata } -> stdout JSON { success, context, error, warnings }

Processors:
  Invoke-GitHubContextProvider   -  reads GitHub env vars (+ config overrides), provides ci-environment
  Invoke-PostPrComment           -  posts violation summary as PR comment via gh CLI
  Invoke-CreateCheck             -  creates a GitHub check run via gh CLI
  Invoke-CommitMarkers           -  commits annotation-flushed files and pushes via git
  Invoke-BotCommit               -  git config/add/commit/push for IArchHub files (metadata, cache, etc.)
  Invoke-CreatePR                -  creates a GitHub PR via gh CLI
  Invoke-TriggerWorkflow         -  triggers a GitHub Actions workflow via gh CLI
  Invoke-CreateIssue             -  creates a GitHub Issue in the target repo via gh CLI
  Invoke-CreateCommitComment     -  posts a commit comment via gh API
#>

function Invoke-GitHubContextProvider {
    $payload = [Console]::In.ReadToEnd() | ConvertFrom-Json
    $cfg     = $payload.config

    # Priority: config override > CI_* generic vars > GITHUB_* platform vars > event payload
    $token      = if ($cfg.'github-token')      { $cfg.'github-token' }      elseif ($env:CI_TOKEN)      { $env:CI_TOKEN }      else { $env:GITHUB_TOKEN }
    $repository = if ($cfg.'github-repository') { $cfg.'github-repository' } elseif ($env:CI_REPOSITORY) { $env:CI_REPOSITORY } else { $env:GITHUB_REPOSITORY }
    $prNumber   = if ($cfg.'github-pr-number')  { $cfg.'github-pr-number' }  elseif ($env:CI_PR_NUMBER)  { $env:CI_PR_NUMBER }  else { $env:GITHUB_PR_NUMBER }
    $sha        = if ($cfg.'github-sha')        { $cfg.'github-sha' }        elseif ($env:CI_SHA)        { $env:CI_SHA }        else { $env:GITHUB_SHA }
    $headRef    = if ($cfg.'github-head-ref')   { $cfg.'github-head-ref' }   elseif ($env:CI_HEAD_REF)   { $env:CI_HEAD_REF }   else { $env:GITHUB_HEAD_REF }
    $eventName  = if ($cfg.'github-event-name') { $cfg.'github-event-name' } elseif ($env:CI_EVENT)      { $env:CI_EVENT }      else { $env:GITHUB_EVENT_NAME }
    $runId      = if ($cfg.'github-run-id')     { $cfg.'github-run-id' }     elseif ($env:CI_RUN_ID)     { $env:CI_RUN_ID }     else { $env:GITHUB_RUN_ID }
    $apiUrl     = if ($cfg.'github-api-url')    { $cfg.'github-api-url' }    `
                  elseif ($env:CI_API_URL)      { $env:CI_API_URL }          `
                  elseif ($env:GITHUB_API_URL)  { $env:GITHUB_API_URL }      `
                  else                          { 'https://api.github.com' }

    # Enrich from the GitHub Actions event payload  -  fills in PR number, head SHA,
    # and workflow_dispatch inputs (e.g. proposal_id passed via gh workflow run --field).
    # Priority: config override > CI_* > GITHUB_* > event payload.
    $workflowInputs = @{}
    if ($env:GITHUB_EVENT_PATH -and (Test-Path $env:GITHUB_EVENT_PATH)) {
        $event = Get-Content $env:GITHUB_EVENT_PATH -Raw | ConvertFrom-Json
        if (-not $prNumber -and $event.pull_request) { $prNumber = [string]$event.pull_request.number }
        if (-not $sha      -and $event.pull_request) { $sha      = $event.pull_request.head.sha }
        if (-not $headRef  -and $event.pull_request) { $headRef  = $event.pull_request.head.ref }
        # workflow_dispatch inputs land at event.inputs (e.g. proposal_id from jira-poll fan-out)
        if ($event.inputs) { $workflowInputs = $event.inputs }
    }

    $warnings = @()
    if ([string]::IsNullOrEmpty($token))      { $warnings += 'CI_TOKEN / GITHUB_TOKEN not set  -  GitHub operations will fail' }
    if ([string]::IsNullOrEmpty($repository)) { $warnings += 'CI_REPOSITORY / GITHUB_REPOSITORY not set  -  GitHub operations will fail' }

    @{
        success  = $true
        context  = @{
            'ci-environment' = @{
                token      = $token
                repository = $repository
                pr_number  = $prNumber
                sha        = $sha
                head_ref   = $headRef
                event_name = $eventName
                run_id     = $runId
                api_url    = $apiUrl
                inputs     = $workflowInputs   # workflow_dispatch inputs; empty hashtable for push/PR events
            }
        }
        error    = $null
        warnings = $warnings
    } | ConvertTo-Json -Depth 10
}

function Invoke-PostPrComment {
    $payload     = [Console]::In.ReadToEnd() | ConvertFrom-Json
    $ctx         = $payload.context
    $ciEnv       = $ctx.'ci-environment'

    $violations  = if ($ctx.violations) { @($ctx.violations) } else { @() }
    $token       = $ciEnv.token
    $repository  = $ciEnv.repository
    $prNumber    = $ciEnv.pr_number

    $warnings = [System.Collections.Generic.List[string]]::new()
    $errors   = [System.Collections.Generic.List[string]]::new()

    if ([string]::IsNullOrEmpty($prNumber)) {
        $warnings.Add('post-pr-comment: no PR number in ci-environment  -  skipping (not a pull request event)')
        @{
            success  = $true
            context  = @{}
            error    = $null
            warnings = $warnings.ToArray()
        } | ConvertTo-Json -Depth 10
        return
    }

    if ($token) { $env:GH_TOKEN = $token }

    $violationCount = $violations.Count
    $errorCount     = @($violations | Where-Object { $_.severity -in @('Error', 'Fatal') }).Count
    $warningCount   = @($violations | Where-Object { $_.severity -eq 'Warning' }).Count

    $body = Format-ViolationComment $violations $violationCount $errorCount $warningCount
    gh pr comment $prNumber --repo $repository --body $body 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { $errors.Add("post-pr-comment: gh pr comment failed (exit $LASTEXITCODE)") }

    @{
        success  = ($errors.Count -eq 0)
        context  = @{}
        error    = if ($errors.Count -gt 0) { $errors -join '; ' } else { $null }
        warnings = $warnings.ToArray()
    } | ConvertTo-Json -Depth 10
}

function Invoke-CreateCheck {
    $payload    = [Console]::In.ReadToEnd() | ConvertFrom-Json
    $ctx        = $payload.context
    $ciEnv      = $ctx.'ci-environment'

    $violations = if ($ctx.violations) { @($ctx.violations) } else { @() }
    $token      = $ciEnv.token
    $repository = $ciEnv.repository
    $sha        = $ciEnv.sha

    $warnings = [System.Collections.Generic.List[string]]::new()
    $errors   = [System.Collections.Generic.List[string]]::new()

    if ([string]::IsNullOrEmpty($sha)) {
        $warnings.Add('create-check: no SHA in ci-environment  -  skipping')
        @{
            success  = $true
            context  = @{}
            error    = $null
            warnings = $warnings.ToArray()
        } | ConvertTo-Json -Depth 10
        return
    }

    if ($token) { $env:GH_TOKEN = $token }

    $violationCount = $violations.Count
    $errorCount     = @($violations | Where-Object { $_.severity -in @('Error', 'Fatal') }).Count
    $warningCount   = @($violations | Where-Object { $_.severity -eq 'Warning' }).Count

    $conclusion = if ($errorCount -gt 0) { 'failure' } else { 'success' }
    $title      = if ($errorCount -gt 0) { "$errorCount error(s), $warningCount warning(s)" } else { 'No violations' }
    $summary    = Format-CheckSummary $violations $violationCount $errorCount $warningCount

    gh api "repos/$repository/check-runs" `
        --method POST `
        -f name='IArchitecture' `
        -f "head_sha=$sha" `
        -f status='completed' `
        -f "conclusion=$conclusion" `
        -f "output[title]=$title" `
        -f "output[summary]=$summary" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { $errors.Add("create-check: gh api check-runs failed (exit $LASTEXITCODE)") }

    @{
        success  = ($errors.Count -eq 0)
        context  = @{}
        error    = if ($errors.Count -gt 0) { $errors -join '; ' } else { $null }
        warnings = $warnings.ToArray()
    } | ConvertTo-Json -Depth 10
}

function Invoke-CommitMarkers {
    $payload    = [Console]::In.ReadToEnd() | ConvertFrom-Json
    $ctx        = $payload.context
    $cfg        = $payload.config
    $ciEnv      = $ctx.'ci-environment'

    $writtenFiles   = if ($ctx.'annotation-flush-written') { @($ctx.'annotation-flush-written') } else { @() }
    $violations     = if ($ctx.violations) { @($ctx.violations) } else { @() }
    $targetPath     = $cfg.'target-path'

    $warnings = [System.Collections.Generic.List[string]]::new()
    $errors   = [System.Collections.Generic.List[string]]::new()

    if ($writtenFiles.Count -eq 0) {
        $warnings.Add('commit-markers: no annotation-flush-written in context  -  skipping')
        @{
            success  = $true
            context  = @{}
            error    = $null
            warnings = $warnings.ToArray()
        } | ConvertTo-Json -Depth 10
        return
    }

    if ([string]::IsNullOrEmpty($targetPath)) {
        $errors.Add('commit-markers: target-path config key not set')
        @{
            success  = $false
            context  = @{}
            error    = $errors -join '; '
            warnings = $warnings.ToArray()
        } | ConvertTo-Json -Depth 10
        return
    }

    # Set token for authenticated push if ci-environment is available
    if ($ciEnv -and $ciEnv.token) { $env:GH_TOKEN = $ciEnv.token }

    $violationCount = $violations.Count
    # Files are already on disk — written by annotation-flush processor upstream

    Push-Location $targetPath
    try {
        foreach ($writtenFile in $writtenFiles) {
            git add -f $writtenFile 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                $warnings.Add("commit-markers: failed to stage '$writtenFile' (exit $LASTEXITCODE)")
            }
        }

        git diff --cached --quiet 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $warnings.Add('commit-markers: nothing staged to commit — annotation files may already be committed or gitignored')
            @{ success = $true; context = @{}; error = $null; warnings = $warnings.ToArray() } | ConvertTo-Json -Depth 10
            return
        }

        git commit -m "IArchitecture: update violation markers ($violationCount violation(s))" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            $errors.Add("commit-markers: git commit failed (exit $LASTEXITCODE)")
        } else {
            git push 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { $errors.Add("commit-markers: git push failed (exit $LASTEXITCODE)") }
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

function Invoke-BotCommit {
    $payload       = [Console]::In.ReadToEnd() | ConvertFrom-Json -Depth 20
    $ctx           = $payload.context
    $cfg           = $payload.config
    $ciEnv         = $ctx.'ci-environment'

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

    # Resolve cache base path: --config cache.base-path > config.json cache-root-path > 'cache'
    $rawCachePath = if ($cfg.'cache.base-path') { $cfg.'cache.base-path' }
                    elseif ($ctx.'cache-root-path') { $ctx.'cache-root-path' }
                    else { 'cache' }
    $cacheBasePath = if ([System.IO.Path]::IsPathRooted($rawCachePath)) {
        $rawCachePath.TrimEnd('/\')
    } else {
        Join-Path $targetPath $rawCachePath.TrimEnd('/\')
    }

    $warnings = [System.Collections.Generic.List[string]]::new()
    $errors   = [System.Collections.Generic.List[string]]::new()

    if ([string]::IsNullOrEmpty($targetPath)) {
        $errors.Add('bot-commit: bot-target-path config key not set')
        @{ success = $false; context = @{}; error = $errors -join '; '; warnings = $warnings.ToArray() } | ConvertTo-Json -Depth 10
        return
    }
    if ([string]::IsNullOrEmpty($commitMessage)) {
        $errors.Add('bot-commit: bot-commit-message config key not set')
        @{ success = $false; context = @{}; error = $errors -join '; '; warnings = $warnings.ToArray() } | ConvertTo-Json -Depth 10
        return
    }

    # Build combined file list from explicit bot-files + cache-name resolution
    $filesToAdd = [System.Collections.Generic.List[string]]::new()

    if ($botFilesRaw) {
        $botFilesRaw -split ',' | ForEach-Object {
            $f = $_.Trim(); if ($f) { $filesToAdd.Add($f) }
        }
    }

    if ($commitCachesRaw) {
        $commitCachesRaw -split ',' | ForEach-Object {
            $name      = $_.Trim(); if (-not $name) { return }
            $cacheType = $cfg."cache.$name.cache-type"
            # Only raw caches produce human-readable files suitable for git
            if ($cacheType -and $cacheType -notin @('raw', '')) {
                $warnings.Add("bot-commit: skipping cache '$name' (type '$cacheType' not committable via commit-caches)")
                return
            }
            # Key with extension (e.g. dashboard.html) -> raw byte file; without -> .json object
            $resolved = if ($name -match '\.') { "$cacheBasePath/$name" } else { "$cacheBasePath/$name.json" }
            $filesToAdd.Add($resolved)
        }
    }

    if ($ciEnv -and $ciEnv.token) { $env:GH_TOKEN = $ciEnv.token }

    # Diagnostics: log resolved paths via warnings (appear in JSON output → CI log)
    $warnings.Add("bot-commit: targetPath=$targetPath")
    $warnings.Add("bot-commit: cacheBasePath=$cacheBasePath")
    if ($filesToAdd.Count -gt 0) {
        $filesToAdd | ForEach-Object {
            $exists = Test-Path $_
            $warnings.Add("bot-commit: file-to-add [exists=$exists] $_")
        }
    } else {
        $warnings.Add("bot-commit: no specific files configured — will use git add -A")
    }

    Push-Location $targetPath
    try {
        git config --local user.name $botName
        git config --local user.email $botEmail

        # Diagnostics: git status before staging
        $gitStatus = git status --porcelain 2>&1
        if ($gitStatus) {
            $warnings.Add("bot-commit: git status (pre-stage): $($gitStatus -join '; ')")
        } else {
            $warnings.Add("bot-commit: git status (pre-stage): no changes detected")
        }

        if ($filesToAdd.Count -gt 0) {
            foreach ($f in $filesToAdd) {
                $gitAddOut = git add -f $f 2>&1
                if ($LASTEXITCODE -ne 0) {
                    $warnings.Add("bot-commit: failed to stage '$f' (exit $LASTEXITCODE): $($gitAddOut -join ' ')")
                }
            }
        } else {
            git add -A 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                $errors.Add("bot-commit: git add -A failed (exit $LASTEXITCODE)")
                @{ success = $false; context = @{}; error = $errors -join '; '; warnings = $warnings.ToArray() } | ConvertTo-Json -Depth 10
                return
            }
        }

        # Check if there is anything staged to commit
        git diff --cached --quiet 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $warnings.Add('bot-commit: nothing staged to commit — skipping')
            @{ success = $true; context = @{}; error = $null; warnings = $warnings.ToArray() } | ConvertTo-Json -Depth 10
            return
        }

        git commit -m $commitMessage 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            $errors.Add("bot-commit: git commit failed (exit $LASTEXITCODE)")
        } else {
            if ($botBranch) {
                git push origin $botBranch 2>&1 | Out-Null
            } else {
                git push 2>&1 | Out-Null
            }
            if ($LASTEXITCODE -ne 0) { $errors.Add("bot-commit: git push failed (exit $LASTEXITCODE)") }
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

function Invoke-CreatePR {
    $payload    = [Console]::In.ReadToEnd() | ConvertFrom-Json -Depth 20
    $ctx        = $payload.context
    $cfg        = $payload.config
    $ciEnv      = $ctx.'ci-environment'

    $violations = if ($ctx.violations) { @($ctx.violations) } else { @() }
    $prTitle    = $cfg.'pr-title'
    $prBase     = $cfg.'pr-base'
    $prHead     = if ($cfg.'pr-head') { $cfg.'pr-head' } elseif ($ciEnv -and $ciEnv.head_ref) { $ciEnv.head_ref } else { $null }
    $prLabels   = $cfg.'pr-labels'
    $prBody     = $cfg.'pr-body'

    $warnings = [System.Collections.Generic.List[string]]::new()
    $errors   = [System.Collections.Generic.List[string]]::new()

    if ([string]::IsNullOrEmpty($prTitle)) {
        $errors.Add('create-pr: pr-title config key not set')
        @{ success = $false; context = @{}; error = $errors -join '; '; warnings = $warnings.ToArray() } | ConvertTo-Json -Depth 10
        return
    }
    if ([string]::IsNullOrEmpty($prBase)) {
        $errors.Add('create-pr: pr-base config key not set')
        @{ success = $false; context = @{}; error = $errors -join '; '; warnings = $warnings.ToArray() } | ConvertTo-Json -Depth 10
        return
    }
    # Fall back to remediation-branch written by governance-remediation-commit
    if ([string]::IsNullOrEmpty($prHead) -and $ctx.'remediation-branch') {
        $prHead = $ctx.'remediation-branch'
    }
    if ([string]::IsNullOrEmpty($prHead)) {
        $errors.Add('create-pr: pr-head not set and no headRef or remediation-branch in context')
        @{ success = $false; context = @{}; error = $errors -join '; '; warnings = $warnings.ToArray() } | ConvertTo-Json -Depth 10
        return
    }

    if ($ciEnv -and $ciEnv.token) { $env:GH_TOKEN = $ciEnv.token }

    if ([string]::IsNullOrEmpty($prBody)) {
        $violationCount = $violations.Count
        $errorCount     = @($violations | Where-Object { $_.severity -in @('Error', 'Fatal') }).Count
        $warningCount   = @($violations | Where-Object { $_.severity -eq 'Warning' }).Count
        $prBody = "## IArchitecture Auto-Generated PR`n`n**Violations addressed:** $violationCount ($errorCount fatal, $warningCount warning)`n`n*Generated by IArchitecture*"
    }

    # pr-repo config allows targeting a spoke repo instead of the current workflow repo
    $repository = if ($cfg.'pr-repo') { $cfg.'pr-repo' } elseif ($ciEnv -and $ciEnv.repository) { $ciEnv.repository } else { $env:GITHUB_REPOSITORY }

    $ghArgs     = @('pr', 'create', '--title', $prTitle, '--body', $prBody, '--base', $prBase, '--head', $prHead)
    if ($prLabels)   { $ghArgs += @('--label', $prLabels) }
    if ($repository) { $ghArgs += @('--repo',  $repository) }

    $output = gh @ghArgs 2>&1
    if ($LASTEXITCODE -ne 0) { $errors.Add("create-pr: gh pr create failed (exit $LASTEXITCODE): $output") }

    # Emit pr-url so downstream processors (e.g. governance-ledger-pr-created) can record it
    $prUrlOut = if ($errors.Count -eq 0) { ($output | Select-Object -Last 1).Trim() } else { $null }

    @{
        success  = ($errors.Count -eq 0)
        context  = @{ 'pr-url' = $prUrlOut }
        error    = if ($errors.Count -gt 0) { $errors -join '; ' } else { $null }
        warnings = $warnings.ToArray()
    } | ConvertTo-Json -Depth 10
}

function Invoke-GovernanceRemediationCommit {
    <#
    .SYNOPSIS
    Creates a remediation branch, commits the generated ca-*-processor, and pushes.
    Provides remediation-branch in context for github-create-pr to use as pr-head.
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
        $errors.Add('governance-remediation-commit: bot-target-path config key not set')
        @{ success = $false; context = @{}; error = $errors -join '; '; warnings = $warnings.ToArray() } | ConvertTo-Json -Depth 10
        return
    }

    # Resolve the ca-processor-path and the generated rule id to derive the branch name
    $caProcessorPath = $ctx.'ca-processor-path'
    if ([string]::IsNullOrEmpty($caProcessorPath)) {
        $errors.Add('governance-remediation-commit: ca-processor-path not in context')
        @{ success = $false; context = @{}; error = $errors -join '; '; warnings = $warnings.ToArray() } | ConvertTo-Json -Depth 10
        return
    }

    # Derive branch name from the directory name of ca-processor-path
    # e.g. ".iarch/processors/ca-coupling-001" -> "iarch/remediation/ca-coupling-001"
    $processorDirName = Split-Path $caProcessorPath -Leaf
    $branchName       = "iarch/remediation/$processorDirName"

    if ($ciEnv -and $ciEnv.token) { $env:GH_TOKEN = $ciEnv.token }

    Push-Location $targetPath
    try {
        git config --local user.name  $botName
        git config --local user.email $botEmail

        # Create or reset the remediation branch from current HEAD
        git checkout -B $branchName 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            $errors.Add("governance-remediation-commit: git checkout -B $branchName failed (exit $LASTEXITCODE)")
            @{ success = $false; context = @{}; error = $errors -join '; '; warnings = $warnings.ToArray() } | ConvertTo-Json -Depth 10
            return
        }

        # Stage the ca-*-processor directory (relative to target-path)
        $absoluteTargetPath = (Resolve-Path $targetPath).Path
        $relPath = [System.IO.Path]::GetRelativePath($absoluteTargetPath, $caProcessorPath)
        git add -f $relPath 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            $errors.Add("governance-remediation-commit: failed to stage processor directory '$relPath' (exit $LASTEXITCODE)")
            @{ success = $false; context = @{}; error = $errors -join '; '; warnings = $warnings.ToArray() } | ConvertTo-Json -Depth 10
            return
        }

        # Stage healed source files produced by annotation-flush
        if ($healedFiles.Count -gt 0) {
            $stagedCount = 0
            foreach ($healedFile in $healedFiles) {
                $relHealedPath = [System.IO.Path]::GetRelativePath($absoluteTargetPath, $healedFile)
                git add -f $relHealedPath 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    $warnings.Add("governance-remediation-commit: failed to stage healed file '$relHealedPath' (exit $LASTEXITCODE)")
                } else {
                    $stagedCount++
                }
            }
            $warnings.Add("governance-remediation-commit: staged $stagedCount of $($healedFiles.Count) healed file(s)")
        }

        git diff --cached --quiet 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $warnings.Add('governance-remediation-commit: nothing staged to commit — processor may already be committed')
        } else {
            $healedCount = $healedFiles.Count
            $commitMsg   = if ($healedCount -gt 0) {
                "IArchitecture: add $processorDirName ca-*-processor + $healedCount healed file(s) (cluster-remediation)"
            } else {
                "IArchitecture: add $processorDirName ca-*-processor (cluster-remediation)"
            }
            git commit -m $commitMsg 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                $errors.Add("governance-remediation-commit: git commit failed (exit $LASTEXITCODE)")
            } else {
                git push --force-with-lease origin $branchName 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) { $errors.Add("governance-remediation-commit: git push failed (exit $LASTEXITCODE)") }
            }
        }
    } finally {
        # Return to default branch regardless of outcome
        git checkout - 2>&1 | Out-Null
        Pop-Location
    }

    @{
        success  = ($errors.Count -eq 0)
        context  = @{ 'remediation-branch' = if ($errors.Count -eq 0) { $branchName } else { $null } }
        error    = if ($errors.Count -gt 0) { $errors -join '; ' } else { $null }
        warnings = $warnings.ToArray()
    } | ConvertTo-Json -Depth 10
}

function Invoke-TriggerWorkflow {
    $payload      = [Console]::In.ReadToEnd() | ConvertFrom-Json -Depth 20
    $ctx          = $payload.context
    $cfg          = $payload.config
    $ciEnv        = $ctx.'ci-environment'

    $workflowFile   = $cfg.'trigger-workflow-file'
    $workflowRef    = $cfg.'trigger-workflow-ref'
    $workflowRepo   = $cfg.'trigger-workflow-repo'
    # Comma-separated "key=value" pairs to pass as --field inputs (single-trigger mode)
    $workflowFields = $cfg.'trigger-workflow-fields'

    $warnings = [System.Collections.Generic.List[string]]::new()
    $errors   = [System.Collections.Generic.List[string]]::new()

    if ([string]::IsNullOrEmpty($workflowFile)) {
        $errors.Add('trigger-workflow: trigger-workflow-file config key not set')
        @{ success = $false; context = @{}; error = $errors -join '; '; warnings = $warnings.ToArray() } | ConvertTo-Json -Depth 10
        return
    }

    if ($ciEnv -and $ciEnv.token) { $env:GH_TOKEN = $ciEnv.token }

    $baseArgs = @('workflow', 'run', $workflowFile)
    if ($workflowRepo) { $baseArgs += @('--repo', $workflowRepo) }
    if ($workflowRef)  { $baseArgs += @('--ref',  $workflowRef) }

    # Fan-out mode: trigger once per approved-proposal-id with --field proposal_id=<id>
    $approvedIds = if ($ctx.'approved-proposal-ids') { @($ctx.'approved-proposal-ids') } else { @() }

    if ($approvedIds.Count -gt 0) {
        foreach ($proposalId in $approvedIds) {
            $ghArgs = $baseArgs + @('--field', "proposal_id=$proposalId")
            $output = gh @ghArgs 2>&1
            if ($LASTEXITCODE -ne 0) {
                $errors.Add("trigger-workflow: gh workflow run failed for proposal $proposalId (exit $LASTEXITCODE): $output")
            } else {
                $warnings.Add("trigger-workflow: triggered $workflowFile for proposal $proposalId")
            }
        }
    } else {
        # Single-trigger mode (existing behavior + optional --field params)
        $ghArgs = $baseArgs
        if ($workflowFields) {
            $workflowFields -split ',' | ForEach-Object {
                $pair = $_.Trim()
                if ($pair) { $ghArgs += @('--field', $pair) }
            }
        }
        $output = gh @ghArgs 2>&1
        if ($LASTEXITCODE -ne 0) { $errors.Add("trigger-workflow: gh workflow run failed (exit $LASTEXITCODE): $output") }
        else { $warnings.Add("trigger-workflow: triggered $workflowFile") }
    }

    @{
        success  = ($errors.Count -eq 0)
        context  = @{}
        error    = if ($errors.Count -gt 0) { $errors -join '; ' } else { $null }
        warnings = $warnings.ToArray()
    } | ConvertTo-Json -Depth 10
}

function Invoke-GovernanceWorkflowDispatcher {
    <#
    .SYNOPSIS
    Reads approved-proposal-ids and promoted-proposal-ids from context and triggers
    the appropriate GitHub workflow for each via gh CLI.

    Job: know the governance routing (which list goes to which workflow).
    github-trigger-workflow stays dumb — this processor is the smart dispatcher.

    Config:
      cluster-remediation-workflow  — workflow file for approved proposals (default: iarchitecture-cluster-remediation.yml)
      governance-promote-workflow   — workflow file for promoted proposals  (default: iarchitecture-governance-promote.yml)
      trigger-workflow-ref          — git ref to run against               (default: main)
      trigger-workflow-repo         — optional repo override (owner/repo)
    #>
    $payload    = [Console]::In.ReadToEnd() | ConvertFrom-Json -Depth 20
    $ctx        = $payload.context
    $cfg        = $payload.config
    $ciEnv      = $ctx.'ci-environment'

    $remediationWorkflow = if ($cfg.'cluster-remediation-workflow') { $cfg.'cluster-remediation-workflow' } else { 'iarchitecture-cluster-remediation.yml' }
    $promoteWorkflow     = if ($cfg.'governance-promote-workflow')  { $cfg.'governance-promote-workflow'  } else { 'iarchitecture-governance-promote.yml'  }
    $workflowRef         = if ($cfg.'trigger-workflow-ref')         { $cfg.'trigger-workflow-ref'         } else { 'main' }
    $workflowRepo        = $cfg.'trigger-workflow-repo'

    $approvedIds = if ($ctx.'approved-proposal-ids') { @($ctx.'approved-proposal-ids') } else { @() }
    $promotedIds = if ($ctx.'promoted-proposal-ids') { @($ctx.'promoted-proposal-ids') } else { @() }

    $warnings = [System.Collections.Generic.List[string]]::new()
    $errors   = [System.Collections.Generic.List[string]]::new()

    if ($approvedIds.Count -eq 0 -and $promotedIds.Count -eq 0) {
        $warnings.Add('governance-workflow-dispatcher: no approved or promoted proposal IDs — nothing to trigger')
        @{ success = $true; context = @{}; error = $null; warnings = $warnings.ToArray() } | ConvertTo-Json -Depth 10
        return
    }

    if ($ciEnv -and $ciEnv.token) { $env:GH_TOKEN = $ciEnv.token }

    $baseArgs = @('workflow', 'run')
    if ($workflowRepo) { $baseArgs += @('--repo', $workflowRepo) }
    if ($workflowRef)  { $baseArgs += @('--ref',  $workflowRef) }

    # Build workspace lookup from ledger-state so cluster-remediation knows which spoke repo to target
    $ledgerState = if ($ctx.'ledger-state') { @($ctx.'ledger-state') } else { @() }
    $workspaceMap = @{}
    foreach ($le in $ledgerState) {
        if ($le.proposal_id) { $workspaceMap[$le.proposal_id] = $le.workspace_name }
    }

    foreach ($proposalId in $approvedIds) {
        $fields = @('--field', "proposal_id=$proposalId")
        $wn = $workspaceMap[$proposalId]
        if ($wn) { $fields += @('--field', "workspace_name=$wn") }
        $output = gh @($baseArgs + $remediationWorkflow + $fields) 2>&1
        if ($LASTEXITCODE -ne 0) { $errors.Add("governance-workflow-dispatcher: failed to trigger cluster-remediation for $proposalId (exit $LASTEXITCODE): $output") }
        else { $warnings.Add("governance-workflow-dispatcher: triggered $remediationWorkflow for proposal $proposalId") }
    }

    foreach ($proposalId in $promotedIds) {
        $fields = @('--field', "proposal_id=$proposalId")
        $wn = $workspaceMap[$proposalId]
        if ($wn) { $fields += @('--field', "workspace_name=$wn") }
        $output = gh @($baseArgs + $promoteWorkflow + $fields) 2>&1
        if ($LASTEXITCODE -ne 0) { $errors.Add("governance-workflow-dispatcher: failed to trigger governance-promote for $proposalId (exit $LASTEXITCODE): $output") }
        else { $warnings.Add("governance-workflow-dispatcher: triggered $promoteWorkflow for proposal $proposalId") }
    }

    @{
        success  = ($errors.Count -eq 0)
        context  = @{}
        error    = if ($errors.Count -gt 0) { $errors -join '; ' } else { $null }
        warnings = $warnings.ToArray()
    } | ConvertTo-Json -Depth 10
}

function Invoke-CreateIssue {
    $payload     = [Console]::In.ReadToEnd() | ConvertFrom-Json -Depth 20
    $ctx         = $payload.context
    $cfg         = $payload.config
    $ciEnv       = $ctx.'ci-environment'

    $violations  = if ($ctx.violations) { @($ctx.violations) } else { @() }
    $issueTitle  = $cfg.'issue-title'
    $issueLabels = $cfg.'issue-labels'
    $issueBody   = $cfg.'issue-body'

    $warnings = [System.Collections.Generic.List[string]]::new()
    $errors   = [System.Collections.Generic.List[string]]::new()

    if ([string]::IsNullOrEmpty($issueTitle)) {
        $errors.Add('create-issue: issue-title config key not set')
        @{ success = $false; context = @{}; error = $errors -join '; '; warnings = $warnings.ToArray() } | ConvertTo-Json -Depth 10
        return
    }

    if ($ciEnv -and $ciEnv.token) { $env:GH_TOKEN = $ciEnv.token }

    if ([string]::IsNullOrEmpty($issueBody)) {
        $issueBody = Format-IssueBody $violations $ciEnv
    }

    $repository = if ($ciEnv -and $ciEnv.repository) { $ciEnv.repository } else { $env:GITHUB_REPOSITORY }
    $ghArgs     = @('issue', 'create', '--title', $issueTitle, '--body', $issueBody)
    if ($issueLabels)  { $ghArgs += @('--label', $issueLabels) }
    if ($repository)   { $ghArgs += @('--repo',  $repository) }

    $output = gh @ghArgs 2>&1
    if ($LASTEXITCODE -ne 0) { $errors.Add("create-issue: gh issue create failed (exit $LASTEXITCODE): $output") }

    @{
        success  = ($errors.Count -eq 0)
        context  = @{}
        error    = if ($errors.Count -gt 0) { $errors -join '; ' } else { $null }
        warnings = $warnings.ToArray()
    } | ConvertTo-Json -Depth 10
}

function Invoke-CreateCommitComment {
    $payload    = [Console]::In.ReadToEnd() | ConvertFrom-Json -Depth 20
    $ctx        = $payload.context
    $cfg        = $payload.config
    $ciEnv      = $ctx.'ci-environment'

    $violations = if ($ctx.violations) { @($ctx.violations) } else { @() }
    $commentSha = if ($cfg.'comment-sha') { $cfg.'comment-sha' } elseif ($ciEnv -and $ciEnv.sha) { $ciEnv.sha } else { $null }

    $warnings = [System.Collections.Generic.List[string]]::new()
    $errors   = [System.Collections.Generic.List[string]]::new()

    if ([string]::IsNullOrEmpty($commentSha)) {
        $errors.Add('create-commit-comment: no SHA available — set comment-sha config or ensure ci-environment contains sha')
        @{ success = $false; context = @{}; error = $errors -join '; '; warnings = $warnings.ToArray() } | ConvertTo-Json -Depth 10
        return
    }

    if ($ciEnv -and $ciEnv.token) { $env:GH_TOKEN = $ciEnv.token }

    $repository     = if ($ciEnv -and $ciEnv.repository) { $ciEnv.repository } else { $env:GITHUB_REPOSITORY }
    $violationCount = $violations.Count
    $errorCount     = @($violations | Where-Object { $_.severity -in @('Error', 'Fatal') }).Count
    $warningCount   = @($violations | Where-Object { $_.severity -eq 'Warning' }).Count
    $body           = Format-CommitCommentBody $violations $violationCount $errorCount $warningCount

    $output = gh api "repos/$repository/commits/$commentSha/comments" `
        --method POST `
        -f "body=$body" 2>&1
    if ($LASTEXITCODE -ne 0) { $errors.Add("create-commit-comment: gh api failed (exit $LASTEXITCODE): $output") }

    @{
        success  = ($errors.Count -eq 0)
        context  = @{}
        error    = if ($errors.Count -gt 0) { $errors -join '; ' } else { $null }
        warnings = $warnings.ToArray()
    } | ConvertTo-Json -Depth 10
}

function Format-ViolationComment {
    param([array]$Violations, [int]$Total, [int]$Errors, [int]$Warnings)

    if ($Total -eq 0) {
        return "## IArchitecture Analysis`n`nNo architectural violations detected."
    }

    $lines = @(
        '## IArchitecture Analysis',
        '',
        "**$Total violation(s) detected**  -  $Errors error(s), $Warnings warning(s)",
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

function Format-CheckSummary {
    param([array]$Violations, [int]$Total, [int]$Errors, [int]$Warnings)

    if ($Total -eq 0) { return 'No architectural violations detected.' }

    $lines = @(
        "**$Total violation(s)**  -  $Errors error(s), $Warnings warning(s)",
        ''
    )

    $Violations | Group-Object -Property name | Sort-Object Count -Descending | Select-Object -First 10 | ForEach-Object {
        $lines += "- **$($_.Name)**: $($_.Count) occurrence(s)"
    }

    $lines -join "`n"
}

function Format-IssueBody {
    param([array]$Violations, $WfCtx)

    $violationCount = $Violations.Count
    $errorCount     = @($Violations | Where-Object { $_.severity -in @('Error', 'Fatal') }).Count
    $warningCount   = @($Violations | Where-Object { $_.severity -eq 'Warning' }).Count

    $lines = @(
        '## IArchitecture Violations Detected',
        '',
        "**Total violations:** $violationCount ($errorCount fatal, $warningCount warning)",
        ''
    )

    if ($WfCtx -and $WfCtx.sha) {
        $short = if ($WfCtx.sha.Length -ge 7) { $WfCtx.sha.Substring(0,7) } else { $WfCtx.sha }
        $lines += "**Commit:** $short"
        $lines += ''
    }

    if ($Violations.Count -gt 0) {
        $lines += '### Top Violations'
        $lines += ''
        $Violations | Select-Object -First 10 | ForEach-Object {
            $file = if ($_.file_path) { [System.IO.Path]::GetFileName($_.file_path) } else { 'unknown' }
            $line = if ($_.line_number) { ":$($_.line_number)" } else { '' }
            $lines += "- **$($_.severity)** in ``$file$line`` — $($_.name)"
        }
        if ($Violations.Count -gt 10) {
            $lines += ''
            $lines += "...and $($Violations.Count - 10) more violations"
        }
    }

    $lines += ''
    $lines += '*Generated by IArchitecture*'
    $lines -join "`n"
}

function Format-CommitCommentBody {
    param([array]$Violations, [int]$Total, [int]$Errors, [int]$Warnings)

    $lines = @(
        '## IArchitecture Violations Detected',
        '',
        "**Total:** $Total violations | **Fatal:** $Errors | **Warning:** $Warnings"
    )

    if ($Violations.Count -gt 0) {
        $lines += ''
        $Violations | Select-Object -First 5 | ForEach-Object {
            $file = if ($_.file_path) { [System.IO.Path]::GetFileName($_.file_path) } else { 'unknown' }
            $line = if ($_.line_number) { ":$($_.line_number)" } else { '' }
            $lines += "- **$($_.severity)**: ``$file$line`` — $($_.name)"
        }
        if ($Total -gt 5) {
            $lines += ''
            $lines += "...and $($Total - 5) more violations"
        }
    }

    $lines += ''
    $lines += '*Generated by IArchitecture*'
    $lines -join "`n"
}
