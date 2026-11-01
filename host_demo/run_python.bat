@echo off
setlocal EnableExtensions
set "HERE=%~dp0"

REM 1. Project-local virtual environment.
if exist "%HERE%.venv\Scripts\python.exe" (
    "%HERE%.venv\Scripts\python.exe" %*
    exit /b
)

REM 2. Python launcher, only after verifying it really runs.
where py >nul 2>nul
if not errorlevel 1 (
    py -3 -c "import sys" >nul 2>nul
    if not errorlevel 1 (
        py -3 %*
        exit /b
    )
)

REM 3. system python, guarded against the Microsoft Store alias.
where python >nul 2>nul
if not errorlevel 1 (
    python -c "import sys" >nul 2>nul
    if not errorlevel 1 (
        python %*
        exit /b
    )
)

echo.
echo ERROR: No usable Python 3 interpreter was found.
echo Checked: .venv, py -3, and python.
echo If Windows shows the Microsoft Store alias, install Python or use this host_demo folder on the current machine.
echo.
exit /b 9009