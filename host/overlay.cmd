@echo off
rem Start the overlay host (always-on-top window + tray). Features live in ..\features.
rem Optional argument selects the initial feature: overlay.cmd zapret
start "" powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0launch.ps1" %*
exit /b 0
