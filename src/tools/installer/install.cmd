@echo off
chcp 65001 >nul
setlocal
set "HERE=%~dp0"
echo.
echo Preparing installer...

powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $z = Join-Path '%HERE%' 'payload.zip'; $d = Join-Path $env:TEMP 'ybinstall'; if (Test-Path $d) { Remove-Item $d -Recurse -Force }; Expand-Archive -LiteralPath $z -DestinationPath $d -Force; & (Join-Path $d 'install.ps1')"

if errorlevel 1 (
  echo.
  echo Installation failed. See the message above.
  pause
  exit /b 1
)
exit /b 0
