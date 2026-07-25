# Tests dot-source this file and set $env:PHPVM_NO_ENTRY=1 to skip the entry point.
if (-not $env:PHPVM_NO_ENTRY) {
    Initialize-PHPVM

    $skipUpdateFor = @("", "help", "--help", "version", "-v", "list", "ls", "current", "which", "ini", "auto", "hook")
    if ($Command.ToLower() -notin $skipUpdateFor) {
        Check-PHPVMUpdate
    }

    switch ($Command.ToLower()) {
        "install"                       { Invoke-Install   $SubOrVer $Arg2 }
        "use"                           { Invoke-Use       $SubOrVer }
        { $_ -in "list", "ls" }         { Invoke-List }
        "current"                       { Invoke-Current }
        { $_ -in "uninstall", "remove" }{ Invoke-Uninstall $SubOrVer }
        "which"                         { Invoke-Which }
        "ini"                           { Invoke-Ini }
        "fix-ini"                       { Invoke-FixIni }
        "cacert"                        { Invoke-Cacert  $SubOrVer }
        "doctor"                        { Invoke-Doctor }
        "ext"                           { Invoke-Ext $SubOrVer $Arg2 $Arg3 }
        "auto"                          { Invoke-Auto }
        "hook"                          { Invoke-Hook $SubOrVer }
        "composer"                      { Invoke-Composer }
        "wp-cli"                        { Invoke-WpCli }
        { $_ -in "upgrade", "update" }  { Invoke-Upgrade }
        { $_ -in "version", "-v" }      { Write-Ok "phpvm $PHPVM_VERSION" }
        { $_ -in "help", "--help" }     { Show-Help }
        ""                              { Show-Help }
        default                         { Invoke-Unknown $Command }
    }
}
