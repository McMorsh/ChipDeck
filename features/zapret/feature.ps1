#requires -Version 5.1
<#
    Zapret feature for the overlay host.

    Loaded as a PowerShell module by the host: the file defines Initialize-,
    Enter-, Update- and Dispose-Feature, each receiving the host API.

    Unlike a `service` feature this one does not depend on the Windows service
    already existing. It finds the zapret distribution on disk, reports whether
    the service or a bare winws.exe is running, and offers the missing step:
    installing the service through the distribution's own service.bat (elevated).

    Lookup order for the folder: saved path in the runtime directory, the
    service ImagePath, then zapret* directories in the usual places. Anything
    that does not contain bin\winws.exe is ignored.

    Contract: docs/FEATURES.md.
#>

param($Api, $FeatureDir)

$script:Api = $Api
$script:FeatureDir = $FeatureDir
$script:Dir = $Api.RuntimeDir
$script:PathFile = Join-Path $script:Dir 'zapret-path.txt'
$script:ServiceName = if ([string]::IsNullOrWhiteSpace([string]$Api.Feature.Service)) { 'zapret' } else { [string]$Api.Feature.Service }
$script:Folder = $null
$script:LastScan = [datetime]::MinValue
$script:LastPoll = [datetime]::MinValue
$script:LastRender = ''

New-Item -ItemType Directory -Path $script:Dir -Force | Out-Null

# ---------------------------------------------------------------- discovery

function Test-ZapretDir([string]$dir) {
  if ([string]::IsNullOrWhiteSpace($dir)) { return $false }
  try {
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return $false }
    if (Test-Path -LiteralPath (Join-Path $dir 'bin\winws.exe')) { return $true }
    if (Test-Path -LiteralPath (Join-Path $dir 'winws.exe')) { return $true }
  } catch { }
  return $false
}

function Get-SavedPath {
  try {
    if (Test-Path -LiteralPath $script:PathFile) {
      $value = [System.IO.File]::ReadAllText($script:PathFile, [System.Text.Encoding]::UTF8).Trim()
      if (Test-ZapretDir $value) { return $value }
    }
  } catch { }
  return $null
}

function Save-Path([string]$dir) {
  try {
    [System.IO.File]::WriteAllText($script:PathFile, $dir, (New-Object System.Text.UTF8Encoding($false)))
  } catch { }
}

function Get-ServiceImageRoot {
  $key = 'HKLM:\SYSTEM\CurrentControlSet\Services\' + $script:ServiceName
  try { $image = [string](Get-ItemProperty -LiteralPath $key -ErrorAction Stop).ImagePath } catch { return $null }
  if ([string]::IsNullOrWhiteSpace($image)) { return $null }
  if ($image -match '^"([^"]+)"') { $exe = $Matches[1] }
  elseif ($image -match '^(\S+\.exe)') { $exe = $Matches[1] }
  else { return $null }
  $exe = [System.Environment]::ExpandEnvironmentVariables($exe)
  $parent = Split-Path -Parent $exe
  if ($parent -eq '') { return $null }
  $root = $(if ((Split-Path -Leaf $parent) -eq 'bin') { Split-Path -Parent $parent } else { $parent })
  if (Test-ZapretDir $root) { return $root }
  if (Test-ZapretDir $parent) { return $parent }
  return $null
}

function Find-ZapretFolder {
  $saved = Get-SavedPath
  if ($null -ne $saved) { return $saved }

  $fromService = Get-ServiceImageRoot
  if ($null -ne $fromService) { return $fromService }

  foreach ($exact in @('C:\zapret', 'D:\zapret', (Join-Path $env:USERPROFILE 'zapret'))) {
    if (Test-ZapretDir $exact) { return $exact }
  }

  $roots = @(
    'C:\',
    'D:\',
    (Join-Path $env:USERPROFILE 'Downloads'),
    (Join-Path $env:USERPROFILE 'Desktop'),
    (Join-Path $env:USERPROFILE 'Documents'),
    $env:USERPROFILE,
    (Join-Path $env:LOCALAPPDATA 'Programs')
  )
  foreach ($root in $roots) {
    if ([string]::IsNullOrWhiteSpace($root)) { continue }
    try {
      if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
      foreach ($dir in @(Get-ChildItem -LiteralPath $root -Directory -Filter 'zapret*' -ErrorAction SilentlyContinue)) {
        if (Test-ZapretDir $dir.FullName) { return $dir.FullName }
        foreach ($nested in @(Get-ChildItem -LiteralPath $dir.FullName -Directory -Filter 'zapret*' -ErrorAction SilentlyContinue)) {
          if (Test-ZapretDir $nested.FullName) { return $nested.FullName }
        }
      }
    } catch { }
  }
  return $null
}

function Get-FolderCached([bool]$force) {
  if ($null -ne $script:Folder -and (Test-ZapretDir $script:Folder)) { return $script:Folder }
  $now = Get-Date
  if (-not $force -and ($now - $script:LastScan).TotalSeconds -lt 5) { return $script:Folder }
  $script:LastScan = $now
  $found = Find-ZapretFolder
  if ($null -ne $found) {
    $script:Folder = $found
    Save-Path $found
  } else {
    $script:Folder = $null
  }
  return $script:Folder
}

# ---------------------------------------------------------------- state

function Get-ZapretState {
  $service = $null
  try { $service = Get-Service -Name $script:ServiceName -ErrorAction SilentlyContinue } catch { $service = $null }

  $status = 'Missing'
  $startType = 'Unknown'
  $strategy = ''
  $imageOk = $true
  if ($null -ne $service) {
    $status = [string]$service.Status
    $key = 'HKLM:\SYSTEM\CurrentControlSet\Services\' + $script:ServiceName
    try {
      $properties = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
      $value = [int]$properties.Start
      $startType = $(switch ($value) {
        0 { 'Boot' }
        1 { 'System' }
        2 { 'Automatic' }
        3 { 'Manual' }
        4 { 'Disabled' }
        default { 'Unknown' }
      })
      $strategy = [string]$properties.'zapret-discord-youtube'
      # A moved distribution leaves the service pointing at a missing exe.
      $imageOk = $false
      $imagePath = [string]$properties.ImagePath
      if ($imagePath -match '^"([^"]+)"') { $exe = $Matches[1] }
      elseif ($imagePath -match '^(\S+\.exe)') { $exe = $Matches[1] }
      else { $exe = '' }
      if ($exe -ne '' -and (Test-Path -LiteralPath ([System.Environment]::ExpandEnvironmentVariables($exe)))) { $imageOk = $true }
    } catch {
      try { $startType = [string]$service.StartType } catch { }
    }
  }

  $processCount = 0
  $processId = 0
  try {
    $processes = @(Get-Process -Name 'winws' -ErrorAction SilentlyContinue)
    $processCount = $processes.Count
    if ($processCount -gt 0) { $processId = [int]$processes[0].Id }
  } catch { }

  return [pscustomobject]@{
    Status = $status
    StartType = $startType
    Strategy = $strategy
    ProcessCount = $processCount
    ProcessId = $processId
    Folder = Get-FolderCached $false
    ImagePathValid = $imageOk
  }
}

function Get-Signature {
  $state = Get-ZapretState
  return ('{0}|{1}|{2}|{3}|{4}|{5}|{6}' -f $state.Status, $state.StartType, $state.Strategy, $state.Folder, $state.ProcessCount, $state.ProcessId, $state.ImagePathValid)
}

# ---------------------------------------------------------------- actions

function Open-ZapretFolder {
  $folder = Get-FolderCached $true
  if ($null -eq $folder) { & $script:Api.ShowBalloon 'Zapret' 'Папка zapret не найдена'; return }
  Start-Process -FilePath explorer.exe -ArgumentList ('"' + $folder + '"')
}

function Select-ZapretFolder {
  Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
  $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
  $dialog.Description = 'Папка zapret (внутри должен быть bin\winws.exe)'
  $dialog.ShowNewFolderButton = $true
  if ($null -ne $script:Folder) { $dialog.SelectedPath = $script:Folder }
  $result = $dialog.ShowDialog()
  $picked = $dialog.SelectedPath
  $dialog.Dispose()
  if ($result -ne [System.Windows.Forms.DialogResult]::OK) { return }
  if (-not (Test-ZapretDir $picked)) {
    & $script:Api.ShowBalloon 'Zapret' 'В папке нет bin\winws.exe - это не zapret'
    return
  }
  $script:Folder = $picked
  Save-Path $picked
  $script:LastRender = ''
  Render
  & $script:Api.ShowBalloon 'Zapret' ('Папка: ' + $picked)
}

function Install-ZapretService {
  $folder = Get-FolderCached $true
  if ($null -eq $folder) {
    & $script:Api.ShowBalloon 'Zapret' 'Сначала укажи папку zapret'
    return
  }
  $bat = Join-Path $folder 'service.bat'
  if (-not (Test-Path -LiteralPath $bat)) {
    & $script:Api.ShowBalloon 'Zapret' 'В папке нет service.bat'
    return
  }
  try {
    Start-Process -FilePath "$env:SystemRoot\System32\cmd.exe" -ArgumentList ('/c ""' + $bat + '""') -WorkingDirectory $folder -Verb RunAs
    & $script:Api.ShowBalloon 'Zapret' 'В окне установщика выбери «Install Service» и стратегию'
  } catch {
    & $script:Api.ShowBalloon 'Zapret' ('Установщик не запущен: ' + $_.Exception.Message)
  }
}

function Invoke-ZapretService([string]$action) {
  $label = $(switch ($action) { 'start' { 'запущена' } 'stop' { 'остановлена' } 'restart' { 'перезапущена' } default { $action } })
  if ((Get-ZapretState).ImagePathValid -eq $false) {
    & $script:Api.ShowBalloon 'Zapret' 'Служба ссылается на отсутствующий winws.exe - переустановите службу'
    return
  }
  $done = $false
  $errorText = ''
  try {
    switch ($action) {
      'start' { Start-Service -Name $script:ServiceName -ErrorAction Stop }
      'stop' { Stop-Service -Name $script:ServiceName -Force -ErrorAction Stop }
      'restart' { Restart-Service -Name $script:ServiceName -Force -ErrorAction Stop }
    }
    $done = $true
  } catch {
    $errorText = $_.Exception.Message
  }

  if (-not $done) {
    try {
      $command = $(if ($action -eq 'restart') {
        'sc stop {0} & sc start {0}' -f $script:ServiceName
      } else {
        'sc {0} {1}' -f $action, $script:ServiceName
      })
      $process = Start-Process -FilePath "$env:SystemRoot\System32\cmd.exe" -ArgumentList ('/c ' + $command) -Verb RunAs -Wait -PassThru -WindowStyle Hidden
      if ($process.ExitCode -eq 0) { $done = $true }
      else { $errorText = 'sc: код ' + $process.ExitCode }
    } catch {
      $errorText = $_.Exception.Message
    }
  }

  if ($done) { & $script:Api.ShowBalloon 'Zapret' ('Служба ' + $label) }
  else { & $script:Api.ShowBalloon 'Zapret' ('Не удалось: ' + $errorText) }
  $script:LastRender = ''
  Render
}

function Set-ZapretAutostart([bool]$enable) {
  $mode = $(if ($enable) { 'auto' } else { 'demand' })
  try {
    $process = Start-Process -FilePath "$env:SystemRoot\System32\sc.exe" -ArgumentList @('config', $script:ServiceName, 'start=', $mode) -Verb RunAs -Wait -PassThru -WindowStyle Hidden
    if ($process.ExitCode -eq 0) {
      & $script:Api.ShowBalloon 'Zapret' $(if ($enable) { 'Автозапуск включён' } else { 'Автозапуск выключен' })
    } else {
      & $script:Api.ShowBalloon 'Zapret' ('sc config: код ' + $process.ExitCode)
    }
  } catch {
    & $script:Api.ShowBalloon 'Zapret' ('Автозапуск не изменён: ' + $_.Exception.Message)
  }
  $script:LastRender = ''
  Render
}

# ---------------------------------------------------------------- view

function Render {
  $api = $script:Api
  $state = Get-ZapretState
  $folder = $state.Folder

  $summary = 'не найден'
  $tone = 'idle'
  $brokenPath = ($state.Status -ne 'Missing' -and -not $state.ImagePathValid)
  if ($brokenPath) {
    $summary = 'служба ссылается на старую папку'
    $tone = 'warn'
  } elseif ($state.Status -eq 'Running') {
    $summary = 'служба работает'
    $tone = 'run'
  } elseif ($state.Status -ne 'Missing') {
    $summary = 'служба остановлена'
    $tone = 'warn'
  } elseif ($state.ProcessCount -gt 0) {
    $summary = 'работает без службы'
    $tone = 'warn'
  } elseif ($null -ne $folder) {
    $summary = 'служба не установлена'
    $tone = 'warn'
  }
  & $api.Clear
  & $api.SetSummary $summary

  $stateText = $(switch ($state.Status) {
    'Running' { 'работает' }
    'Stopped' { 'остановлена' }
    'Missing' { 'не установлена' }
    default { [string]$state.Status }
  })
  $startText = $(if ($state.Status -eq 'Missing') {
    '—'
  } else {
    switch ($state.StartType) {
      'Automatic' { 'автоматически' }
      'Manual' { 'вручную' }
      'Disabled' { 'отключена' }
      'Unknown' { 'неизвестно' }
      default { [string]$state.StartType }
    }
  })
  $meta = 'Служба «{0}»: {1}' -f $script:ServiceName, $stateText
  if ($state.Status -eq 'Missing' -and $state.ProcessCount -gt 0) { $meta = $meta + "`n" + ('Процесс winws.exe: PID {0}' -f $state.ProcessId) }
  if ($state.Strategy -ne '') { $meta = $meta + "`n" + ('Стратегия: ' + $state.Strategy) }
  if ($brokenPath) { $meta = $meta + "`n" + 'winws.exe по пути службы не найден: переустановите службу' }

  $toggle = & $api.NewButton 'AllowButton' $(if ($state.Status -eq 'Running') { 'Остановить' } else { 'Запустить' }) {
    if ((Get-ZapretState).Status -eq 'Running') { Invoke-ZapretService 'stop' } else { Invoke-ZapretService 'start' }
  }.GetNewClosure()
  $toggle.IsEnabled = ($state.Status -ne 'Missing' -and -not $brokenPath)
  $restart = & $api.NewButton 'GhostButton' 'Перезапустить' { Invoke-ZapretService 'restart' }.GetNewClosure()
  $restart.IsEnabled = ($state.Status -eq 'Running')
  $api.Panel.Children.Add((& $api.NewRow $tone 'Zapret' $meta @($toggle, $restart))) | Out-Null

  if ($null -ne $folder) {
    $open = & $api.NewFullButton 'PillButton' '📂 Открыть папку zapret' { Open-ZapretFolder }.GetNewClosure()
    $api.Panel.Children.Add($open) | Out-Null
  }

  if ($state.Status -eq 'Missing' -or $brokenPath) {
    $installLabel = $(if ($brokenPath) { '⚙ Переустановить службу…' } else { '⚙ Установить службу…' })
    $install = & $api.NewFullButton 'PillButton' $installLabel { Install-ZapretService }.GetNewClosure()
    $install.IsEnabled = ($null -ne $folder)
    $api.Panel.Children.Add($install) | Out-Null
  } else {
    $autoLabel = $(if ($state.StartType -eq 'Automatic') { '⏻ Автозапуск включён' } else { '⏻ Автозапуск выключен' })
    $auto = & $api.NewFullButton 'PillButton' $autoLabel {
      Set-ZapretAutostart ((Get-ZapretState).StartType -ne 'Automatic')
    }.GetNewClosure()
    $api.Panel.Children.Add($auto) | Out-Null
  }

  $pick = & $api.NewFullButton 'GhostButton' '📁 Указать папку zapret…' { Select-ZapretFolder }.GetNewClosure()
  $api.Panel.Children.Add($pick) | Out-Null

  $details = New-Object System.Windows.Controls.TextBlock
  $details.Style = & $api.GetResource 'MonoText'
  $lines = @(
    ('служба: ' + $script:ServiceName),
    ('состояние: ' + $stateText),
    ('запуск: ' + $startText),
    ('стратегия: ' + $(if ($state.Strategy -ne '') { $state.Strategy } else { '—' })),
    ('папка: ' + $(if ($null -ne $folder) { $folder } else { 'не найдена' }))
  )
  if ($state.Status -eq 'Missing') {
    $lines += ('winws.exe: ' + $(if ($state.ProcessCount -gt 0) { 'PID ' + $state.ProcessId } else { 'не запущен' }))
  }
  $details.Text = ($lines -join "`n")
  $details.Margin = New-Object System.Windows.Thickness(4, 8, 4, 4)
  $api.Panel.Children.Add((& $api.NewSection 'ZAPRET')) | Out-Null
  $api.Panel.Children.Add($details) | Out-Null

  if ($brokenPath) { & $api.SetFooter 'Служба ссылается на старую папку - нажмите «Переустановить службу…»' }
  elseif ($state.Status -eq 'Running') { & $api.SetFooter 'Служба работает - обход активен' }
  elseif ($state.Status -ne 'Missing') { & $api.SetFooter 'Служба остановлена - «Запустить» вернёт обход' }
  elseif ($state.ProcessCount -gt 0) { & $api.SetFooter 'winws.exe запущен вручную, службы нет: чип видит только процесс' }
  elseif ($null -ne $folder) { & $api.SetFooter 'Службы нет: «Установить службу…» запустит service.bat' }
  else { & $api.SetFooter 'Папка не найдена: укажи её кнопкой «Указать папку…»' }

  $script:LastRender = Get-Signature
}

# ---------------------------------------------------------------- hooks

function Initialize-Feature {
  param($Api)
  $script:Api = $Api
  Get-FolderCached $true | Out-Null
  & $Api.AddTrayItem 'Открыть папку zapret' { Open-ZapretFolder }
  & $Api.AddTrayItem 'Запустить zapret' { Invoke-ZapretService 'start' }
  & $Api.AddTrayItem 'Остановить zapret' { Invoke-ZapretService 'stop' }
}

function Enter-Feature {
  param($Api)
  $script:Api = $Api
  $script:LastPoll = [datetime]::MinValue
  $script:LastScan = [datetime]::MinValue
  Render
}

function Update-Feature {
  param($Api)
  $now = Get-Date
  if (($now - $script:LastPoll).TotalSeconds -lt 2) { return }
  $script:LastPoll = $now
  $script:Api = $Api
  if ((Get-Signature) -ne $script:LastRender) { Render }
}

function Dispose-Feature {
  param($Api)
}
