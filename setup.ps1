#requires -Version 5.1
<#
    Первый запуск ChipDeck из репозитория.

    Определяет профиль DSH, спрашивает, подключать ли агентов, ставит
    клиентский плагин-мост в профиль (через junction, без pnpm), сохраняет
    выбор фичи в settings.json и запускает оверлей.

    Примеры:
        .\setup.cmd
        .\setup.ps1 -WithDsh
        .\setup.ps1 -WithoutDsh -NoLaunch
        .\setup.ps1 -Install
#>

param(
    [switch]$WithDsh,
    [switch]$WithoutDsh,
    [string]$AppDir = $PSScriptRoot,
    [string]$Profile = '',
    [string]$ProfileDir = '',
    [string]$SettingsDir = (Join-Path $env:LOCALAPPDATA 'chipdeck'),
    [switch]$Install,
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'Programs\ChipDeck'),
    [switch]$NoLaunch,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'

$script:BundleName = '@local/dsh-agent-overlay'
$pluginInstalled = $false
$script:Warnings = New-Object System.Collections.Generic.List[string]

function Write-Step([string]$text) {
    Write-Host ('  ' + $text)
}

function Write-Warn([string]$text) {
    $script:Warnings.Add($text)
    Write-Host ('  WARNING: ' + $text)
}

function Resolve-ProfileDir {
    if ($ProfileDir -ne '') {
        $candidate = [System.IO.Path]::GetFullPath($ProfileDir)
        if (Test-Path -LiteralPath $candidate) { return $candidate }
        return $null
    }
    $root = Join-Path $env:USERPROFILE '.dsh\profiles'
    if (-not (Test-Path -LiteralPath $root)) { return $null }
    $name = $Profile
    if ($name -eq '' -and $env:DSH_PROFILE) { $name = $env:DSH_PROFILE }
    if ($name -eq '' -and (Test-Path -LiteralPath (Join-Path $root 'web'))) { $name = 'web' }
    if ($name -eq '') {
        $profiles = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)
        if ($profiles.Count -eq 0) { return $null }
        $name = ($profiles | Sort-Object LastWriteTime -Descending | Select-Object -First 1).Name
    }
    $dir = Join-Path $root $name
    if (Test-Path -LiteralPath $dir) { return $dir }
    return $null
}

function Read-ProfileJson([string]$packagePath) {
    if (-not (Test-Path -LiteralPath $packagePath)) {
        return [pscustomobject]@{
            name = 'dsh-profile'
            private = $true
            dependencies = [pscustomobject]@{}
            dsh = [pscustomobject]@{ profile = [pscustomobject]@{ bundles = @() } }
        }
    }
    $text = [System.IO.File]::ReadAllText($packagePath, [System.Text.Encoding]::UTF8)
    return ($text | ConvertFrom-Json)
}

function Install-PluginBundle([string]$profileDir, [string]$appDir) {
    $pluginSource = Join-Path $appDir 'dsh-plugin'
    if (-not (Test-Path -LiteralPath (Join-Path $pluginSource 'package.json'))) {
        throw ('dsh-plugin is missing: ' + $pluginSource)
    }

    $scopeDir = Join-Path $profileDir 'node_modules\@local'
    New-Item -ItemType Directory -Path $scopeDir -Force | Out-Null
    $linkPath = Join-Path $scopeDir 'dsh-agent-overlay'
    if (Test-Path -LiteralPath $linkPath) {
        (Get-Item -LiteralPath $linkPath -Force).Delete()
    }
    New-Item -ItemType Junction -Path $linkPath -Target $pluginSource | Out-Null
    Write-Step ('Plugin linked: ' + $linkPath)

    $packagePath = Join-Path $profileDir 'package.json'
    $json = Read-ProfileJson $packagePath
    if ($null -eq $json.dependencies) {
        $json | Add-Member -MemberType NoteProperty -Name dependencies -Value ([pscustomobject]@{})
    }
    $linkSpec = 'link:' + ($pluginSource -replace '\\', '/')
    $json.dependencies | Add-Member -MemberType NoteProperty -Name $script:BundleName -Value $linkSpec -Force

    if ($null -eq $json.dsh) {
        $json | Add-Member -MemberType NoteProperty -Name dsh -Value ([pscustomobject]@{})
    }
    if ($null -eq $json.dsh.profile) {
        $json.dsh | Add-Member -MemberType NoteProperty -Name profile -Value ([pscustomobject]@{})
    }
    $bundles = @()
    if ($null -ne $json.dsh.profile.bundles) { $bundles = @($json.dsh.profile.bundles) }
    if ($bundles -notcontains $script:BundleName) { $bundles += $script:BundleName }
    $json.dsh.profile = [pscustomobject]@{ bundles = $bundles }

    if (Test-Path -LiteralPath $packagePath) {
        Copy-Item -LiteralPath $packagePath -Destination ($packagePath + '.chipdeck-backup') -Force
    }
    [System.IO.File]::WriteAllText($packagePath, ($json | ConvertTo-Json -Depth 12), (New-Object System.Text.UTF8Encoding($false)))
    Write-Step ('Profile updated: ' + $packagePath)
}

function Save-FeatureChoice([bool]$enableAgents) {
    New-Item -ItemType Directory -Path $SettingsDir -Force | Out-Null
    $settingsPath = Join-Path $SettingsDir 'settings.json'
    $settings = @{ opacity = 1.0; topmost = $true; enabled = @{} }
    if (Test-Path -LiteralPath $settingsPath) {
        try {
            $raw = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
            if ($null -ne $raw.opacity) { $settings.opacity = [double]$raw.opacity }
            if ($null -ne $raw.topmost) { $settings.topmost = [bool]$raw.topmost }
            if ($null -ne $raw.enabled) {
                foreach ($property in $raw.enabled.PSObject.Properties) {
                    $settings.enabled[$property.Name] = [bool]$property.Value
                }
            }
        } catch { }
    }
    $settings.enabled['dsh-agents'] = $enableAgents
    $serialized = @{
        opacity = [Math]::Round([double]$settings.opacity, 2)
        topmost = [bool]$settings.topmost
        enabled = $settings.enabled
    } | ConvertTo-Json -Depth 4 -Compress
    [System.IO.File]::WriteAllText($settingsPath, $serialized, (New-Object System.Text.UTF8Encoding($false)))
    Write-Step ('Settings: dsh-agents = ' + $enableAgents)
}

Write-Host ''
Write-Host 'ChipDeck: first run'
Write-Host ''

$AppDir = [System.IO.Path]::GetFullPath($AppDir)
if (-not (Test-Path -LiteralPath (Join-Path $AppDir 'host\chipdeck.ps1'))) {
    throw ('ChipDeck not found in ' + $AppDir)
}

$profileDir = Resolve-ProfileDir
$hasDsh = $null -ne $profileDir
if ($hasDsh) {
    Write-Step ('DSH profile: ' + $profileDir)
} else {
    Write-Step 'DSH profile not found.'
}

$enableAgents = $false
if ($WithDsh -and $WithoutDsh) {
    throw 'Use either -WithDsh or -WithoutDsh.'
}
if ($WithDsh) {
    $enableAgents = $true
} elseif ($WithoutDsh) {
    $enableAgents = $false
} elseif ($hasDsh) {
    if ([Console]::IsInputRedirected) {
        $enableAgents = $true
    } else {
        $answer = Read-Host 'Enable DSH agents (link the plugin into the profile)? [Y/n]'
        $enableAgents = $answer -notmatch '^\s*[nN]'
    }
}

if ($enableAgents -and -not $hasDsh) {
    Write-Warn 'DSH not found: agents stay disabled. Install DSH and run setup again.'
    $enableAgents = $false
}

$appPath = $AppDir
if ($Install) {
    $installer = Join-Path $AppDir 'install.ps1'
    if (Test-Path -LiteralPath $installer) {
        Write-Step 'Installing the application...'
        & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $installer -InstallDir $InstallDir -SkipDsh -NoLaunch
        $appPath = $InstallDir
        $AppDir = $InstallDir
    } else {
        Write-Warn 'install.ps1 not found, running from the repository folder.'
    }
}

if ($enableAgents) {
    $pluginInstalled = $true
    Install-PluginBundle $profileDir $AppDir
}

Save-FeatureChoice $enableAgents

Write-Host ''
if ($script:Warnings.Count -gt 0) {
    Write-Host 'Finished with warnings:'
    foreach ($warning in $script:Warnings) { Write-Host (' - ' + $warning) }
} else {
    Write-Host 'Done.'
}

if (-not $NoLaunch) {
    $launchScript = Join-Path $appPath 'host\launch.ps1'
    if (Test-Path -LiteralPath $launchScript) {
        Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList @(
            '-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', $launchScript
        ) -WindowStyle Hidden
        Write-Host 'ChipDeck started.'
    }
}

if ($pluginInstalled) {
    Write-Host ''
    Write-Host '========================================================'
    Write-Host ' IMPORTANT: restart DSH so it loads the plugin.'
    Write-Host '   1. Close DSH (window or process).'
    Write-Host '   2. Start DSH again (for example, dsh-web).'
    Write-Host '========================================================'
}

if (-not $NoPause -and -not [Console]::IsInputRedirected) {
    Read-Host 'Press Enter to close this window' | Out-Null
}
