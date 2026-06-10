@echo off
REM ──────────────────────────────────────────────────────
REM Remote PC Flutter — Windows Release Build (Obfuscated)
REM 单独构建 Windows EXE + Dart 代码混淆
REM ──────────────────────────────────────────────────────
setlocal

set FLUTTER=C:\Users\Administrator\flutter\bin\flutter.bat
set PROJECT=C:\Users\Administrator\Desktop\remote-pc-flutter
set OBFUSCATE=--obfuscate --split-debug-info=%PROJECT%\build\debug-info

echo ============================================================
echo Remote PC v1.0.3 — Windows Release Build with Obfuscation
echo ============================================================

cd /d %PROJECT%

echo.
echo 📦 Building Windows release (obfuscated)...
%FLUTTER% build windows --release %OBFUSCATE%

if %ERRORLEVEL% EQU 0 (
    echo.
    echo ✅ Windows build complete!
    echo.
    echo Output: %PROJECT%\build\windows\x64\runner\Release\
    echo Debug symbols: %PROJECT%\build\debug-info\
    echo.
    echo ⚠️  Keep debug-info/ for crash log deobfuscation!
    echo ⚠️  Do NOT commit debug-info/ to Git!
) else (
    echo.
    echo ❌ Build failed!
)

endlocal
