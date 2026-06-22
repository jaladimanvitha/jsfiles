@echo off
REM ============================================================
REM   FCP Pods Dashboard - installer (Windows)
REM ------------------------------------------------------------
REM   The dashboard runs this file when `gcloud` or `kubectl`
REM   is not on PATH. We install gcloud first, then use gcloud
REM   to install kubectl (matches the manual flow in your notes).
REM
REM   The dashboard expects:
REM     - Exit code 0 on success
REM     - Anything written to stdout/stderr is shown back to UI
REM ============================================================

setlocal
set "HERE=%~dp0"

echo [installer] FCP Dashboard installer starting...

REM ============================================================
REM  STEP 1 - Install gcloud
REM ------------------------------------------------------------
REM  Your existing gcloud-install script is named "Install.cmd"
REM  (per your notes). Place a copy of it next to this dashboard
REM  but RENAME it to "install-gcloud.cmd" so it doesn't collide
REM  with this file.
REM
REM  Edit the path on the next line if your installer lives
REM  somewhere else (network share, %ProgramFiles%, etc.).
REM ============================================================

where gcloud >NUL 2>&1
if %errorlevel%==0 (
    echo [installer] gcloud already on PATH - skipping gcloud install.
) else (
    echo [installer] Installing gcloud ...
    if exist "%HERE%install-gcloud.cmd" (
        call "%HERE%install-gcloud.cmd"
        if errorlevel 1 ( echo [installer] gcloud install failed & exit /b 1 )
    ) else (
        echo [installer] ERROR: install-gcloud.cmd not found next to the dashboard.
        echo            Copy your existing Install.cmd here as "install-gcloud.cmd",
        echo            or change the path on line 38 of Install.cmd.
        exit /b 1
    )
)

REM ============================================================
REM  STEP 2 - Install kubectl via gcloud components
REM ============================================================

where kubectl >NUL 2>&1
if %errorlevel%==0 (
    echo [installer] kubectl already on PATH - skipping kubectl install.
) else (
    echo [installer] Installing kubectl ...
    call gcloud components install kubectl --quiet
    if errorlevel 1 ( echo [installer] kubectl install failed & exit /b 1 )
)

echo.
echo [installer] Done. Reload the dashboard tab to refresh the CLI indicators.
echo.

endlocal
exit /b 0
