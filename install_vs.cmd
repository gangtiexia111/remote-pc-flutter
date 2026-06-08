@echo off
echo Installing Visual Studio Build Tools 2022...
echo Components: Desktop C++ + MSVC + Windows SDK
echo This will take 15-30 minutes (download ~6-8 GB)...
echo.

C:\Users\Administrator\Downloads\vs_BuildTools.exe --quiet --wait --norestart --installPath "C:\Program Files\Microsoft Visual Studio\2022\BuildTools" --add Microsoft.VisualStudio.Workload.NativeDesktop --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 --add Microsoft.VisualStudio.Component.Windows11SDK.22621 --includeRecommended

echo.
echo Exit code: %ERRORLEVEL%
if %ERRORLEVEL% EQU 0 (
    echo SUCCESS: VS Build Tools installed!
) else if %ERRORLEVEL% EQU 3010 (
    echo SUCCESS: VS Build Tools installed (reboot may be required)!
) else (
    echo WARNING: Installer exited with code %ERRORLEVEL%
)
