@echo off
setlocal
cd /d "%~dp0"
call "%~dp0run_python.bat" "%~dp0console_demo.py"
if errorlevel 1 (
    echo.
    echo Demo failed to start or was cancelled.
    pause
)