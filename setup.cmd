@echo off
setlocal
rem First run from the repository: configure features and start the overlay.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" %*
set "RESULT=%ERRORLEVEL%"
rem Keep the window open when the script was started by a double click.
echo %cmdcmdline% | find /i " /c " >nul && pause
exit /b %RESULT%