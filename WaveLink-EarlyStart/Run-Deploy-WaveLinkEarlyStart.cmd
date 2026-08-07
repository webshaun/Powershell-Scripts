@echo off
REM ===========================================================================
REM  Run-Deploy-WaveLinkEarlyStart.cmd
REM
REM  Double-click this to run the Wave Link deployer.
REM
REM  Why this exists: a .ps1 downloaded from the internet carries a Mark of the
REM  Web, which RemoteSigned refuses to load. cmd.exe has no execution policy,
REM  and -ExecutionPolicy Bypass is process-scoped, so nothing on the machine is
REM  permanently loosened.
REM
REM  Do NOT run this elevated. The deployer will refuse - a packaged app
REM  activated from an elevated context lands in the wrong session.
REM ===========================================================================

setlocal

set "PS1=%~dp0Deploy-WaveLinkEarlyStart.ps1"

if not exist "%PS1%" (
    echo.
    echo   ERROR: Deploy-WaveLinkEarlyStart.ps1 not found next to this launcher.
    echo   Expected: %PS1%
    echo.
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*

echo.
pause
endlocal
