@echo off
setlocal
set "HERE=%~dp0"
cd /d "%HERE%"
call "%HERE%run_python.bat" "%HERE%scripts\auto_paste.py" --dir "%HERE%output\frame_lines" --start-delay 5 --delay-ms 700
if errorlevel 1 (
    echo.
    echo Automatic paste failed. Check that output\frame_lines contains 50 files.
    pause
)