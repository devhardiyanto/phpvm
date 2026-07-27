# ==============================================================================
#  phpvm.ps1 - PHP Version Manager for Windows
#  Compatible with: CMD (via phpvm.cmd shim) and PowerShell
#  Repo: https://github.com/devhardiyanto/phpvm
# ==============================================================================

param(
    [Parameter(Position = 0)] [string]$Command  = "",
    [Parameter(Position = 1)] [string]$SubOrVer = "",
    [Parameter(Position = 2)] [string]$Arg2     = "",
    [Parameter(Position = 3)] [string]$Arg3     = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -- Constants -----------------------------------------------------------------
$PHPVM_VERSION = "1.13.2"
$PHPVM_DIR     = if ($env:PHPVM_DIR) { $env:PHPVM_DIR } else { "$env:USERPROFILE\.phpvm" }
$VERSIONS_DIR  = "$PHPVM_DIR\versions"
$CURRENT_LINK  = "$PHPVM_DIR\current"
$PHPVM_BIN     = "$PHPVM_DIR\bin"
$PHPVM_CACERT  = "$PHPVM_DIR\cacert.pem"
$PHPVM_CACERT_URL = "https://curl.se/ca/cacert.pem"

# -- Update checker (hourly, via version.txt) ---------------------------------
$PHPVM_UPDATE_URL   = "https://raw.githubusercontent.com/devhardiyanto/phpvm/main/version.txt"
$PHPVM_LAST_CHECK   = "$PHPVM_DIR\.last_update_check"
$PHPVM_CHECK_INTERVAL = 3600  # 1 hour in seconds
