@echo off
chcp 65001 >nul
echo.
echo  ╔═══════════════════════════════════╗
echo  ║   Remote PC 信令服务器              ║
echo  ║   启动中...                         ║
echo  ╚═══════════════════════════════════╝
echo.

cd /d "%~dp0signaling-server"

REM 优先使用系统 Node，其次用 WorkBuddy 内置 Node
where node >nul 2>&1
if %ERRORLEVEL% == 0 (
    echo [OK] 使用系统 Node.js
    node index.js
) else (
    echo [OK] 使用内置 Node.js
    "C:\Users\Administrator\.workbuddy\binaries\node\versions\22.22.2\node.exe" index.js
)

pause
