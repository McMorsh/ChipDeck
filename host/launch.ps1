# Start the overlay host hidden. Features are discovered from ../features;
# the DSH agents feature starts its own bridge on first selection.
#
# Optional first argument selects the initial feature id, e.g.:
#   chipdeck zapret

param([string]$Feature = '')

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $PSCommandPath
$hostScript = Join-Path $here 'chipdeck.ps1'

if ($Feature -ne '') { $env:DSH_OVERLAY_FEATURE = $Feature }

Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
  -ArgumentList @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $hostScript) `
  -WorkingDirectory $here -WindowStyle Hidden
