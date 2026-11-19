#requires -Version 5.1
<#
    Allow the interactive user to start and stop the zapret service from the
    tray menu without an elevation prompt.

    The grant is limited to query + start/stop/pause: the ACE keeps no
    SERVICE_CHANGE_CONFIG, so a non-admin cannot repoint the service binary.
    Run once, elevated.
#>

$ErrorActionPreference = 'Stop'
$log = Join-Path $PSScriptRoot 'grant-service-control.log'
function Log([string]$message) {
  $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $message
  Write-Host $line
  Add-Content -LiteralPath $log -Value $line -Encoding UTF8
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Log ("elevated: {0}" -f $isAdmin)
if (-not $isAdmin) { Log 'ERROR: run elevated'; exit 2 }

$sddl = (& sc.exe sdshow zapret 2>&1) -join ''
if ($LASTEXITCODE -ne 0 -or $sddl -notmatch '^D:') { Log ("ERROR: cannot read zapret SDDL: {0}" -f $sddl); exit 1 }
Log ('before: ' + $sddl)

$current = '(A;;CCLCSWLOCRRC;;;IU)'
$granted = '(A;;CCLCSWRPWPDTLOCRRC;;;IU)'
if ($sddl.Contains($granted)) {
  Log 'IU already has start/stop rights; nothing to change'
  exit 0
}
if (-not $sddl.Contains($current)) {
  Log 'ERROR: unexpected IU ACE, refusing to rewrite the ACL'
  exit 1
}
$next = $sddl.Replace($current, $granted)
$result = (& sc.exe sdset zapret $next 2>&1) -join ' '
Log ('sdset: ' + $result)
if ($LASTEXITCODE -ne 0) { Log 'ERROR: sdset failed'; exit 1 }

$after = (& sc.exe sdshow zapret 2>&1) -join ''
Log ('after: ' + $after)
if ($after.Contains($granted)) { Log 'DONE'; exit 0 }
Log 'ERROR: grant not visible after sdset'
exit 1
