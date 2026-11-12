@echo off
setlocal EnableExtensions
set "SRC=%~dp0"
set "DEST=%LOCALAPPDATA%\DshUsageBall"

echo.
echo   DSH Usage Ball - Installer
echo   --------------------------
echo   Target: %DEST%
echo.

if not exist "%DEST%" mkdir "%DEST%" >nul 2>&1

set "FAIL=0"
for %%F in (widget.ps1 collect.mjs config.json start.vbs start.cmd install-autostart.cmd install-autostart.ps1 uninstall-autostart.cmd uninstall-autostart.ps1 install-shortcuts.ps1 README.txt) do (
  if exist "%SRC%%%F" (
    copy /Y "%SRC%%%F" "%DEST%\" >nul 2>&1
    if errorlevel 1 set "FAIL=1"
  )
)

if "%FAIL%"=="1" (
  echo   Copy failed. Move this installer to a writable folder and retry.
  pause
  exit /b 1
)

if "%DSH_BALL_TEST%"=="1" (
  echo   [test] files copied to %DEST%
  exit /b 0
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%DEST%\install-shortcuts.ps1" >nul 2>&1
start "" wscript.exe "%DEST%\start.vbs"

echo   Installed.
echo.
echo   - Shortcut created on Desktop and Start Menu: "DSH Usage Ball"
echo   - The ball docks to the DeepSeek Harness window (bottom right)
echo   - Click the ball to expand; click the dot on the card to collapse
echo   - Autostart: run install-autostart.cmd in the install folder
echo   - Chinese guide: see README.txt in the install folder
echo.
timeout /t 5 >nul
