@echo off
chcp 65001 >nul
setlocal EnableDelayedExpansion
cd /d "%~dp0"
title 云班-DSH 桥接器

rem ============================================
rem  单一入口：默认托盘模式
rem  云班桥接器.bat            启动托盘（推荐）
rem  云班桥接器.bat console    命令行模式（看滚动日志）
rem  云班桥接器.bat status     查看状态
rem  云班桥接器.bat login      重新登录
rem ============================================

if /i "%~1"=="console" goto console
if /i "%~1"=="status"  goto status
if /i "%~1"=="login"   goto login
if /i "%~1"=="persona" goto persona
if /i "%~1"=="history" goto history
if /i "%~1"=="rebind"  goto rebind
if /i "%~1"=="off"     goto off
if /i "%~1"=="on"      goto on
if /i "%~1"=="tray"    goto tray

:tray
where node >nul 2>nul
if errorlevel 1 (
  echo [错误] 未找到 Node.js，请先安装 Node 22+ 并加入 PATH
  pause
  exit /b 1
)
start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0托盘.ps1"
exit /b 0

:console
where node >nul 2>nul
if errorlevel 1 (
  echo [错误] 未找到 Node.js
  pause
  exit /b 1
)
node bridge\main.js %2 %3 %4
echo.
pause
exit /b 0

:status
node bridge\main.js --status
echo.
pause
exit /b 0

:login
node bridge\main.js --login
echo.
pause
exit /b 0

:persona
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0人格设置.ps1"
exit /b 0

:history
node tools\export_history.js
echo.
echo 已导出到 exports 目录
pause
exit /b 0

:rebind
echo 正在重新识别账号与班级...
if exist "data\bridge.lock" (
  echo 1> "data\rebind.flag"
  echo 1> "data\force-poll"
  echo 正在运行的桥接器会在下一轮（几秒内）重新识别，无需重启。
) else (
  node bridge\main.js --once --rebind
  echo 已执行一次重新识别。
)
echo.
pause
exit /b 0

:off
echo 正在停用桥接器...
if not exist "data" mkdir "data"
echo disabled by user %date% %time%> "data\disabled.flag"
if exist "data\bridge.lock" (
  set /p BPID=<"data\bridge.lock"
  call :killpid !BPID!
)
echo.
echo 已停用：不会再轮询云班，也不会调用 DSH。
echo 托盘若在运行，图标会变成灰色并停止自动拉起。
echo 恢复请执行：云班桥接器.bat on
echo.
pause
exit /b 0

:on
echo 正在启用桥接器...
if exist "data\disabled.flag" del /q "data\disabled.flag"
start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0托盘.ps1"
echo 已启用（若托盘已在运行，会在几秒内自动恢复）。
echo.
pause
exit /b 0

:killpid
taskkill /PID %~1 /F >nul 2>nul
exit /b 0
