@echo off
REM FCP Pods Dashboard - Windows launcher
REM Starts the PowerShell server, opens the browser, and stays attached.

setlocal
cd /d "%~dp0"

set "PORT=8765"
if not "%~1"=="" set "PORT=%~1"

REM Find PowerShell (prefer pwsh / PS7, fall back to Windows PowerShell 5.1).
set "PS_EXE=powershell.exe"
where pwsh >NUL 2>&1 && set "PS_EXE=pwsh.exe"

REM Open the browser shortly after the server starts.
start "" "" /b cmd /c "ping -n 2 127.0.0.1 >NUL & start http://localhost:%PORT%/"

echo Starting FCP Pods Dashboard on http://localhost:%PORT%/ ...
echo Press Ctrl+C to stop.
echo.

"%PS_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0server.ps1" -Port %PORT%

endlocal
