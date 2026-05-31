@echo off
setlocal enabledelayedexpansion

REM Parse command line argument
set "TARGET=%~1"
if "!TARGET!"=="" set "TARGET=latest"

REM Validate target parameter
if /i "!TARGET!"=="stable" goto :target_valid
if /i "!TARGET!"=="latest" goto :target_valid
echo !TARGET! | findstr /r "^[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*" >nul
if !ERRORLEVEL! equ 0 goto :target_valid

echo Usage: %0 [stable^|latest^|VERSION] >&2
echo Example: %0 1.0.58 >&2
exit /b 1

:target_valid

REM Check for 64-bit Windows
if /i "%PROCESSOR_ARCHITECTURE%"=="AMD64" goto :arch_valid
if /i "%PROCESSOR_ARCHITECTURE%"=="ARM64" goto :arch_valid
if /i "%PROCESSOR_ARCHITEW6432%"=="AMD64" goto :arch_valid
if /i "%PROCESSOR_ARCHITEW6432%"=="ARM64" goto :arch_valid

echo Claude Code does not support 32-bit Windows. >&2
exit /b 1

:arch_valid

set "DOWNLOAD_BASE_URL=https://nexus.ihome.sxxpqp.top:8443/repository/claude-code"
set "DOWNLOAD_DIR=%USERPROFILE%\.claude\downloads"

if /i "%PROCESSOR_ARCHITECTURE%"=="ARM64" (
    set "PLATFORM=win32-arm64"
) else (
    set "PLATFORM=win32-x64"
)

if not exist "!DOWNLOAD_DIR!" mkdir "!DOWNLOAD_DIR!"

curl --version >nul 2>&1
if !ERRORLEVEL! neq 0 (
    echo curl is required but not available. >&2
    exit /b 1
)

REM Get latest version
call :download_file "!DOWNLOAD_BASE_URL!/latest" "!DOWNLOAD_DIR!\latest"
if !ERRORLEVEL! neq 0 (
    echo Failed to get latest version >&2
    exit /b 1
)

findstr /r "^[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*" "!DOWNLOAD_DIR!\latest" >nul
if !ERRORLEVEL! neq 0 (
    del "!DOWNLOAD_DIR!\latest"
    echo Failed to get a valid version >&2
    exit /b 1
)

set /p VERSION=<"!DOWNLOAD_DIR!\latest"
del "!DOWNLOAD_DIR!\latest"
echo Found version: !VERSION!

REM Download binary (skip manifest and checksum)
set "BINARY_PATH=!DOWNLOAD_DIR!\claude-!VERSION!-!PLATFORM!.exe"
echo Downloading Claude Code !VERSION!...
call :download_file "!DOWNLOAD_BASE_URL!/!VERSION!/!PLATFORM!/claude.exe" "!BINARY_PATH!"
if !ERRORLEVEL! neq 0 (
    echo Failed to download binary >&2
    if exist "!BINARY_PATH!" del "!BINARY_PATH!"
    exit /b 1
)

REM Run install
echo Setting up Claude Code...
"!BINARY_PATH!" install "!TARGET!" --force
set "INSTALL_RESULT=!ERRORLEVEL!"

timeout /t 1 /nobreak >nul 2>&1
del /f "!BINARY_PATH!" >nul 2>&1

if !INSTALL_RESULT! neq 0 (
    echo Installation failed >&2
    exit /b 1
)

echo.
echo Installation complete!
echo.
exit /b 0

:download_file
set "URL=%~1"
set "OUTPUT=%~2"
curl -fsSL "!URL!" -o "!OUTPUT!"
exit /b !ERRORLEVEL!