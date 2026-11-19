@echo off
setlocal
rem Remove ChipDeck: stop the overlay and delete shortcuts.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1" %*
set "RESULT=%ERRORLEVEL%"
echo %cmdcmdline% | find /i " /c " >nul && pause
exit /b %RESULT%