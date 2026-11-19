@echo off
setlocal
rem Install ChipDeck: copy the app, create shortcuts and the DSH plugin.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
set "RESULT=%ERRORLEVEL%"
echo %cmdcmdline% | find /i " /c " >nul && pause
exit /b %RESULT%