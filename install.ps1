#requires -Version 5.1
<#
    Установщик ChipDeck.

    Копирует приложение в каталог пользователя, создаёт ярлыки (меню «Пуск» и
    автозапуск), при наличии DSH ставит клиентский плагин-мост, затем запускает
    оверлей.

    Примеры:
        .\install.cmd
        .\install.ps1 -NoAutostart
        .\install.ps1 -InstallDir D:\Apps\ChipDeck
        .\install.ps1 -SkipDsh
        .\install.ps1 -NoPath
        .\install.ps1 -DshDryRun -NoLaunch
#>

param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'Programs\ChipDeck'),
    [string]$DshCommand = '',
    [switch]$NoAutostart,
    [switch]$SkipDsh,
    [switch]$NoLaunch,
    [switch]$NoPath,
    [switch]$DshDryRun
)

$ErrorActionPreference = 'Stop'

$script:LogPath = Join-Path $env:TEMP 'chipdeck-install.log'
$script:BundleName = '@local/dsh-agent-overlay'
$script:Warnings = New-Object System.Collections.Generic.List[string]

function Write-Log([string]$text) {
    $line = (Get-Date -Format 'HH:mm:ss') + '  ' + $text
    Write-Host $line
    try { Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8 } catch { }
}

function Write-Warn([string]$text) {
    $script:Warnings.Add($text)
    Write-Log ('WARNING: ' + $text)
}

function Stop-ChipDeck {
    $processes = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*chipdeck.ps1*' }
    foreach ($process in $processes) {
        Write-Log ('Stopping running ChipDeck, PID ' + $process.ProcessId)
        Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

function New-Shortcut([string]$path, [string]$arguments, [string]$workDir) {
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($path)
        $shortcut.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
        $shortcut.Arguments = $arguments
        $shortcut.WorkingDirectory = $workDir
        $shortcut.Description = 'ChipDeck — оверлей поверх окон'
        $shortcut.IconLocation = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe,0"
        $shortcut.Save()
        Write-Log ('Shortcut created: ' + $path)
        return $true
    } catch {
        Write-Warn ('Could not create shortcut ' + $path + ': ' + $_.Exception.Message)
        return $false
    }
}

# ---- user PATH: make `chipdeck` callable from a new console
# Appends <InstallDir>\host to HKCU\Environment Path (no admin needed) and
# notifies running shells through WM_SETTINGCHANGE. Existing consoles keep the
# old PATH until reopened.

function Get-NormalizedPathEntry([string]$value) {
    if ([string]::IsNullOrWhiteSpace($value)) { return '' }
    $expanded = [Environment]::ExpandEnvironmentVariables($value)
    try { $expanded = [System.IO.Path]::GetFullPath($expanded) } catch { }
    return $expanded.Trim().TrimEnd('\').ToLowerInvariant()
}

function Get-UserPathRaw {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $false)
    if ($null -eq $key) { return '' }
    try {
        return [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    } finally { $key.Close() }
}

function Update-EnvironmentBroadcast {
    try {
        if (-not ('ChipDeck.EnvBroadcast' -as [type])) {
            Add-Type -Namespace ChipDeck -Name EnvBroadcast -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern System.IntPtr SendMessageTimeout(System.IntPtr hWnd, uint Msg, System.UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out System.IntPtr lpdwResult);
'@
        }
        $result = [System.IntPtr]::Zero
        [void][ChipDeck.EnvBroadcast]::SendMessageTimeout([System.IntPtr]0xFFFF, 0x001A, [System.UIntPtr]::Zero, 'Environment', 0x0002, 5000, [ref]$result)
    } catch { }
}

function Test-UserPathEntry([string]$entry) {
    $normalized = Get-NormalizedPathEntry $entry
    if ($normalized -eq '') { return $false }
    foreach ($part in @((Get-UserPathRaw) -split ';')) {
        if ((Get-NormalizedPathEntry $part) -eq $normalized) { return $true }
    }
    return $false
}

function Add-UserPathEntry([string]$entry) {
    $normalized = Get-NormalizedPathEntry $entry
    if ($normalized -eq '') { return $false }
    $current = Get-UserPathRaw
    $parts = @($current -split ';' | Where-Object { $_.Trim() -ne '' })
    foreach ($part in $parts) {
        if ((Get-NormalizedPathEntry $part) -eq $normalized) { return $false }
    }
    $next = (@($parts) + $entry) -join ';'
    try {
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
        if ($null -eq $key) { throw 'HKCU\Environment is not writable' }
        try { $key.SetValue('Path', $next, [Microsoft.Win32.RegistryValueKind]::ExpandString) }
        finally { $key.Close() }
    } catch {
        Write-Warn ('Could not update the user PATH: ' + $_.Exception.Message)
        return $false
    }
    Update-EnvironmentBroadcast
    return $true
}

function Find-DshCommand {
    if ($DshCommand -ne '') {
        return [pscustomobject]@{
            File = $DshCommand
            Prefix = @()
            Display = $DshCommand
        }
    }
    $command = Get-Command dsh -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return [pscustomobject]@{ File = $command.Source; Prefix = @(); Display = $command.Source }
    }
    foreach ($candidate in @(
        (Join-Path $env:APPDATA 'npm\dsh.cmd'),
        (Join-Path $env:LOCALAPPDATA 'pnpm\dsh.cmd')
    )) {
        if (Test-Path -LiteralPath $candidate) {
            return [pscustomobject]@{ File = $candidate; Prefix = @(); Display = $candidate }
        }
    }
    $binCandidates = @()
    $webShim = Join-Path $env:APPDATA 'npm\dsh-web.cmd'
    if (Test-Path -LiteralPath $webShim) {
        $lines = Get-Content -LiteralPath $webShim -ErrorAction SilentlyContinue
        foreach ($line in $lines) {
            if ($line -match 'DSH_ROOT=(.+)$') {
                $root = $Matches[1].Trim().Trim('"')
                $binCandidates += (Join-Path $root 'apps\cli\lib\bin.js')
            }
        }
    }
    $binCandidates += (Join-Path $env:USERPROFILE 'deepseek-harness\apps\cli\lib\bin.js')
    $node = Get-Command node -ErrorAction SilentlyContinue
    if ($null -ne $node) {
        foreach ($bin in $binCandidates) {
            if (Test-Path -LiteralPath $bin) {
                return [pscustomobject]@{
                    File = $node.Source
                    Prefix = @($bin)
                    Display = ('"' + $node.Source + '" "' + $bin + '"')
                }
            }
        }
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

function Add-BundleToProfile([string]$profileName) {
    $profileDir = Join-Path (Join-Path $env:USERPROFILE '.dsh\profiles') $profileName
    $packagePath = Join-Path $profileDir 'package.json'
    if (-not (Test-Path -LiteralPath $packagePath)) {
        throw ('Not found: ' + $packagePath)
    }
    $text = [System.IO.File]::ReadAllText($packagePath, [System.Text.Encoding]::UTF8)
    $json = $text | ConvertFrom-Json
    if ($null -eq $json.dsh) {
        $json | Add-Member -MemberType NoteProperty -Name dsh -Value ([pscustomobject]@{})
    }
    if ($null -eq $json.dsh.profile) {
        $json.dsh | Add-Member -MemberType NoteProperty -Name profile -Value ([pscustomobject]@{})
    }
    $bundles = @()
    if ($null -ne $json.dsh.profile.bundles) { $bundles = @($json.dsh.profile.bundles) }
    if ($bundles -contains $script:BundleName) {
        Write-Log 'The plugin is already enabled in the DSH profile.'
        return
    }
    $bundles += $script:BundleName
    $json.dsh.profile = [pscustomobject]@{ bundles = $bundles }
    Copy-Item -LiteralPath $packagePath -Destination ($packagePath + '.chipdeck-backup') -Force
    [System.IO.File]::WriteAllText($packagePath, ($json | ConvertTo-Json -Depth 12), (New-Object System.Text.UTF8Encoding($false)))
    Write-Log ('Plugin added to dsh.profile.bundles of profile ' + $profileName)
}

function Install-DshPlugin($dsh, [string]$profileName, [string]$pluginPath) {
    $arguments = @($dsh.Prefix) + @('plugin', '--profile', $profileName, 'add', ('link:' + $pluginPath))
    if ($DshDryRun) {
        Write-Log ('DRY RUN: ' + $dsh.File + ' ' + ($arguments -join ' '))
        return
    }
    Write-Log ('Installing the DSH plugin from ' + $pluginPath)
    & $dsh.File @arguments 2>&1 | ForEach-Object { Write-Log ([string]$_) }
    if ($LASTEXITCODE -ne 0) {
        Write-Warn ('pnpm could not install the plugin (usually because DSH is running). Close DSH and run the installer again, or connect it manually: DSH → Plugins → Add plugin → ' + $pluginPath)
        return
    }
    Add-BundleToProfile $profileName
    Write-Log 'IMPORTANT: restart DSH so it loads the plugin.'
}

Write-Log '=== ChipDeck installer ==='

if ($env:OS -ne 'Windows_NT') {
    throw 'ChipDeck installs on Windows only.'
}
if ($PSVersionTable.PSVersion.Major -lt 5) {
    throw 'Windows PowerShell 5.1 or newer is required.'
}

$sourceDir = $PSScriptRoot
if (-not (Test-Path -LiteralPath (Join-Path $sourceDir 'host\chipdeck.ps1'))) {
    throw ('The installer was not started from the ChipDeck folder: ' + $sourceDir)
}

$InstallDir = [System.IO.Path]::GetFullPath($InstallDir)
Write-Log ('Install directory: ' + $InstallDir)
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

Stop-ChipDeck

if ($InstallDir.TrimEnd('\') -ne $sourceDir.TrimEnd('\')) {
    Write-Log 'Copying application files...'
    $robocopyArgs = @(
        $sourceDir, $InstallDir, '/E', '/R:1', '/W:1',
        '/XD', '.git', 'dev', 'installer', '.runtime', '__pycache__',
        '/XF', '*.log', '/NFL', '/NDL', '/NP'
    )
    & robocopy @robocopyArgs | Out-Null
    if ($LASTEXITCODE -ge 8) {
        throw ('robocopy failed with exit code ' + $LASTEXITCODE)
    }
}

$launchScript = Join-Path $InstallDir 'host\launch.ps1'
if (-not (Test-Path -LiteralPath $launchScript)) {
    throw ('Not found: ' + $launchScript)
}

$binDir = Join-Path $InstallDir 'bin'
$pathEntry = $binDir
$pathReady = $false
if ($NoPath) {
    Write-Log 'User PATH left unchanged (-NoPath).'
} else {
    New-Item -ItemType Directory -Path $binDir -Force | Out-Null
    $shim = Join-Path $binDir 'chipdeck.cmd'
    $shimText = @'
@echo off
rem ChipDeck launcher; the installer puts this folder on the user PATH.
start "" powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0..\host\launch.ps1" %*
exit /b 0
'@
    [System.IO.File]::WriteAllText($shim, ($shimText -replace "`r?`n", "`r`n"), (New-Object System.Text.ASCIIEncoding))
    $pathReady = Test-UserPathEntry $pathEntry
    if ($pathReady) {
        Write-Log ('User PATH already contains ' + $pathEntry)
    } elseif (Add-UserPathEntry $pathEntry) {
        $pathReady = $true
        Write-Log ('Added to the user PATH: ' + $pathEntry)
        Write-Log 'Open a new console window to run "chipdeck" there.'
    } else {
        Write-Log ('Run "chipdeck.cmd" from ' + $binDir + ' or add that folder to PATH manually.')
    }
}

$startMenuDir = [Environment]::GetFolderPath('Programs')
New-Shortcut (Join-Path $startMenuDir 'ChipDeck.lnk') ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $launchScript + '"') (Split-Path -Parent $launchScript)

if (-not $NoAutostart) {
    $startupDir = [Environment]::GetFolderPath('Startup')
    New-Shortcut (Join-Path $startupDir 'ChipDeck.lnk') ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $launchScript + '"') (Split-Path -Parent $launchScript)
}

if (-not $SkipDsh) {
    $pluginPath = Join-Path $InstallDir 'dsh-plugin'
    $dsh = Find-DshCommand
    $profileName = Find-DshProfile
    if (-not (Test-Path -LiteralPath $pluginPath)) {
        Write-Warn 'The dsh-plugin folder is missing, the DSH plugin was not installed.'
    } elseif ($null -eq $dsh) {
        Write-Warn ('dsh not found. Connect the plugin manually: DSH → Plugins → Add plugin → ' + $pluginPath)
    } elseif ($null -eq $profileName) {
        Write-Warn ('DSH profile not found. Connect the plugin manually: DSH → Plugins → Add plugin → ' + $pluginPath)
    } else {
        Install-DshPlugin $dsh $profileName $pluginPath
    }
}

Write-Log ('Done. Launch: ' + $launchScript)
if ($pathReady) { Write-Log 'Console: run "chipdeck" (or "chipdeck zapret") in a new window.' }
if (-not $NoLaunch) {
    Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList @(
        '-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', $launchScript
    ) -WindowStyle Hidden
    Write-Log 'ChipDeck started.'
}

Write-Log ''
if ($script:Warnings.Count -gt 0) {
    Write-Log 'Installation finished with warnings:'
    foreach ($warning in $script:Warnings) { Write-Log (' - ' + $warning) }
} else {
    Write-Log 'Installation finished without warnings.'
}
Write-Log ('Log: ' + $script:LogPath)
