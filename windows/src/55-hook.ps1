# Manage the $PROFILE snippet that runs `phpvm auto -Silent` on each prompt.
$script:PHPVM_HOOK_MARKER = '# phpvm-auto-hook (managed by `phpvm hook`)'

function Get-PHPVMHookSnippet {
    @"

$($script:PHPVM_HOOK_MARKER)
if (Get-Command phpvm -ErrorAction SilentlyContinue) {
    `$global:__phpvm_prev_prompt = `$function:prompt
    function global:prompt {
        try { phpvm auto -Silent } catch {}
        if (`$global:__phpvm_prev_prompt) { & `$global:__phpvm_prev_prompt }
        else { "PS `$(`$ExecutionContext.SessionState.Path.CurrentLocation)`$('>' * (`$nestedPromptLevel + 1)) " }
    }
}
"@
}

function Install-PHPVMHook {
    $profilePath = $PROFILE.CurrentUserCurrentHost
    if (-not (Test-Path $profilePath)) {
        New-Item -ItemType File -Path $profilePath -Force | Out-Null
    }
    $existing = Get-Content $profilePath -Raw -ErrorAction SilentlyContinue
    if ($existing -and $existing.Contains($script:PHPVM_HOOK_MARKER)) {
        Write-Warn "phpvm hook already installed in $profilePath"
        return
    }
    Add-Content -Path $profilePath -Value (Get-PHPVMHookSnippet)
    Write-Ok "Installed hook -> $profilePath"
    Write-Dim "Open a new PowerShell window to activate."
}

function Uninstall-PHPVMHook {
    $profilePath = $PROFILE.CurrentUserCurrentHost
    if (-not (Test-Path $profilePath)) {
        Write-Warn "No `$PROFILE found at $profilePath"
        return
    }
    $content = Get-Content $profilePath -Raw
    if (-not $content.Contains($script:PHPVM_HOOK_MARKER)) {
        Write-Warn "phpvm hook not found in $profilePath"
        return
    }
    # Strip from marker to the matching closing brace of the `if` block.
    $pattern = "(?ms)\r?\n?" + [regex]::Escape($script:PHPVM_HOOK_MARKER) + ".*?^\}\s*"
    $cleaned = [regex]::Replace($content, $pattern, '')
    Set-Content -Path $profilePath -Value $cleaned -NoNewline
    Write-Ok "Removed hook from $profilePath"
    Write-Dim "Open a new PowerShell window for the change to take effect."
}

function Show-PHPVMHookStatus {
    $profilePath = $PROFILE.CurrentUserCurrentHost
    if (-not (Test-Path $profilePath)) {
        Write-Dim "No `$PROFILE at $profilePath - hook not installed."
        return
    }
    $content = Get-Content $profilePath -Raw -ErrorAction SilentlyContinue
    if ($content -and $content.Contains($script:PHPVM_HOOK_MARKER)) {
        Write-Ok "Hook installed in $profilePath"
    } else {
        Write-Dim "Hook not installed. Run: phpvm hook enable"
    }
}

function Invoke-Hook ([string]$sub) {
    switch ($sub.ToLower()) {
        'enable'    { Install-PHPVMHook }
        'disable'   { Uninstall-PHPVMHook }
        'status'    { Show-PHPVMHookStatus }
        default     {
            Write-Host ""
            Write-Host "  phpvm hook - manage the PowerShell auto-switch hook" -ForegroundColor Cyan
            Write-Host "    phpvm hook enable     Enable .phpvmrc auto-switching (prompt hook in `$PROFILE)"
            Write-Host "    phpvm hook disable    Disable the hook"
            Write-Host "    phpvm hook status     Check whether the hook is enabled"
            Write-Host ""
        }
    }
}
