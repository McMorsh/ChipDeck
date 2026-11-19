#requires -Version 5.1
<#
    Удаление ChipDeck.

    Останавливает оверлей, убирает ярлыки и автозапуск, при необходимости
    отключает плагин DSH и удаляет настройки.
#>

param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'Programs\ChipDeck'),
    [switch]$RemoveDshPlugin,
    [switch]$RemoveSettings
)

$ErrorActionPreference = 'Stop'

$script:LogPath = Join-Path $env:TEMP 'chipdeck-uninstall.log'
$script:BundleName = '@local/dsh-agent-overlay'

function Write-Log([string]$text) {
    $line = (Get-Date -Format 'HH:mm:ss') + '  ' + $text
    Write-Host $line
    try { Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8 } catch { }
}

function Stop-ChipDeck {
    $processes = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*chipdeck.ps1*' }
    foreach ($process in $processes) {
        Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
        Write-Log ('Stopped ChipDeck, PID ' + $process.ProcessId)
    }
}

function Find-DshCommand {
    $command = Get-Command dsh -ErrorAction SilentlyContinue
    if ($null -ne $command) { return $command.Source }
    $candidates = @(
        (Join-Path $env:APPDATA 'npm\dsh.cmd'),
        (Join-Path $env:LOCALAPPDATA 'pnpm\dsh.cmd')
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $null
}

function Find-DshProfile {
    if ($env:DSH_PROFILE) { return $env:DSH_PROFILE }
    $root = Join-Path $env:USERPROFILE '.dsh\profiles'
    if (-not (Test-Path -LiteralPath $root)) { return $null }
    $profiles = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)
    if ($profiles.Count -eq 0) { return $null }
    $web = $profiles | Where-Object { $_.Name -eq 'web' } | Select-Object -First 1
    if ($null -ne $web) { return $web.Name }
    return ($profiles | Sort-Object LastWriteTime -Descending | Select-Object -First 1).Name
}

function Remove-BundleFromProfile([string]$profileName) {
    $packagePath = Join-Path (Join-Path (Join-Path $env:USERPROFILE '.dsh\profiles') $profileName) 'package.json'
    if (-not (Test-Path -LiteralPath $packagePath)) { return }
    $text = [System.IO.File]::ReadAllText($packagePath, [System.Text.Encoding]::UTF8)
    $json = $text | ConvertFrom-Json
    if ($null -eq $json.dsh -or $null -eq $json.dsh.profile) { return }
    $bundles = @()
    if ($null -ne $json.dsh.profile.bundles) { $bundles = @($json.dsh.profile.bundles) }
    if ($bundles -notcontains $script:BundleName) { return }
    $bundles = @($bundles | Where-Object { $_ -ne $script:BundleName })
    $json.dsh.profile = [pscustomobject]@{ bundles = $bundles }
    Copy-Item -LiteralPath $packagePath -Destination ($packagePath + '.chipdeck-backup') -Force
    [System.IO.File]::WriteAllText($packagePath, ($json | ConvertTo-Json -Depth 12), (New-Object System.Text.UTF8Encoding($false)))
    Write-Log 'Plugin removed from the DSH profile.'
}

Write-Log '=== ChipDeck uninstaller ==='
$InstallDir = [System.IO.Path]::GetFullPath($InstallDir)

Stop-ChipDeck

foreach ($shortcut in @(
    (Join-Path ([Environment]::GetFolderPath('Programs')) 'ChipDeck.lnk'),
    (Join-Path ([Environment]::GetFolderPath('Startup')) 'ChipDeck.lnk')
)) {
    if (Test-Path -LiteralPath $shortcut) {
        Remove-Item -LiteralPath $shortcut -Force
        Write-Log ('Removed shortcut: ' + $shortcut)
    }
}

if ($RemoveDshPlugin) {
    $dshCommand = Find-DshCommand
    $profileName = Find-DshProfile
    if ($null -ne $dshCommand -and $null -ne $profileName) {
        Write-Log 'Disabling the DSH plugin...'
        & $dshCommand plugin --profile $profileName remove $script:BundleName 2>&1 |
            ForEach-Object { Write-Log ([string]$_) }
        Remove-BundleFromProfile $profileName
    } else {
        Write-Log 'dsh or the profile was not found; the plugin was not disabled.'
    }
}

if ($RemoveSettings) {
    $settingsDir = Join-Path $env:LOCALAPPDATA 'chipdeck'
    if (Test-Path -LiteralPath $settingsDir) {
        Remove-Item -LiteralPath $settingsDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log ('Removed settings: ' + $settingsDir)
    }
}

if (Test-Path -LiteralPath $InstallDir) {
    Write-Log ('Removing ' + $InstallDir)
    try {
        Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction Stop
    } catch {
        Write-Log ('Could not remove the directory: ' + $_.Exception.Message)
    }
}

Write-Log 'Uninstall finished.'
