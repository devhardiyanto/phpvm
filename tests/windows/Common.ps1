# Shared bootstrap for Pester tests against windows/phpvm.ps1.
# Call from inside a BeforeAll block - Pester 5 isolates scope per Describe.

$env:PHPVM_NO_ENTRY        = '1'
$env:PHPVM_NO_UPDATE_CHECK = '1'

$ScriptUnderTest = (Resolve-Path (Join-Path $PSScriptRoot '..\..\windows\phpvm.ps1')).Path

. $ScriptUnderTest -Command '' -SubOrVer '' -Arg2 ''
