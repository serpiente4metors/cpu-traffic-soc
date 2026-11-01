@echo off
setlocal
set "HERE=%~dp0"
if "%~1"=="" (
    echo Drag a JPG/PNG/BMP image onto this file, or run:
    echo    make_frame.bat "C:\path\image.png"
    pause
    exit /b 1
)
if not exist "%HERE%output" mkdir "%HERE%output"
call "%HERE%run_python.bat" "%HERE%scripts\make_frame.py" "%~1" --report "%HERE%config\quant_report.json" --out "%HERE%output\frame.txt"
if errorlevel 1 (
    echo.
    echo Frame generation failed.
    pause
    exit /b 1
)
echo.
echo Generated: %HERE%output\frame.txt
echo Next: enter start, then 2, wait for READY, and run auto_paste.bat.
pause