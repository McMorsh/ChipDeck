# Settings for the overlay host: persisted preferences, the effective feature
# list and the settings window behind the tray gear.
#
# Dot-sourced into overlay.ps1 at script scope, so `$script:` here is the
# host's script scope and every host function is callable.

$script:Settings = $null
$script:SettingsWindow = $null

function Read-Settings {
  $settings = @{ Opacity = 1.0; Topmost = $true; Enabled = @{} }
  if (-not (Test-Path -LiteralPath $script:SettingsPath)) { return $settings }
  try {
    $raw = Get-Content -LiteralPath $script:SettingsPath -Raw | ConvertFrom-Json
    if ($null -ne $raw.opacity) {
      $opacity = [double]$raw.opacity
      if ($opacity -lt 0.3) { $opacity = 0.3 }
      if ($opacity -gt 1.0) { $opacity = 1.0 }
      $settings.Opacity = $opacity
    }
    if ($null -ne $raw.topmost) { $settings.Topmost = [bool]$raw.topmost }
    if ($null -ne $raw.enabled) {
      foreach ($property in $raw.enabled.PSObject.Properties) {
        $settings.Enabled[$property.Name] = [bool]$property.Value
      }
    }
  } catch {
    Add-HostLog ('settings: ' + ($_ | Out-String))
  }
  return $settings
}

function Save-Settings {
  $state = @{
    opacity = [Math]::Round([double]$script:Settings.Opacity, 2)
    topmost = [bool]$script:Settings.Topmost
    enabled = $script:Settings.Enabled
  }
  try { Write-JsonFile $script:SettingsPath (ConvertTo-Json -InputObject $state -Depth 4 -Compress) } catch { Add-HostLog ('settings save: ' + ($_ | Out-String)) }
}

function Test-FeatureEnabled($feature) {
  $enabled = [bool]$feature.Configured
  if ($script:Settings.Enabled.ContainsKey($feature.Id)) { $enabled = [bool]$script:Settings.Enabled[$feature.Id] }
  return $enabled
}

function Get-EffectiveFeatures($all) {
  $result = @()
  foreach ($feature in @($all)) {
    if (Test-FeatureEnabled $feature) { $result += $feature }
  }
  return $result
}

function Apply-Presentation {
  if ($null -eq $script:Window) { return }
  $script:Window.Opacity = [double]$script:Settings.Opacity
  $script:Window.Topmost = [bool]$script:Settings.Topmost
}

function Set-FeatureEnabled([string]$id, [bool]$enabled) {
  if ($id -eq '') { return }
  $script:Settings.Enabled[$id] = $enabled
  Save-Settings
  $script:FeatureSignature = ''
  Reload-Features
  Rebuild-TrayMenu
}

function Update-Opacity([double]$percent) {
  $value = $percent
  if ($value -lt 30) { $value = 30 }
  if ($value -gt 100) { $value = 100 }
  $script:Settings.Opacity = [Math]::Round($value / 100.0, 2)
  if ($null -ne $script:Window) { $script:Window.Opacity = $script:Settings.Opacity }
  if ($null -ne $script:SettingsWindow) {
    $label = $script:SettingsWindow.FindName('OpacityLabel')
    if ($null -ne $label) { $label.Text = 'Прозрачность: ' + [int][Math]::Round($value) + '%' }
  }
}

function Set-OverlayTopmost([bool]$value) {
  $script:Settings.Topmost = $value
  if ($null -ne $script:Window) { $script:Window.Topmost = $value }
  Save-Settings
}

function New-SettingsWindow {
  $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Настройки оверлея" Width="400" SizeToContent="Height"
        WindowStyle="ToolWindow" ResizeMode="NoResize" ShowInTaskbar="False"
        WindowStartupLocation="CenterOwner" Background="#F5161619"
        FontFamily="Segoe UI" TextOptions.TextFormattingMode="Display">
  <Border Margin="14" Background="#16161A" CornerRadius="10" BorderThickness="1" BorderBrush="#2BFFFFFF" Padding="14">
    <StackPanel>
      <TextBlock Text="ФИЧИ" FontSize="10" FontWeight="Bold" Foreground="#8A8A96" Margin="0,0,0,8"/>
      <ScrollViewer MaxHeight="280" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
        <StackPanel x:Name="FeatureList"/>
      </ScrollViewer>
      <TextBlock Text="ВИД" FontSize="10" FontWeight="Bold" Foreground="#8A8A96" Margin="0,16,0,8"/>
      <TextBlock x:Name="OpacityLabel" Text="Прозрачность: 100%" FontSize="12" Foreground="#D7D7DE"/>
      <Slider x:Name="OpacitySlider" Minimum="30" Maximum="100" Margin="0,4,0,12" IsSnapToTickEnabled="True" TickFrequency="1"/>
      <CheckBox x:Name="TopmostBox" Content="Поверх всех окон" Foreground="#F0F0F3" FontSize="12" Margin="0,0,0,16"/>
      <Button x:Name="DoneButton" Content="Готово" HorizontalAlignment="Right" Padding="16,6" BorderThickness="0" Background="#2A2A31" Foreground="#F0F0F3" FontSize="12" Cursor="Hand"/>
    </StackPanel>
  </Border>
</Window>
'@
  $window = [System.Windows.Markup.XamlReader]::Parse($xaml)
  $window.Owner = $script:Window

  $done = $window.FindName('DoneButton')
  $done.Add_Click({ param($sender, $eventArgs) Hide-Settings })

  $slider = $window.FindName('OpacitySlider')
  $slider.Add_ValueChanged({ param($sender, $eventArgs) Update-Opacity ([double]$sender.Value) })
  $slider.Add_LostMouseCapture({ param($sender, $eventArgs) Save-Settings })

  $topmost = $window.FindName('TopmostBox')
  $topmost.Add_Checked({ param($sender, $eventArgs) Set-OverlayTopmost $true })
  $topmost.Add_Unchecked({ param($sender, $eventArgs) Set-OverlayTopmost $false })

  $window.Add_Closing({
    param($sender, $eventArgs)
    if (-not $script:Quitting) {
      $eventArgs.Cancel = $true
      Hide-Settings
    }
  })
  return $window
}

function Refresh-SettingsWindow {
  if ($null -eq $script:SettingsWindow) { return }
  $list = $script:SettingsWindow.FindName('FeatureList')
  if ($null -eq $list) { return }
  $list.Children.Clear()
  foreach ($feature in @($script:AllFeatures)) {
    $box = New-Object System.Windows.Controls.CheckBox
    $box.Content = ('{0}  ·  {1}' -f $feature.Title, $feature.Kind)
    $box.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#F0F0F3')
    $box.FontSize = 12
    $box.Margin = New-Object System.Windows.Thickness(0, 3, 0, 3)
    $box.Tag = $feature.Id
    $box.IsChecked = (Test-FeatureEnabled $feature)
    $box.Add_Checked({ param($sender, $eventArgs) Set-FeatureEnabled ([string]$sender.Tag) $true })
    $box.Add_Unchecked({ param($sender, $eventArgs) Set-FeatureEnabled ([string]$sender.Tag) $false })
    $list.Children.Add($box) | Out-Null
  }
  $slider = $script:SettingsWindow.FindName('OpacitySlider')
  if ($null -ne $slider) { $slider.Value = [Math]::Round([double]$script:Settings.Opacity * 100) }
  $label = $script:SettingsWindow.FindName('OpacityLabel')
  if ($null -ne $label) { $label.Text = 'Прозрачность: ' + [int][Math]::Round([double]$script:Settings.Opacity * 100) + '%' }
  $topmost = $script:SettingsWindow.FindName('TopmostBox')
  if ($null -ne $topmost) { $topmost.IsChecked = [bool]$script:Settings.Topmost }
}

function Show-Settings {
  if ($null -eq $script:SettingsWindow) { $script:SettingsWindow = New-SettingsWindow }
  if (-not $script:Window.IsVisible) { Show-Overlay }
  $script:SettingsWindow.Owner = $script:Window
  Refresh-SettingsWindow
  $script:SettingsWindow.Topmost = $true
  $script:SettingsWindow.Show()
  $script:SettingsWindow.Activate() | Out-Null
}

function Hide-Settings {
  if ($null -eq $script:SettingsWindow) { return }
  Save-Settings
  $script:SettingsWindow.Hide()
}
