@echo off
setlocal
chcp 65001 >nul

:menu
cls
echo ================================================================
echo   Remote Codex Proxy / Codex 远控代理工具
echo ================================================================
echo   1. Enable controller forced mode / 开启控制端强制模式
echo   2. Disable controller forced mode / 撤销控制端强制模式
echo   3. Enable host light mode / 开启被控端轻量模式
echo   4. Disable host light mode / 撤销被控端轻量模式
echo   5. Show status / 检查状态
echo   6. Run self-test / 执行自检
echo   0. Exit / 退出
echo ================================================================
set "choice="
set /p "choice=Choose / 请选择: "

if "%choice%"=="1" call :run EnableController
if "%choice%"=="2" call :run DisableController
if "%choice%"=="3" call :run EnableHost
if "%choice%"=="4" call :run DisableHost
if "%choice%"=="5" call :run Status
if "%choice%"=="6" call :run SelfTest
if "%choice%"=="0" exit /b 0
goto menu

:run
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0CodexRemoteProxy.ps1" -Action %1 -Interactive
exit /b
