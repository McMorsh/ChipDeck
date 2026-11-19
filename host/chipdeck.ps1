#requires -Version 5.1
<#
    Overlay host.

    A frameless always-on-top window with a strip of features and a system-tray
    menu. The host knows nothing about DSH or zapret: it discovers every
    directory under ../features (or $env:DSH_OVERLAY_FEATURES) that has a
    feature.json, renders it by kind, watches that directory for edits, keeps a
    user-defined chip order, and lets features contribute tray entries.

    Built-in kinds: service (Windows service controls) and commands (a status
    command plus action buttons). Everything else is a script feature: the
    entry file is loaded as a PowerShell module defining
    Initialize-/Enter-/Update-/Dispose-Feature and receiving the host API.
    See docs/FEATURES.md.
#>

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = 'Stop'
$script:HostDir = Split-Path -Parent $PSCommandPath
$script:ProjectDir = Split-Path -Parent $script:HostDir
$script:FeaturesRoot = if ($env:DSH_OVERLAY_FEATURES) { $env:DSH_OVERLAY_FEATURES } else { Join-Path $script:ProjectDir 'features' }
$script:RuntimeRoot = if ($env:DSH_OVERLAY_DIR) { $env:DSH_OVERLAY_DIR } else { Join-Path $env:LOCALAPPDATA 'dsh-overlay' }
New-Item -ItemType Directory -Path $script:RuntimeRoot -Force | Out-Null

$script:BoundsPath = Join-Path $script:RuntimeRoot 'window.json'
$script:FocusPath = Join-Path $script:RuntimeRoot 'focus.flag'
$script:OrderPath = Join-Path $script:RuntimeRoot 'order.json'
$script:SettingsPath = Join-Path $script:RuntimeRoot 'settings.json'

$mutexSuffix = if ($env:DSH_OVERLAY_MUTEX_SUFFIX) { '.' + $env:DSH_OVERLAY_MUTEX_SUFFIX } else { '' }
$script:Mutex = New-Object System.Threading.Mutex($false, ('Local\DshOverlayHost' + $mutexSuffix))
if (-not $script:Mutex.WaitOne(0)) { exit 0 }

# ---------------------------------------------------------------- helpers
function Write-JsonFile([string]$path, [string]$text) {
  $temporary = "$path.tmp"
  [System.IO.File]::WriteAllText($temporary, $text, (New-Object System.Text.UTF8Encoding($false)))
  Move-Item -LiteralPath $temporary -Destination $path -Force
}

function Add-HostLog([string]$text) {
  try {
    Add-Content -LiteralPath (Join-Path $script:RuntimeRoot 'host-errors.log') -Value ((Get-Date -Format s) + ' ' + $text) -Encoding UTF8
  } catch { }
}

function Save-Bounds {
  $state = @{
    left = [Math]::Round($script:Window.Left)
    top = [Math]::Round($script:Window.Top)
    width = [Math]::Round($script:Window.Width)
    height = [Math]::Round($script:Window.Height)
    feature = $script:ActiveFeatureId
  }
  Write-JsonFile $script:BoundsPath (ConvertTo-Json -InputObject $state -Compress)
}

function Restore-Bounds {
  $left = [System.Windows.SystemParameters]::WorkArea.Right - 404
  $top = [System.Windows.SystemParameters]::WorkArea.Top + 72
  $width = 380.0
  $height = 540.0
  if (Test-Path -LiteralPath $script:BoundsPath) {
    try {
      $saved = Get-Content -LiteralPath $script:BoundsPath -Raw | ConvertFrom-Json
      $virtualLeft = [System.Windows.SystemParameters]::VirtualScreenLeft
      $virtualTop = [System.Windows.SystemParameters]::VirtualScreenTop
      $virtualRight = $virtualLeft + [System.Windows.SystemParameters]::VirtualScreenWidth
      $virtualBottom = $virtualTop + [System.Windows.SystemParameters]::VirtualScreenHeight
      $width = [Math]::Max(320, [Math]::Min([double]$saved.width, 900))
      $height = [Math]::Max(240, [Math]::Min([double]$saved.height, 1200))
      $left = [Math]::Max($virtualLeft, [Math]::Min([double]$saved.left, $virtualRight - 160))
      $top = [Math]::Max($virtualTop, [Math]::Min([double]$saved.top, $virtualBottom - 120))
      if ($saved.feature -and -not $env:DSH_OVERLAY_FEATURE) { $script:PreferredFeature = [string]$saved.feature }
    } catch { }
  }
  $script:Window.WindowStartupLocation = 'Manual'
  $script:Window.Left = $left
  $script:Window.Top = $top
  $script:Window.Width = $width
  $script:Window.Height = $height
}

# ---------------------------------------------------------------- features
. (Join-Path $script:HostDir 'settings.ps1')
$script:Settings = Read-Settings

function Read-Features {
  $found = @()
  if (-not (Test-Path -LiteralPath $script:FeaturesRoot)) { return $found }
  foreach ($dir in Get-ChildItem -LiteralPath $script:FeaturesRoot -Directory) {
    $descriptor = Join-Path $dir.FullName 'feature.json'
    if (-not (Test-Path -LiteralPath $descriptor)) { continue }
    try {
      $config = [System.IO.File]::ReadAllText($descriptor, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    } catch {
      Add-HostLog ('feature.json ' + $dir.Name + ': ' + $_.Exception.Message)
      continue
    }
    if ($null -eq $config.id -or $null -eq $config.title -or $null -eq $config.kind) { continue }
    $enabled = if ($null -eq $config.enabled) { $true } else { [bool]$config.enabled }
    $entryName = if ($null -eq $config.entry) { 'feature.ps1' } else { [string]$config.entry }
    $found += [pscustomobject]@{
      Id = [string]$config.id
      Title = [string]$config.title
      Order = if ($null -eq $config.order) { 100 } else { [double]$config.order }
      Kind = [string]$config.kind
      Configured = $enabled
      Dir = $dir.FullName
      Entry = Join-Path $dir.FullName $entryName
      Icon = if ($null -eq $config.icon) { '' } else { [string]$config.icon }
      Glyph = if ($null -eq $config.glyph) { '' } else { [string]$config.glyph }
      Service = if ($null -eq $config.service) { '' } else { [string]$config.service }
      Autostart = if ($null -eq $config.autostart) { $true } else { [bool]$config.autostart }
      OpenFolder = if ($null -eq $config.openFolder) { $true } else { [bool]$config.openFolder }
      Status = if ($null -eq $config.status) { '' } else { [string]$config.status }
      RefreshSeconds = if ($null -eq $config.refreshSeconds) { 10 } else { [double]$config.refreshSeconds }
      Actions = @($config.actions)
      TrayItems = @($config.tray)
    }
  }
  return $found
}

function Sort-Features($features) {
  $savedOrder = @()
  if (Test-Path -LiteralPath $script:OrderPath) {
    try {
      $raw = Get-Content -LiteralPath $script:OrderPath -Raw | ConvertFrom-Json
      if ($raw -is [System.Array]) { $savedOrder = $raw }
      elseif ($null -ne $raw -and [string]$raw -ne '') { $savedOrder = @([string]$raw) }
    } catch { $savedOrder = @() }
  }
  $positions = @{}
  for ($i = 0; $i -lt $savedOrder.Count; $i++) { $positions[[string]$savedOrder[$i]] = $i }
  return @($features | Sort-Object @{ Expression = { if ($positions.ContainsKey($_.Id)) { $positions[$_.Id] } else { 10000 + $_.Order } } }, @{ Expression = { $_.Title } })
}

function Get-FeaturesSignature {
  if (-not (Test-Path -LiteralPath $script:FeaturesRoot)) { return '' }
  $parts = New-Object System.Collections.Generic.List[string]
  foreach ($file in Get-ChildItem -LiteralPath $script:FeaturesRoot -Recurse -File) {
    $parts.Add($file.FullName + ':' + $file.LastWriteTimeUtc.Ticks)
  }
  return ($parts -join '|')
}

# ---------------------------------------------------------------- shell
$script:Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Overlay" Width="380" Height="540" MinWidth="320" MinHeight="240"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ResizeMode="CanResizeWithGrip"
        FontFamily="Segoe UI" TextOptions.TextFormattingMode="Display"
        UseLayoutRounding="True" SnapsToDevicePixels="True">
  <Window.Resources>
    <Style x:Key="BaseText" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#F0F0F3"/>
      <Setter Property="TextTrimming" Value="CharacterEllipsis"/>
    </Style>
    <Style x:Key="MutedText" TargetType="TextBlock" BasedOn="{StaticResource BaseText}">
      <Setter Property="Foreground" Value="#9A9AA6"/>
      <Setter Property="FontSize" Value="11"/>
    </Style>
    <Style x:Key="MonoText" TargetType="TextBlock" BasedOn="{StaticResource BaseText}">
      <Setter Property="FontFamily" Value="Consolas"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
    </Style>
    <Style x:Key="SectionText" TargetType="TextBlock" BasedOn="{StaticResource BaseText}">
      <Setter Property="Foreground" Value="#8A8A96"/>
      <Setter Property="FontSize" Value="10"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Margin" Value="4,6,4,4"/>
    </Style>
    <Style x:Key="PillButton" TargetType="Button">
      <Setter Property="Foreground" Value="#EDEDF1"/>
      <Setter Property="Background" Value="#1FFFFFFF"/>
      <Setter Property="Padding" Value="9,4"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="7"
                    Padding="{TemplateBinding Padding}" BorderThickness="0">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Opacity" Value="0.82"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Bd" Property="Opacity" Value="0.4"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="AllowButton" TargetType="Button" BasedOn="{StaticResource PillButton}">
      <Setter Property="Background" Value="#4C8DFF"/>
      <Setter Property="Foreground" Value="#FFFFFF"/>
    </Style>
    <Style x:Key="RejectButton" TargetType="Button" BasedOn="{StaticResource PillButton}">
      <Setter Property="Background" Value="#2EFF8080"/>
      <Setter Property="Foreground" Value="#FFBDBD"/>
    </Style>
    <Style x:Key="GhostButton" TargetType="Button" BasedOn="{StaticResource PillButton}">
      <Setter Property="Background" Value="#1AFFFFFF"/>
    </Style>
    <Style x:Key="CloseButton" TargetType="Button" BasedOn="{StaticResource PillButton}">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#8A8A96"/>
      <Setter Property="Padding" Value="7,2"/>
      <Setter Property="FontSize" Value="13"/>
    </Style>
    <Style x:Key="RowBorder" TargetType="Border">
      <Setter Property="CornerRadius" Value="10"/>
      <Setter Property="Background" Value="#12FFFFFF"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="BorderBrush" Value="#1FFFFFFF"/>
      <Setter Property="Padding" Value="9"/>
      <Setter Property="Margin" Value="0,0,0,6"/>
    </Style>
  </Window.Resources>
  <Border Margin="10" CornerRadius="16" Background="#F5161619" BorderThickness="1" BorderBrush="#2BFFFFFF">
    <Border.Effect>
      <DropShadowEffect BlurRadius="26" ShadowDepth="0" Opacity="0.55" Color="#000000"/>
    </Border.Effect>
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>
      <Grid x:Name="Header" Grid.Row="0" Margin="14,11,10,6" Background="Transparent">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <Ellipse x:Name="HeaderDot" Grid.Column="0" Width="8" Height="8" Fill="#62D69B" VerticalAlignment="Center" Margin="0,0,9,0"/>
        <StackPanel Grid.Column="1" VerticalAlignment="Center">
          <TextBlock Style="{StaticResource BaseText}" FontSize="12.5" FontWeight="SemiBold" Text="Оверлей"/>
          <TextBlock x:Name="Summary" Style="{StaticResource MutedText}" Text=""/>
        </StackPanel>
        <Button x:Name="CloseButton" Grid.Column="2" Style="{StaticResource CloseButton}" Content="✕" ToolTip="Свернуть в трей"/>
      </Grid>
      <ScrollViewer Grid.Row="1" HorizontalScrollBarVisibility="Hidden" VerticalScrollBarVisibility="Disabled" Margin="12,0,10,4">
        <StackPanel x:Name="FeatureStrip" Orientation="Horizontal"/>
      </ScrollViewer>
      <ScrollViewer x:Name="Scroller" Grid.Row="2" VerticalScrollBarVisibility="Auto" Margin="10,2,10,4">
        <StackPanel x:Name="ContentHost"/>
      </ScrollViewer>
      <TextBlock x:Name="Status" Grid.Row="3" Style="{StaticResource MutedText}" FontSize="10" Margin="14,0,12,10" Text=""/>
    </Grid>
  </Border>
</Window>
'@

$script:Window = [System.Windows.Markup.XamlReader]::Parse($script:Xaml)
$script:Header = $script:Window.FindName('Header')
$script:Summary = $script:Window.FindName('Summary')
$script:Status = $script:Window.FindName('Status')
$script:ContentHost = $script:Window.FindName('ContentHost')
$script:HeaderDot = $script:Window.FindName('HeaderDot')
$script:CloseButton = $script:Window.FindName('CloseButton')
$script:Scroller = $script:Window.FindName('Scroller')
$script:FeatureStrip = $script:Window.FindName('FeatureStrip')

$script:PreferredFeature = $env:DSH_OVERLAY_FEATURE
Restore-Bounds

$script:Dirty = $false
$script:Quitting = $false
$script:ActiveFeatureId = ''
$script:Chips = @{}
$script:ChipTitles = @{}
$script:Order = New-Object System.Collections.Generic.List[string]
$script:Loaded = @{}
$script:Runtime = @{}
$script:FeatureTrayItems = @{}
$script:HideHintShown = $false
$script:MenuOpen = $false
$script:TrayDirty = $false
$script:TrayFlags = @{ Rebuild = $false }
$script:DragId = ''
$script:DragStartX = 0
$script:DragMoved = $false
$script:LastReloadCheck = [datetime]::MinValue
$script:AutoExitAt = if ($env:DSH_OVERLAY_TEST_EXIT_MS) { (Get-Date).AddMilliseconds([double]$env:DSH_OVERLAY_TEST_EXIT_MS) } else { $null }

$script:AllFeatures = Read-Features
$script:Features = Sort-Features (Get-EffectiveFeatures $script:AllFeatures)
foreach ($feature in $script:Features) {
  $script:Runtime[$feature.Id] = @{ StatusText = '…'; Output = ''; LastRefresh = [datetime]::MinValue; LastCheck = [datetime]::MinValue }
}

# ---------------------------------------------------------------- widgets
function New-SectionText([string]$text) {
  $block = New-Object System.Windows.Controls.TextBlock
  $block.Style = $script:Window.FindResource('SectionText')
  $block.Text = $text
  return $block
}

function New-RowGrid([string]$tone, [string]$title, [string]$meta, [object[]]$buttons) {
  $border = New-Object System.Windows.Controls.Border
  $border.Style = $script:Window.FindResource('RowBorder')
  if ($tone -eq 'warn') { $border.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#3DFFCF66') }
  $grid = New-Object System.Windows.Controls.Grid
  $auto1 = New-Object System.Windows.Controls.ColumnDefinition; $auto1.Width = [System.Windows.GridLength]::Auto; $grid.ColumnDefinitions.Add($auto1) | Out-Null
  $star = New-Object System.Windows.Controls.ColumnDefinition; $star.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star); $grid.ColumnDefinitions.Add($star) | Out-Null
  $auto2 = New-Object System.Windows.Controls.ColumnDefinition; $auto2.Width = [System.Windows.GridLength]::Auto; $grid.ColumnDefinitions.Add($auto2) | Out-Null

  $dot = New-Object System.Windows.Shapes.Ellipse
  $dot.Width = 8; $dot.Height = 8; $dot.VerticalAlignment = 'Top'
  $dot.Margin = New-Object System.Windows.Thickness(0, 5, 8, 0)
  $dot.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString($(if ($tone -eq 'warn') { '#FFCF66' } elseif ($tone -eq 'idle') { '#7A7A85' } else { '#62D69B' }))
  [System.Windows.Controls.Grid]::SetColumn($dot, 0)
  $grid.Children.Add($dot) | Out-Null

  $stack = New-Object System.Windows.Controls.StackPanel
  $stack.VerticalAlignment = 'Center'
  $titleBlock = New-Object System.Windows.Controls.TextBlock
  $titleBlock.Style = $script:Window.FindResource('BaseText')
  $titleBlock.FontSize = 12.5
  $titleBlock.FontWeight = 'SemiBold'
  $titleBlock.Text = $title
  $stack.Children.Add($titleBlock) | Out-Null
  if ($meta -ne '') {
    $metaBlock = New-Object System.Windows.Controls.TextBlock
    $metaBlock.Style = $script:Window.FindResource('MutedText')
    $metaBlock.Text = $meta
    $metaBlock.TextWrapping = 'Wrap'
    $metaBlock.MaxHeight = 46
    $stack.Children.Add($metaBlock) | Out-Null
  }
  [System.Windows.Controls.Grid]::SetColumn($stack, 1)
  $grid.Children.Add($stack) | Out-Null

  $actions = New-Object System.Windows.Controls.StackPanel
  $actions.VerticalAlignment = 'Center'
  $actions.Margin = New-Object System.Windows.Thickness(8, 0, 0, 0)
  foreach ($button in $buttons) { $actions.Children.Add($button) | Out-Null }
  [System.Windows.Controls.Grid]::SetColumn($actions, 2)
  $grid.Children.Add($actions) | Out-Null

  $border.Child = $grid
  return $border
}

function New-ActionButton([string]$styleKey, [string]$text, [scriptblock]$onClick) {
  $button = New-Object System.Windows.Controls.Button
  $button.Style = $script:Window.FindResource($styleKey)
  $button.Content = $text
  $button.Margin = New-Object System.Windows.Thickness(0, 2, 0, 2)
  $button.MinWidth = 84
  if ($null -ne $onClick) { $button.Add_Click($onClick) }
  return $button
}

function New-FullButton([string]$styleKey, [string]$text, [scriptblock]$onClick) {
  $button = New-Object System.Windows.Controls.Button
  $button.Style = $script:Window.FindResource($styleKey)
  $button.Content = $text
  $button.HorizontalAlignment = 'Stretch'
  $button.Margin = New-Object System.Windows.Thickness(0, 0, 0, 6)
  $button.Padding = New-Object System.Windows.Thickness(10, 7, 10, 7)
  if ($null -ne $onClick) { $button.Add_Click($onClick) }
  return $button
}

function Invoke-CommandText([string]$command, [int]$timeoutSeconds) {
  if ($command -eq '') { return '' }
  $wrapped = '$ProgressPreference = ''SilentlyContinue''; ' + $command
  $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($wrapped))
  $info = New-Object System.Diagnostics.ProcessStartInfo
  $info.FileName = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
  $info.Arguments = '-NoProfile -NonInteractive -OutputFormat Text -ExecutionPolicy Bypass -EncodedCommand ' + $encoded
  $info.UseShellExecute = $false
  $info.CreateNoWindow = $true
  $info.RedirectStandardOutput = $true
  $info.RedirectStandardError = $true
  $process = [System.Diagnostics.Process]::Start($info)
  $stdout = $process.StandardOutput.ReadToEnd()
  $stderr = $process.StandardError.ReadToEnd()
  if (-not $process.WaitForExit($timeoutSeconds * 1000)) {
    try { $process.Kill() } catch { }
    return 'Таймаут выполнения команды'
  }
  $text = ($stdout + $stderr).Trim()
  if ($text -eq '') { return '(пусто)' }
  if ($text.Length -gt 4000) { return $text.Substring(0, 4000) + '…' }
  return $text
}

# ---------------------------------------------------------------- feature API


function New-FeatureApi($feature) {
  $runtimeDir = Join-Path $script:RuntimeRoot $feature.Id
  New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null
  $featureId = $feature.Id
  $trayStore = $script:FeatureTrayItems
  $trayFlags = $script:TrayFlags
  $api = @{
    Feature = $feature
    RuntimeDir = $runtimeDir
    HostDir = $script:HostDir
    Panel = $script:ContentHost
    Clear = { $script:ContentHost.Children.Clear() }
    NewSection = { param($text) New-SectionText $text }
    NewRow = { param($tone, $title, $meta, $buttons) New-RowGrid $tone $title $meta $buttons }
    NewButton = { param($styleKey, $text, $onClick) New-ActionButton $styleKey $text $onClick }
    NewFullButton = { param($styleKey, $text, $onClick) New-FullButton $styleKey $text $onClick }
    GetResource = { param($key) $script:Window.FindResource($key) }
    SetSummary = { param($text) $script:Summary.Text = [string]$text }
    SetFooter = { param($text) $script:Status.Text = [string]$text }
    ShowBalloon = { param($title, $text) Show-Balloon $title $text }
    RunCommand = { param($command, $timeoutSeconds) Invoke-CommandText $command $timeoutSeconds }
    WriteJson = { param($path, $text) Write-JsonFile $path $text }
AddTrayItem = {
      param($label, $action)
      $store = $trayStore
      if (-not $store.ContainsKey($featureId)) { $store[$featureId] = New-Object System.Collections.ArrayList }
      [void]$store[$featureId].Add(@{ Label = $label; Action = $action })
      $trayFlags.Rebuild = $true
    }.GetNewClosure()
  }
  return $api
}

function Invoke-FeatureHook($entry, [string]$hook, $api) {
  if ($null -eq $entry -or $null -eq $entry.Module) { return }
  try {
    & $entry.Module {
      param($hookName, $apiValue)
      $command = Get-Command $hookName -ErrorAction SilentlyContinue
      if ($null -ne $command) { & $command $apiValue }
    } $hook $api
  } catch {
    Add-HostLog ('feature hook ' + $hook + ': ' + ($_ | Out-String))
  }
}

function Import-ScriptFeature($feature, [bool]$runInitialize = $true) {
  $api = New-FeatureApi $feature
  $source = [System.IO.File]::ReadAllText($feature.Entry, [System.Text.Encoding]::UTF8)
  $moduleName = 'overlay-feature-' + $feature.Id + '-' + ([guid]::NewGuid().ToString('N').Substring(0, 8))
  $module = New-Module -Name $moduleName -ArgumentList @($api, $feature.Dir) -ScriptBlock ([scriptblock]::Create($source))
  $entry = @{
    Module = $module
    Api = $api
    EntryTicks = if (Test-Path -LiteralPath $feature.Entry) { (Get-Item -LiteralPath $feature.Entry).LastWriteTimeUtc.Ticks } else { 0 }
    DescriptorTicks = (Get-Item -LiteralPath (Join-Path $feature.Dir 'feature.json')).LastWriteTimeUtc.Ticks
  }
  $script:Loaded[$feature.Id] = $entry
  Invoke-FeatureHook $entry 'Initialize-Feature' $api
}

function Remove-ScriptFeature([string]$id) {
  $entry = $script:Loaded[$id]
  if ($null -eq $entry) { return }
  Invoke-FeatureHook $entry 'Dispose-Feature' $entry.Api
  try { Remove-Module -ModuleInfo $entry.Module -Force -ErrorAction SilentlyContinue } catch { }
  $script:Loaded.Remove($id)
  $script:FeatureTrayItems.Remove($id)
}

foreach ($feature in $script:Features) {
  if ($feature.Kind -ne 'script') { continue }
  try { Import-ScriptFeature $feature $false } catch { Add-HostLog ('feature ' + $feature.Id + ': ' + ($_ | Out-String)) }
}

# ---------------------------------------------------------------- generic renderers
function Get-ServiceState([string]$name) {
  if ($name -eq '') { return 'Missing' }
  try { return (Get-Service -Name $name -ErrorAction Stop).Status } catch { return 'Missing' }
}

function Get-ServiceStartType([string]$name) {
  try {
    $value = [int](Get-ItemProperty -Path ('HKLM:\SYSTEM\CurrentControlSet\Services\' + $name) -ErrorAction Stop).Start
    switch ($value) {
      0 { return 'Boot' }
      1 { return 'System' }
      2 { return 'Automatic' }
      3 { return 'Manual' }
      4 { return 'Disabled' }
    }
  } catch { }
  try { return [string](Get-Service -Name $name -ErrorAction Stop).StartType } catch { return 'Unknown' }
}

function Get-ServiceRoot([string]$name) {
  try {
    $image = [string](Get-ItemProperty -Path ('HKLM:\SYSTEM\CurrentControlSet\Services\' + $name) -ErrorAction Stop).ImagePath
    if ($image -match '^"([^"]+)"') { $exe = $Matches[1] }
    elseif ($image -match '^(\S+\.exe)') { $exe = $Matches[1] }
    else { return $null }
    if (Test-Path -LiteralPath $exe) { return Split-Path -Parent (Split-Path -Parent $exe) }
  } catch { }
  return $null
}

function Invoke-ServiceAction([string]$name, [string]$action) {
  try {
    switch ($action) {
      'start' { Start-Service -Name $name -ErrorAction Stop }
      'stop' { Stop-Service -Name $name -Force -ErrorAction Stop }
      'restart' { Restart-Service -Name $name -Force -ErrorAction Stop }
    }
    Show-Balloon $name $(switch ($action) { 'start' { 'запущена' } 'stop' { 'остановлена' } 'restart' { 'перезапущена' } default { $action } })
  } catch {
    Show-Balloon $name ('Не удалось: ' + $_.Exception.Message)
  }
  Refresh-ActiveFeature
}

function Set-ServiceAutostart([string]$name, [bool]$enabled) {
  $mode = if ($enabled) { 'auto' } else { 'demand' }
  try {
    Start-Process -FilePath "$env:SystemRoot\System32\sc.exe" -ArgumentList @('config', $name, 'start=', $mode) -Verb RunAs -Wait -WindowStyle Hidden
    Show-Balloon $name $(if ($enabled) { 'Автозапуск включён' } else { 'Автозапуск выключен' })
  } catch {
    Show-Balloon $name ('Автозапуск не изменён: ' + $_.Exception.Message)
  }
  Refresh-ActiveFeature
}

function Invoke-ServicePanelAction($sender) {
  $tag = $sender.Tag
  if ($null -eq $tag) { return }
  switch ([string]$tag.Action) {
    'toggle' {
      if ((Get-ServiceState $tag.Service) -eq 'Running') { Invoke-ServiceAction $tag.Service 'stop' }
      else { Invoke-ServiceAction $tag.Service 'start' }
    }
    'restart' { Invoke-ServiceAction $tag.Service 'restart' }
    'autostart' { Set-ServiceAutostart $tag.Service ([bool]$tag.Enable) }
    'folder' {
      $root = Get-ServiceRoot $tag.Service
      if ($null -eq $root) { Show-Balloon $tag.Service 'Папка не найдена'; return }
      Start-Process explorer.exe -ArgumentList $root
    }
  }
}

function Render-Service($feature) {
  $script:ContentHost.Children.Clear()
  $name = $feature.Service
  $state = Get-ServiceState $name
  $startType = Get-ServiceStartType $name
  $stateText = $(switch ($state) { 'Running' { 'работает' } 'Stopped' { 'остановлена' } 'Missing' { 'служба не найдена' } default { [string]$state } })
  $tone = $(if ($state -eq 'Running') { 'run' } elseif ($state -eq 'Missing') { 'idle' } else { 'warn' })
  $startText = $(switch ($startType) { 'Automatic' { 'автоматически' } 'Manual' { 'вручную' } 'Disabled' { 'отключена' } default { [string]$startType } })

  $script:ContentHost.Children.Add((New-RowGrid $tone ([string]$feature.Title) ('Служба «' + $name + '»: ' + $stateText + ' · запуск: ' + $startText) @())) | Out-Null

  $toggle = New-ActionButton 'AllowButton' $(if ($state -eq 'Running') { 'Остановить' } else { 'Запустить' }) { param($sender, $eventArgs) Invoke-ServicePanelAction $sender }
  $toggle.Tag = @{ Service = $name; Action = 'toggle' }
  $toggle.IsEnabled = ($state -ne 'Missing')
  $restart = New-ActionButton 'GhostButton' 'Перезапустить' { param($sender, $eventArgs) Invoke-ServicePanelAction $sender }
  $restart.Tag = @{ Service = $name; Action = 'restart' }
  $restart.IsEnabled = ($state -eq 'Running')

  $actions = New-Object System.Windows.Controls.WrapPanel
  $actions.Margin = New-Object System.Windows.Thickness(0, 2, 0, 6)
  $actions.Children.Add($toggle) | Out-Null
  $actions.Children.Add($restart) | Out-Null
  $script:ContentHost.Children.Add($actions) | Out-Null

  if ($feature.Autostart) {
    $autoLabel = $(if ($startType -eq 'Automatic') { 'Автозапуск включён' } else { 'Автозапуск выключен' })
    $auto = New-FullButton 'PillButton' ('⏻ ' + $autoLabel) { param($sender, $eventArgs) Invoke-ServicePanelAction $sender }
    $auto.Tag = @{ Service = $name; Action = 'autostart'; Enable = ($startType -ne 'Automatic') }
    $script:ContentHost.Children.Add($auto) | Out-Null
  }

  if ($feature.OpenFolder) {
    $folder = New-FullButton 'PillButton' '📂 Открыть папку службы' { param($sender, $eventArgs) Invoke-ServicePanelAction $sender }
    $folder.Tag = @{ Service = $name; Action = 'folder' }
    $folder.IsEnabled = ($null -ne (Get-ServiceRoot $name))
    $script:ContentHost.Children.Add($folder) | Out-Null
  }

  $script:ContentHost.Children.Add((New-SectionText 'СЛУЖБА')) | Out-Null
  $info = New-Object System.Windows.Controls.TextBlock
  $info.Style = $script:Window.FindResource('MonoText')
  $info.Text = 'name:   ' + $name + "`nstate:  " + $state + "`nstart:  " + $startType
  $script:ContentHost.Children.Add($info) | Out-Null
  $script:Summary.Text = ('{0} · {1}' -f $feature.Title, $stateText)
  $script:Status.Text = ''
}

function Invoke-CommandPanelAction($sender) {
  $tag = $sender.Tag
  if ($null -eq $tag) { return }
  $feature = $script:Features | Where-Object { $_.Id -eq $tag.Id } | Select-Object -First 1
  if ($null -eq $feature) { return }
  $result = Invoke-CommandText ([string]$tag.Command) 30
  $script:Runtime[$feature.Id].Output = $result
  $script:Runtime[$feature.Id].LastRefresh = [datetime]::MinValue
  Render-Commands $feature
}

function Render-Commands($feature) {
  $runtime = $script:Runtime[$feature.Id]
  $script:ContentHost.Children.Clear()
  $script:Summary.Text = [string]$feature.Title

  if ($feature.Status -ne '') {
    $script:ContentHost.Children.Add((New-SectionText 'СОСТОЯНИЕ')) | Out-Null
    $statusBlock = New-Object System.Windows.Controls.TextBlock
    $statusBlock.Style = $script:Window.FindResource('MonoText')
    $statusBlock.Text = [string]$runtime.StatusText
    $statusBox = New-Object System.Windows.Controls.Border
    $statusBox.Style = $script:Window.FindResource('RowBorder')
    $statusBox.Child = $statusBlock
    $script:ContentHost.Children.Add($statusBox) | Out-Null
  }

  if (@($feature.Actions).Count -gt 0) {
    $script:ContentHost.Children.Add((New-SectionText 'ДЕЙСТВИЯ')) | Out-Null
    foreach ($action in @($feature.Actions)) {
      if ($null -eq $action -or $null -eq $action.label) { continue }
      $label = [string]$action.label
      $command = [string]$action.command
      $button = New-FullButton 'PillButton' $label { param($sender, $eventArgs) Invoke-CommandPanelAction $sender }
      $button.Tag = @{ Id = $feature.Id; Command = $command }
      $script:ContentHost.Children.Add($button) | Out-Null
    }
  }

  if ([string]$runtime.Output -ne '') {
    $script:ContentHost.Children.Add((New-SectionText 'ВЫВОД')) | Out-Null
    $outputBlock = New-Object System.Windows.Controls.TextBlock
    $outputBlock.Style = $script:Window.FindResource('MonoText')
    $outputBlock.Text = [string]$runtime.Output
    $outputScroll = New-Object System.Windows.Controls.ScrollViewer
    $outputScroll.MaxHeight = 220
    $outputScroll.VerticalScrollBarVisibility = 'Auto'
    $outputScroll.Content = $outputBlock
    $script:ContentHost.Children.Add($outputScroll) | Out-Null
  }
  $script:Status.Text = ''
}

function Get-ActiveFeature {
  return $script:Features | Where-Object { $_.Id -eq $script:ActiveFeatureId } | Select-Object -First 1
}

function Render-ActiveFeature {
  $feature = Get-ActiveFeature
  if ($null -eq $feature) { return }
  switch ($feature.Kind) {
    'service' { Render-Service $feature }
    'commands' { Render-Commands $feature }
    'script' {
      $entry = $script:Loaded[$feature.Id]
      if ($null -ne $entry) { Invoke-FeatureHook $entry 'Enter-Feature' $entry.Api }
    }
    default {
      $script:ContentHost.Children.Clear()
      $block = New-Object System.Windows.Controls.TextBlock
      $block.Style = $script:Window.FindResource('MutedText')
      $block.Text = ('Неизвестный тип фичи: ' + $feature.Kind)
      $script:ContentHost.Children.Add($block) | Out-Null
    }
  }
}

function Refresh-ActiveFeature {
  $feature = Get-ActiveFeature
  if ($null -eq $feature) { return }
  if ($feature.Kind -eq 'service') { Render-Service $feature }
  if ($feature.Kind -eq 'commands' -and $feature.Status -ne '') {
    $script:Runtime[$feature.Id].StatusText = Invoke-CommandText $feature.Status 10
    $script:Runtime[$feature.Id].LastRefresh = Get-Date
    Render-Commands $feature
  }
}

# ---------------------------------------------------------------- chips, icons, order
function Get-FeatureImage($feature) {
  if ($feature.Icon -eq '') { return $null }
  $path = Join-Path $feature.Dir $feature.Icon
  if (-not (Test-Path -LiteralPath $path)) { return $null }
  try {
    $image = New-Object System.Windows.Media.Imaging.BitmapImage
    $image.BeginInit()
    $image.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $image.UriSource = New-Object System.Uri($path)
    $image.EndInit()
    $image.Freeze()
    return $image
  } catch {
    Add-HostLog ('icon ' + $feature.Id + ': ' + $_.Exception.Message)
    return $null
  }
}

function Start-ChipDrag($sender, $eventArgs) {
  if ($env:DSH_OVERLAY_DEBUG) { Add-HostLog ('debug: chip down ' + [string]$sender.Tag) }
  $script:DragId = [string]$sender.Tag
  $script:DragStartX = $eventArgs.GetPosition($script:FeatureStrip).X
  $script:DragMoved = $false
  $script:FeatureStrip.CaptureMouse() | Out-Null
}

function Enter-Chip($sender, $eventArgs) {
  if ($script:DragId -eq '') { $sender.Opacity = 0.85 }
}

function Leave-Chip($sender, $eventArgs) {
  if ($script:DragId -eq '') { $sender.Opacity = 1.0 }
}

function New-FeatureChip($feature) {
  $border = New-Object System.Windows.Controls.Border
  $border.CornerRadius = New-Object System.Windows.CornerRadius(8)
  $border.Padding = New-Object System.Windows.Thickness(7, 3, 10, 3)
  $border.Margin = New-Object System.Windows.Thickness(0, 0, 4, 0)
  $border.Cursor = [System.Windows.Input.Cursors]::Hand
  $border.Background = [System.Windows.Media.Brushes]::Transparent
  $border.Tag = $feature.Id
  $border.ToolTip = ('{0} · {1}' -f $feature.Title, $feature.Kind)

  $panel = New-Object System.Windows.Controls.StackPanel
  $panel.Orientation = 'Horizontal'
  $image = Get-FeatureImage $feature
  if ($null -ne $image) {
    $picture = New-Object System.Windows.Controls.Image
    $picture.Source = $image
    $picture.Width = 18
    $picture.Height = 18
    $picture.Margin = New-Object System.Windows.Thickness(0, 0, 6, 0)
    $panel.Children.Add($picture) | Out-Null
  } elseif ($feature.Glyph -ne '') {
    $glyph = New-Object System.Windows.Controls.TextBlock
    $glyph.Text = $feature.Glyph
    $glyph.FontSize = 13
    $glyph.Margin = New-Object System.Windows.Thickness(0, 0, 5, 0)
    $glyph.VerticalAlignment = 'Center'
    $panel.Children.Add($glyph) | Out-Null
  }
  $title = New-Object System.Windows.Controls.TextBlock
  $title.Text = $feature.Title
  $title.FontSize = 11.5
  $title.FontWeight = 'SemiBold'
  $title.VerticalAlignment = 'Center'
  $panel.Children.Add($title) | Out-Null
  $script:ChipTitles[$feature.Id] = $title
  $border.Child = $panel

  $border.Add_MouseLeftButtonDown({
    param($sender, $eventArgs)
    Start-ChipDrag $sender $eventArgs
  })
  $border.Add_MouseEnter({
    param($sender, $eventArgs)
    if ($script:DragId -eq '') { $sender.Opacity = 0.85 }
  })
  $border.Add_MouseLeave({
    param($sender, $eventArgs)
    if ($script:DragId -eq '') { $sender.Opacity = 1.0 }
  })
  return $border
}

function Update-ChipStyles {
  foreach ($id in $script:Order) {
    $chip = $script:Chips[$id]
    if ($null -eq $chip) { continue }
    $active = ($id -eq $script:ActiveFeatureId)
    if ($active) {
      $chip.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#264C8DFF')
    } else {
      $chip.Background = [System.Windows.Media.Brushes]::Transparent
    }
    $title = $script:ChipTitles[$id]
    if ($null -ne $title) {
      $title.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($(if ($active) { '#EAF1FF' } else { '#A9A9B5' }))
    }
  }
}

function Rebuild-Strip {
  $script:FeatureStrip.Children.Clear()
  $script:Chips = @{}
  $script:ChipTitles = @{}
  $known = @{}
  foreach ($feature in $script:Features) { $known[$feature.Id] = $feature }
  foreach ($id in @($script:Order)) {
    if (-not $known.ContainsKey($id)) { $script:Order.Remove($id); continue }
    $chip = New-FeatureChip $known[$id]
    if ($env:DSH_OVERLAY_DEBUG) { Add-HostLog ('debug: chip ' + $id + ' type=' + $chip.GetType().FullName + ' count=' + @($chip).Count) }
    $script:FeatureStrip.Children.Add($chip) | Out-Null
    $script:Chips[$id] = $chip
  }
  Update-ChipStyles
}

function Save-FeatureOrder {
  Write-JsonFile $script:OrderPath (ConvertTo-Json -InputObject @($script:Order) -Compress)
}

# ---------------------------------------------------------------- tray
function New-MenuItem([string]$text, [scriptblock]$onClick, [bool]$checkable) {
  $item = New-Object System.Windows.Forms.ToolStripMenuItem
  $item.Text = $text
  if ($checkable) { $item.CheckOnClick = $true }
  if ($null -ne $onClick) { $item.Add_Click($onClick) }
  return $item
}

function Add-FeatureTrayItem([string]$id, [string]$label, [scriptblock]$action) {
  if (-not $script:FeatureTrayItems.ContainsKey($id)) {
    $script:FeatureTrayItems[$id] = New-Object System.Collections.ArrayList
  }
  [void]$script:FeatureTrayItems[$id].Add(@{ Label = $label; Action = $action })
  if ($null -ne $script:Menu) { Rebuild-TrayMenu }
}

function Add-FeatureSubmenu([string]$title, $entries) {
  if (@($entries).Count -eq 0) { return }
  $submenu = New-Object System.Windows.Forms.ToolStripMenuItem
  $submenu.Text = $title
  foreach ($entry in $entries) {
    $label = [string]$entry.Label
    $action = $entry.Action
    if ($null -eq $action) { continue }
    $item = New-MenuItem $label $action $false
    $submenu.DropDownItems.Add($item) | Out-Null
  }
  $script:Menu.Items.Add($submenu) | Out-Null
}

function Invoke-TrayEntryAction($sender) {
  $tag = $sender.Tag
  if ($null -eq $tag) { return }
  if ([string]$tag.Kind -eq 'command') { Invoke-CommandText ([string]$tag.Command) 30 | Out-Null; return }
  & $tag.Action
}

function Invoke-ServiceMenuAction($sender) {
  $tag = $sender.Tag
  if ($null -eq $tag) { return }
  Invoke-ServiceAction $tag.Service $tag.Action
}

function Exit-Overlay {
  Hide-Settings
  $script:Quitting = $true
  foreach ($key in @($script:Loaded.Keys)) { Remove-ScriptFeature $key }
  try { $script:TrayIcon.Visible = $false; $script:TrayIcon.Dispose() } catch { }
  $script:Window.Close()
}

function Rebuild-TrayMenu {
  if ($null -eq $script:Menu) { return }
  if ($script:MenuOpen) { $script:TrayDirty = $true; return }
  $script:TrayDirty = $false
  $script:Menu.Items.Clear()
  $script:ShowItem = New-MenuItem 'Показать оверлей' { Toggle-Overlay } $false
  $script:ActiveItem = New-MenuItem 'Фича: —' $null $false
  $script:ActiveItem.Enabled = $false
  $script:Menu.Items.Add($script:ShowItem) | Out-Null
  $script:Menu.Items.Add($script:ActiveItem) | Out-Null
  $script:Menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

  $featuresMenu = New-Object System.Windows.Forms.ToolStripMenuItem
  $featuresMenu.Text = 'Фичи'
  foreach ($feature in $script:Features) {
    $item = New-MenuItem ([string]$feature.Title) { param($sender, $eventArgs) Switch-Feature ([string]$sender.Tag) $true; Show-Overlay } $false
    $item.Tag = $feature.Id
    $featuresMenu.DropDownItems.Add($item) | Out-Null
  }
  $script:Menu.Items.Add($featuresMenu) | Out-Null

  foreach ($feature in $script:Features) {
    $entries = New-Object System.Collections.ArrayList
    if ($script:FeatureTrayItems.ContainsKey($feature.Id)) {
      foreach ($entry in $script:FeatureTrayItems[$feature.Id]) { [void]$entries.Add($entry) }
    }
    foreach ($declared in @($feature.TrayItems)) {
      if ($null -eq $declared -or $null -eq $declared.label) { continue }
      [void]$entries.Add(@{ Label = [string]$declared.label; Command = [string]$declared.command })
    }
    if ($entries.Count -eq 0) { continue }
    $submenu = New-Object System.Windows.Forms.ToolStripMenuItem
    $submenu.Text = [string]$feature.Title
    foreach ($entry in $entries) {
      $item = New-Object System.Windows.Forms.ToolStripMenuItem
      $item.Text = [string]$entry.Label
      if ($entry.ContainsKey('Command')) {
        $item.Tag = @{ Kind = 'command'; Command = [string]$entry.Command }
      } else {
        $item.Tag = @{ Kind = 'script'; Action = $entry.Action }
      }
      $item.Add_Click({ param($sender, $eventArgs) Invoke-TrayEntryAction $sender })
      $submenu.DropDownItems.Add($item) | Out-Null
    }
    $script:Menu.Items.Add($submenu) | Out-Null
  }

  $script:ServiceEntries = @{}
  foreach ($feature in $script:Features) {
    if ($feature.Kind -ne 'service') { continue }
    $serviceName = $feature.Service
    $title = [string]$feature.Title
    $entry = @{
      Service = $serviceName
      Title = $title
      State = New-MenuItem ($title + ': …') $null $false
      Start = New-MenuItem ($title + ': запустить') { param($sender, $eventArgs) Invoke-ServiceMenuAction $sender } $false
      Stop = New-MenuItem ($title + ': остановить') { param($sender, $eventArgs) Invoke-ServiceMenuAction $sender } $false
      Restart = New-MenuItem ($title + ': перезапустить') { param($sender, $eventArgs) Invoke-ServiceMenuAction $sender } $false
    }
    $entry.State.Enabled = $false
    $entry.Start.Tag = @{ Service = $serviceName; Action = 'start' }
    $entry.Stop.Tag = @{ Service = $serviceName; Action = 'stop' }
    $entry.Restart.Tag = @{ Service = $serviceName; Action = 'restart' }
    $script:ServiceEntries[$feature.Id] = $entry
    $script:Menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
    $script:Menu.Items.Add($entry.State) | Out-Null
    $script:Menu.Items.Add($entry.Start) | Out-Null
    $script:Menu.Items.Add($entry.Stop) | Out-Null
    $script:Menu.Items.Add($entry.Restart) | Out-Null
  }

  $script:Menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
  $settingsItem = New-MenuItem '⚙ Настройки…' { Show-Settings } $false
  $script:Menu.Items.Add($settingsItem) | Out-Null
  $exit = New-MenuItem 'Выход' { Exit-Overlay } $false
  $script:Menu.Items.Add($exit) | Out-Null
  Update-TrayMenuState
}

function Update-TrayMenuState {
  if ($null -eq $script:ShowItem) { return }
  $script:ShowItem.Text = $(if ($script:Window.IsVisible) { 'Скрыть оверлей' } else { 'Показать оверлей' })
  $active = Get-ActiveFeature
  if ($null -ne $script:ActiveItem) { $script:ActiveItem.Text = 'Фича: ' + $(if ($null -eq $active) { '—' } else { $active.Title }) }
  foreach ($featureId in $script:ServiceEntries.Keys) {
    $entry = $script:ServiceEntries[$featureId]
    $state = Get-ServiceState $entry.Service
    $stateText = $(switch ($state) { 'Running' { 'работает' } 'Stopped' { 'остановлена' } 'Missing' { 'не найдена' } default { '?' } })
    $entry.State.Text = ($entry.Title + ': ' + $stateText)
    $running = $state -eq 'Running'
    $entry.Start.Enabled = -not $running
    $entry.Stop.Enabled = $running
    $entry.Restart.Enabled = $running
  }
}

$script:Menu = New-Object System.Windows.Forms.ContextMenuStrip
$script:Menu.ShowImageMargin = $false
$script:Menu.Add_Opening({
  $script:MenuOpen = $true
  Update-TrayMenuState
})
$script:Menu.Add_Closed({
  $script:MenuOpen = $false
  if ($script:TrayDirty) { Rebuild-TrayMenu }
})

foreach ($featureId in @($script:Loaded.Keys)) {
  $entry = $script:Loaded[$featureId]
  Invoke-FeatureHook $entry 'Initialize-Feature' $entry.Api
}

# ---------------------------------------------------------------- window actions
function Show-Balloon([string]$title, [string]$text) {
  try {
    $script:TrayIcon.BalloonTipTitle = $title
    $script:TrayIcon.BalloonTipText = $text
    $script:TrayIcon.ShowBalloonTip(2500)
  } catch { }
}

function Show-Overlay {
  $script:Window.Show()
  if ($script:Window.WindowState -eq 'Minimized') { $script:Window.WindowState = 'Normal' }
  $script:Window.Topmost = $true
  $script:Window.Activate() | Out-Null
}

function Hide-Overlay {
  $script:Window.Hide()
  if (-not $script:HideHintShown) {
    $script:HideHintShown = $true
    Show-Balloon 'Оверлей' 'Свёрнуто в трей. Вернуть — двойным кликом по иконке.'
  }
}

function Toggle-Overlay {
  if ($script:Window.IsVisible) { Hide-Overlay } else { Show-Overlay }
}

# ---------------------------------------------------------------- switch and reload
function Switch-Feature([string]$id, [bool]$force) {
  if ($env:DSH_OVERLAY_DEBUG) { Add-HostLog ('debug: switch ' + $id + ' force=' + $force) }
  if ($script:ActiveFeatureId -eq $id -and -not $force) { return }
  if (-not ($script:Features | Where-Object { $_.Id -eq $id })) { return }
  $script:ActiveFeatureId = $id
  Update-ChipStyles
  $script:Status.Text = ''
  Render-ActiveFeature
  Refresh-ActiveFeature
}

function Reload-Features {
  $signature = Get-FeaturesSignature
  if ($signature -eq $script:FeatureSignature) { return }
  $script:FeatureSignature = $signature
  $script:AllFeatures = Read-Features
  $newFeatures = Sort-Features (Get-EffectiveFeatures $script:AllFeatures)
  $newById = @{}
  foreach ($feature in $newFeatures) { $newById[$feature.Id] = $feature }

  foreach ($id in @($script:Loaded.Keys)) {
    $entry = $script:Loaded[$id]
    $still = $newById[$id]
    if ($null -eq $still) { Remove-ScriptFeature $id; continue }
    $entryTicks = if (Test-Path -LiteralPath $still.Entry) { (Get-Item -LiteralPath $still.Entry).LastWriteTimeUtc.Ticks } else { 0 }
    $descriptorTicks = (Get-Item -LiteralPath (Join-Path $still.Dir 'feature.json')).LastWriteTimeUtc.Ticks
    if ($entryTicks -ne $entry.EntryTicks -or $descriptorTicks -ne $entry.DescriptorTicks) { Remove-ScriptFeature $id }
  }

  $script:Features = $newFeatures
  foreach ($feature in $script:Features) {
    if (-not $script:Runtime.ContainsKey($feature.Id)) {
      $script:Runtime[$feature.Id] = @{ StatusText = '…'; Output = ''; LastRefresh = [datetime]::MinValue; LastCheck = [datetime]::MinValue }
    }
    if ($feature.Kind -ne 'script') { continue }
    if ($script:Loaded.ContainsKey($feature.Id)) { continue }
    try { Import-ScriptFeature $feature } catch { Add-HostLog ('feature ' + $feature.Id + ': ' + ($_ | Out-String)) }
  }

  $script:Order.Clear()
  foreach ($feature in $script:Features) { $script:Order.Add($feature.Id) }
  $script:DragId = ''
  Rebuild-Strip
  Rebuild-TrayMenu

  if (-not ($script:Features | Where-Object { $_.Id -eq $script:ActiveFeatureId })) {
    $first = $script:Features | Select-Object -First 1
    $script:ActiveFeatureId = ''
    if ($null -ne $first) { Switch-Feature $first.Id $true } else {
      $script:ContentHost.Children.Clear()
      $script:Summary.Text = ''
      $script:Status.Text = ''
    }
  } else {
    Render-ActiveFeature
    Refresh-ActiveFeature
  }
}

# ---------------------------------------------------------------- initial UI
foreach ($feature in $script:Features) { $script:Order.Add($feature.Id) }
Rebuild-Strip

# strip drag: capture lives on the strip, so rebuilding chips mid-drag keeps events flowing
function Complete-ChipDrag($sender, $eventArgs) {
  if ($env:DSH_OVERLAY_DEBUG) { Add-HostLog ('debug: strip up dragId=[' + $script:DragId + '] moved=' + $script:DragMoved) }
  if ($script:DragId -eq '') { return }
  $id = $script:DragId
  $moved = $script:DragMoved
  $script:DragId = ''
  $script:DragMoved = $false
  $script:FeatureStrip.ReleaseMouseCapture() | Out-Null
  if ($moved) { Save-FeatureOrder } else { Switch-Feature $id $false }
}

function Update-ChipDrag([double]$pointerX) {
  try {
    if ($script:DragId -eq '') { return }
    $delta = [Math]::Abs($pointerX - $script:DragStartX)
    if (-not $script:DragMoved -and $delta -lt 6) { return }
    $script:DragMoved = $true
    $current = $script:Order.IndexOf($script:DragId)
    if ($current -lt 0) { return }
    $target = $script:Order.Count - 1
    for ($i = 0; $i -lt $script:Order.Count; $i++) {
      $chip = $script:Chips[$script:Order[$i]]
      if ($null -eq $chip) { continue }
      $origin = $chip.TransformToAncestor($script:FeatureStrip).Transform((New-Object System.Windows.Point -ArgumentList @(0, 0)))
      $center = $origin.X + ([double]$chip.ActualWidth / 2)
      if ($env:DSH_OVERLAY_DEBUG) { Add-HostLog ('debug: drag i=' + $i + ' center=' + [Math]::Round($center, 1)) }
      if ($pointerX -lt $center) { $target = $i; break }
    }
    if ($target -ne $current) {
      $script:Order.RemoveAt($current)
      $insert = if ($target -gt $current) { $target - 1 } else { $target }
      if ($insert -lt 0) { $insert = 0 }
      if ($insert -gt $script:Order.Count) { $insert = $script:Order.Count }
      $script:Order.Insert($insert, $script:DragId)
      Rebuild-Strip
    }
  } catch {
    Add-HostLog ('drag error: ' + ($_ | Out-String))
  }
}

$script:FeatureStrip.Add_MouseMove({
  param($sender, $eventArgs)
  if ($env:DSH_OVERLAY_DEBUG) { Add-HostLog ('debug: move dragId=[' + $script:DragId + '] order=' + $script:Order.GetType().Name + ' chips=' + $script:Chips.GetType().Name) }
  if ($eventArgs -is [System.Windows.Input.MouseEventArgs]) {
    Update-ChipDrag $eventArgs.GetPosition($script:FeatureStrip).X
  }
})
$script:FeatureStrip.Add_MouseLeftButtonUp({
  param($sender, $eventArgs)
  Complete-ChipDrag $sender $eventArgs
})
$script:FeatureStrip.Add_LostMouseCapture({
  param($sender, $eventArgs)
  $script:DragId = ''
  $script:DragMoved = $false
})

# tray icon
$script:TrayBitmap = New-Object System.Drawing.Bitmap 32, 32
$script:TrayGraphics = [System.Drawing.Graphics]::FromImage($script:TrayBitmap)
$script:TrayGraphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$script:TrayGraphics.Clear([System.Drawing.Color]::Transparent)
$trayBackground = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 31, 111, 235))
$trayDot = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 126, 226, 168))
$script:TrayGraphics.FillEllipse($trayBackground, 1, 1, 30, 30)
$script:TrayGraphics.FillEllipse($trayDot, 11, 11, 10, 10)
$trayBackground.Dispose()
$trayDot.Dispose()
$script:TrayGraphics.Dispose()
$script:TrayHandle = $script:TrayBitmap.GetHicon()

$script:TrayIcon = New-Object System.Windows.Forms.NotifyIcon
$script:TrayIcon.Icon = [System.Drawing.Icon]::FromHandle($script:TrayHandle)
$script:TrayIcon.Text = 'Оверлей · фичи и службы'
$script:TrayIcon.ContextMenuStrip = $script:Menu
$script:TrayIcon.Visible = $true
$script:TrayIcon.Add_DoubleClick({ Toggle-Overlay })

Rebuild-TrayMenu

# window events
$script:Window.Add_LocationChanged({ $script:Dirty = $true })
$script:Window.Add_SizeChanged({ $script:Dirty = $true })
$script:Header.Add_MouseLeftButtonDown({
  try { $script:Window.DragMove() } catch { }
})
$script:CloseButton.Add_Click({ Hide-Overlay })
$script:Window.Add_Closing({
  param($sender, $eventArgs)
  if (-not $script:Quitting) { $eventArgs.Cancel = $true; Hide-Overlay }
})

# ---------------------------------------------------------------- timer
$script:LastFocusTime = [datetime]::MinValue
$script:FeatureSignature = Get-FeaturesSignature
$script:Timer = New-Object System.Windows.Threading.DispatcherTimer
$script:Timer.Interval = [TimeSpan]::FromMilliseconds(400)
$script:Timer.Add_Tick({
  try {
  if ($script:Dirty) { $script:Dirty = $false; try { Save-Bounds } catch { } }

  $now = Get-Date
  if (($now - $script:LastReloadCheck).TotalSeconds -ge 1.2) {
    $script:LastReloadCheck = $now
    try { Reload-Features } catch { Add-HostLog ('reload: ' + ($_ | Out-String)) }
  }

  $active = Get-ActiveFeature
  if ($null -ne $active) {
    switch ($active.Kind) {
      'script' {
        $entry = $script:Loaded[$active.Id]
        if ($null -ne $entry) { Invoke-FeatureHook $entry 'Update-Feature' $entry.Api }
      }
      'service' {
        $runtime = $script:Runtime[$active.Id]
        if (($now - $runtime.LastCheck).TotalSeconds -ge 2) {
          $runtime.LastCheck = $now
          Render-Service $active
        }
      }
      'commands' {
        if ($active.Status -ne '') {
          $runtime = $script:Runtime[$active.Id]
          if (($now - $runtime.LastRefresh).TotalSeconds -ge $active.RefreshSeconds) {
            $runtime.StatusText = Invoke-CommandText $active.Status 10
            $runtime.LastRefresh = $now
            Render-Commands $active
          }
        }
      }
    }
  }

if ($script:TrayFlags.Rebuild -and -not $script:MenuOpen) {
    $script:TrayFlags.Rebuild = $false
    try { Rebuild-TrayMenu } catch { Add-HostLog ('tray rebuild: ' + ($_ | Out-String)) }
  }

  if (Test-Path -LiteralPath $script:FocusPath) {
    $focus = (Get-Item -LiteralPath $script:FocusPath).LastWriteTime
    if ($focus -gt $script:LastFocusTime) {
      $script:LastFocusTime = $focus
      try { Show-Overlay } catch { }
    }
  }

  if ($null -ne $script:AutoExitAt -and $now -ge $script:AutoExitAt) {
    $script:Quitting = $true
    $script:Window.Close()
  }
  } catch {
    Add-HostLog ('tick: ' + ($_ | Out-String))
  }
})
$script:Timer.Start()

$script:Window.Add_Closed({
  $script:Timer.Stop()
  foreach ($key in @($script:Loaded.Keys)) { Remove-ScriptFeature $key }
  try { $script:TrayIcon.Visible = $false; $script:TrayIcon.Dispose() } catch { }
  try { $script:Mutex.ReleaseMutex() } catch { }
})

# ---------------------------------------------------------------- start
$initial = $script:PreferredFeature
if ($initial -eq '' -or -not ($script:Features | Where-Object { $_.Id -eq $initial })) {
  $first = $script:Features | Select-Object -First 1
  $initial = if ($null -eq $first) { '' } else { $first.Id }
}
if ($initial -ne '') { Switch-Feature $initial $true }

$script:App = New-Object System.Windows.Application
$script:App.Add_DispatcherUnhandledException({
  param($sender, $eventArgs)
  try { Add-HostLog ('unhandled: ' + $eventArgs.Exception.Message + "`n" + $eventArgs.Exception.StackTrace) } catch { }
  try { Show-Balloon 'Ошибка оверлея' ([string]$eventArgs.Exception.Message) } catch { }
  $eventArgs.Handled = $true
})

$script:App.ShutdownMode = 'OnMainWindowClose'
if ($env:DSH_OVERLAY_SELFTEST) {
  $script:SelfTest = New-Object System.Windows.Threading.DispatcherTimer
  $script:SelfTest.Interval = [TimeSpan]::FromSeconds(2)
  $script:SelfTest.Add_Tick({
    $script:SelfTest.Stop()
    try {
      foreach ($feature in @($script:Features)) { Switch-Feature $feature.Id $true }
      $first = $script:Features | Select-Object -First 1
      if ($null -ne $first) { Switch-Feature $first.Id $true }
      Add-HostLog 'selftest: switched through all features'
      if ($env:DSH_OVERLAY_SELFTEST_CLICK) {
        $target = $script:Features | Select-Object -Skip 1 -First 1
        if ($null -eq $target) { $target = $script:Features | Select-Object -First 1 }
        if ($null -ne $target) {
          $script:DragId = $target.Id
          $script:DragMoved = $false
          Complete-ChipDrag $script:FeatureStrip $null
          Add-HostLog ('selftest: click path -> ' + $script:ActiveFeatureId)
          if ($env:DSH_OVERLAY_SELFTEST_DRAG) {
            $script:DragId = $target.Id
            $script:DragStartX = 10000
            $script:DragMoved = $false
            Add-HostLog ('selftest: before drag = ' + ($script:Order -join ','))
            Update-ChipDrag 0
            Add-HostLog ('selftest: after drag = ' + ($script:Order -join ','))
            $script:DragMoved = $true
            Complete-ChipDrag $script:FeatureStrip $null
            Add-HostLog ('selftest: saved order -> ' + (Get-Content $script:OrderPath -Raw))
            $script:DragId = ''
            Add-HostLog ('selftest: drag order -> ' + (Get-Content $script:OrderPath -Raw))
          }
          if ($env:DSH_OVERLAY_SELFTEST_SETTINGS) {
            Show-Settings
            Add-HostLog 'selftest: settings window opened'
          }
        }
      }
    } catch {
      Add-HostLog ('selftest: ' + ($_ | Out-String))
    }
  })
  $script:SelfTest.Start()
}

Apply-Presentation
[void]$script:App.Run($script:Window)

