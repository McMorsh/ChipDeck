#requires -Version 5.1
<#
    DSH agents feature for the overlay host.

    Loaded as a PowerShell module by the host: the file defines Initialize-,
    Enter-, Update- and Dispose-Feature, each receiving the host API. Renders
    the model the DSH page pushes through bridge.js — running sessions and
    pending approvals — and starts that bridge lazily in this feature's runtime
    directory, so the host itself knows nothing about DSH.

    Contract: docs/FEATURES.md.
#>

param($Api, $FeatureDir)

$script:Api = $Api
$script:FeatureDir = $FeatureDir
$script:Dir = $Api.RuntimeDir
$script:StatePath = Join-Path $script:Dir 'state.json'
$script:CommandsPath = Join-Path $script:Dir 'commands.json'
$script:Origin = 'http://127.0.0.1:3080'
$script:LastStateText = ''
$script:LastStateTime = [datetime]::MinValue
$script:BridgeChecked = $false
$script:BridgeConflict = $false

New-Item -ItemType Directory -Path $script:Dir -Force | Out-Null

function Write-JsonFile([string]$path, [string]$text) {
  $temporary = "$path.tmp"
  [System.IO.File]::WriteAllText($temporary, $text, (New-Object System.Text.UTF8Encoding($false)))
  Move-Item -LiteralPath $temporary -Destination $path -Force
}

function Add-PageCommand([hashtable]$command) {
  $list = @()
  if (Test-Path -LiteralPath $script:CommandsPath) {
    try { $list = @([System.IO.File]::ReadAllText($script:CommandsPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json) } catch { $list = @() }
  }
  $list += [pscustomobject]$command
  Write-JsonFile $script:CommandsPath (ConvertTo-Json -InputObject @($list) -Depth 5 -Compress)
}

function Test-Bridge {
  try {
    $health = Invoke-RestMethod -Uri 'http://127.0.0.1:5199/health' -TimeoutSec 1
    if ($health.ok -ne $true) { return $null }
    return $health
  } catch { return $null }
}

function Start-Bridge {
  $health = Test-Bridge
  if ($null -ne $health) {
    if ([string]$health.dir -ne $script:Dir) { $script:BridgeConflict = $true }
    return
  }
  $node = Get-Command node -ErrorAction SilentlyContinue
  if ($null -eq $node) { return }
  $bridge = Join-Path $script:FeatureDir 'bridge.js'
  if (-not (Test-Path -LiteralPath $bridge)) { return }
  $previous = $env:CHIPDECK_DIR
  $env:CHIPDECK_DIR = $script:Dir
  try { Start-Process -FilePath $node.Source -ArgumentList @($bridge) -WorkingDirectory $script:FeatureDir -WindowStyle Hidden } catch { }
  finally { $env:CHIPDECK_DIR = $previous }
}

function Get-State {
  if (-not (Test-Path -LiteralPath $script:StatePath)) { return $null }
  try { return [System.IO.File]::ReadAllText($script:StatePath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json } catch { return $null }
}

function Get-Origin {
  if ([string]::IsNullOrWhiteSpace($script:Origin)) { return 'http://127.0.0.1:3080' }
  return $script:Origin
}

function Update-Footer {
  if ($script:BridgeConflict) {
    & $script:Api.SetFooter 'Мост занят старым экземпляром ChipDeck - выйди из него в трее'
    return
  }
  $fresh = $false
  if (Test-Path -LiteralPath $script:StatePath) {
    $fresh = ((Get-Date) - (Get-Item -LiteralPath $script:StatePath).LastWriteTime).TotalSeconds -lt 8
  }
  & $script:Api.SetFooter $(if ($fresh) { 'DSH подключён' } else { 'Нет связи с DSH' })
}

function Render {
  $api = $script:Api
  $state = Get-State
  $waiting = @()
  $running = @()
  if ($null -ne $state) {
    $waiting = @($state.waiting)
    $running = @($state.running)
    if ($null -ne $state.origin -and [string]$state.origin -ne '') { $script:Origin = [string]$state.origin }
  }

  & $api.Clear
  & $api.SetSummary ('работают: {0} · ждут: {1}' -f $running.Count, $waiting.Count)

  if ($waiting.Count -eq 0 -and $running.Count -eq 0) {
    $empty = New-Object System.Windows.Controls.TextBlock
    $empty.Style = & $api.GetResource 'MutedText'
    $empty.Text = 'Сейчас никто не работает и подтверждать нечего.'
    $empty.TextAlignment = 'Center'
    $empty.Margin = New-Object System.Windows.Thickness(8, 22, 8, 22)
    $empty.TextWrapping = 'Wrap'
    $api.Panel.Children.Add($empty) | Out-Null
  }

  if ($waiting.Count -gt 0) {
    $api.Panel.Children.Add((& $api.NewSection 'ТРЕБУЮТ ПОДТВЕРЖДЕНИЯ')) | Out-Null
    foreach ($item in $waiting) {
      $meta = 'Инструмент: {0}' -f $item.tool
      if ($null -ne $item.reason -and $item.reason -ne '') { $meta = $meta + "`n" + $item.reason }
      $key = [string]$item.key
      $answerable = [bool]$item.answerable
      $allow = & $api.NewButton 'AllowButton' 'Разрешить' {
        Add-PageCommand @{ type = 'answer'; key = $key; decision = 'allowed-once' }
      }.GetNewClosure()
      $reject = & $api.NewButton 'RejectButton' 'Отклонить' {
        Add-PageCommand @{ type = 'answer'; key = $key; decision = 'rejected' }
      }.GetNewClosure()
      $allow.IsEnabled = $answerable
      $reject.IsEnabled = $answerable
      $api.Panel.Children.Add((& $api.NewRow 'warn' ([string]$item.title) $meta @($allow, $reject))) | Out-Null
    }
  }

  if ($running.Count -gt 0) {
    $api.Panel.Children.Add((& $api.NewSection 'РАБОТАЮТ')) | Out-Null
    foreach ($item in $running) {
      $sessionId = [string]$item.sessionId
      $open = & $api.NewButton 'GhostButton' 'Открыть' {
        Add-PageCommand @{ type = 'open'; sessionId = $sessionId }
      }.GetNewClosure()
      $api.Panel.Children.Add((& $api.NewRow 'run' ([string]$item.title) 'агент выполняется' @($open))) | Out-Null
    }
  }

  $browser = & $api.NewFullButton 'PillButton' '🌐 Открыть DSH в браузере' {
    Start-Process (Get-Origin)
  }.GetNewClosure()
  $api.Panel.Children.Add($browser) | Out-Null

  Update-Footer
}

function Initialize-Feature {
  param($Api)
  $script:Api = $Api
  Start-Bridge
  $script:BridgeChecked = $true
  & $Api.AddTrayItem 'Открыть DSH' { Start-Process (Get-Origin) }
}

function Enter-Feature {
  param($Api)
  $script:Api = $Api
  $script:LastStateText = ''
  $script:LastStateTime = [datetime]::MinValue
  Render
}

function Update-Feature {
  param($Api)
  if (-not $script:BridgeChecked) { $script:BridgeChecked = $true; Start-Bridge }
  if (Test-Path -LiteralPath $script:StatePath) {
    $file = Get-Item -LiteralPath $script:StatePath
    if ($file.LastWriteTime -gt $script:LastStateTime) {
      $script:LastStateTime = $file.LastWriteTime
      $text = [System.IO.File]::ReadAllText($script:StatePath, [System.Text.Encoding]::UTF8)
      if ($text -ne $script:LastStateText) {
        $script:LastStateText = $text
        Render
        return
      }
    }
  }
  Update-Footer
}

function Dispose-Feature {
  param($Api)
  try { Invoke-RestMethod -Method Post -Uri 'http://127.0.0.1:5199/shutdown' -TimeoutSec 1 | Out-Null } catch { }
}
