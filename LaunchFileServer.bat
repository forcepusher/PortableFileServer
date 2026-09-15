@echo off
setlocal
cd /d "%~dp0"

REM Hosts ..\PublicFiles over HTTP. That folder must already exist.

set "PFS_HTTP_PORT=8080"
set "PFS_SHARE_ID=soundlibrary"

title Portable File Server
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0LaunchFileServer.ps1"
set "ERR=%ERRORLEVEL%"
if not "%ERR%"=="0" (
    echo.
    echo Server failed to start.
    pause
)
exit /b %ERR%
