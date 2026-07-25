function Show-Help {
    Write-Host @"

  phpvm $PHPVM_VERSION - PHP Version Manager for Windows
  ---------------------------------------------------------

  VERSION MANAGEMENT
    phpvm install   <version>      Download & install a PHP version
                                     --no-use     install without switching to it
                                     --no-cacert  skip CA bundle configuration
    phpvm use       <version>      Switch the active PHP version
    phpvm list                     List installed versions
    phpvm current                  Show active version info
    phpvm uninstall <version>      Remove a PHP version
    phpvm which                    Path to active php.exe
    phpvm ini                      Open active php.ini in Notepad
    phpvm fix-ini                  Sync extension_dir & CA bundle in active php.ini
    phpvm cacert [status|update]   Manage the shared CA bundle (HTTPS/TLS)
    phpvm doctor                   Diagnose PATH, ext_dir, CA bundle, VC++ runtime

  COMPOSER / WP-CLI
    phpvm composer                 Install Composer for active PHP version
    phpvm wp-cli                   Install WP-CLI (global 'wp' command)

  AUTO-SWITCH (.phpvmrc)
    phpvm auto                     Switch to the version named in .phpvmrc
    phpvm hook enable              Enable auto-switching (PowerShell prompt hook)
    phpvm hook disable             Disable the hook
    phpvm hook status              Check whether the hook is enabled

  SELF UPDATE
    phpvm upgrade                  Upgrade phpvm to latest version
    phpvm version                  Show current phpvm version

  LARAVEL QUICK SETUP
    phpvm ext laravel              Enable all Laravel extensions (full)
    phpvm ext laravel minimal      Required extensions only
    phpvm ext laravel full         Required + recommended + Redis

  EXTENSION MANAGEMENT
    phpvm ext list                 Show all bundled extensions
    phpvm ext enable  <name>       Enable a bundled extension
    phpvm ext install <name>       Install from PECL / xdebug.org
    phpvm ext help                 Full extension reference (list, loaded,
                                     disable, info, laravel, examples)

  EXAMPLES
    phpvm install 8.3.0
    phpvm install 8.1.29
    phpvm use 8.3.0
    phpvm ext enable mbstring
    phpvm ext enable pdo_mysql
    phpvm ext install redis
    phpvm ext install xdebug

  Home: $PHPVM_DIR

"@ -ForegroundColor Cyan
}

# -- Did-you-mean (unknown command handling) -----------------------------------
# Iterative Levenshtein distance (two-row, O(n) memory).
function Get-Levenshtein ([string]$a, [string]$b) {
    $la = $a.Length; $lb = $b.Length
    if ($la -eq 0) { return $lb }
    if ($lb -eq 0) { return $la }
    $row = 0..$lb
    for ($i = 1; $i -le $la; $i++) {
        $prev = $row[0]
        $row[0] = $i
        for ($j = 1; $j -le $lb; $j++) {
            $cur  = $row[$j]
            $cost = if ($a[$i - 1] -eq $b[$j - 1]) { 0 } else { 1 }
            $del  = $row[$j] + 1
            $ins  = $row[$j - 1] + 1
            $sub  = $prev + $cost
            $row[$j] = [Math]::Min([Math]::Min($del, $ins), $sub)
            $prev = $cur
        }
    }
    return $row[$lb]
}

# Unknown command: suggest the nearest match instead of dumping the full help.
function Invoke-Unknown ([string]$cmd) {
    $cmds = @("install","use","list","ls","current","uninstall","remove",
              "which","ini","fix-ini","cacert","doctor","ext","composer","wp-cli","auto","hook",
              "upgrade","update","version","help")
    $best = ""; $bestd = 99
    foreach ($c in $cmds) {
        $d = Get-Levenshtein $cmd.ToLower() $c
        if ($d -lt $bestd) { $bestd = $d; $best = $c }
    }
    Write-Err "'$cmd' is not a phpvm command."
    if ($bestd -le 2) { Write-Dim "Did you mean '$best'?" }
    Write-Dim "Run 'phpvm help' to see all commands."
}
