@echo off
REM ============================================================
REM pds_run.bat <target> -- reliable PDS flow launcher
REM
REM Usage:
REM   pds_run.bat pnr
REM   pds_run.bat report_timing
REM   pds_run.bat gen_bit_stream
REM   pds_run.bat synthesize
REM
REM Valid targets:
REM   compile  synthesize  dev_map  pnr  report_timing
REM   gen_bit_stream  report_power  gen_netlist
REM
REM Do NOT use: pds_shell -file xxx.tcl
REM   PDS parses the .tcl as a project file first, reports a fake
REM   line-number error, then open_project becomes an invalid command.
REM   Use -project + -run instead.
REM
REM All project tasks have force_to_run=ON, so -run reruns the full
REM chain from compile (about 4 minutes).
REM ============================================================
set PDS=D:\study\software\PDS_2022.2-SP6.4\bin\pds_shell.exe
for %%I in ("%~dp0..") do set "ROOT=%%~fI"
set PRJ=%ROOT%\pg200h\pg200h.pds
if "%~1"=="" (
  echo usage: pds_run.bat ^<compile^|synthesize^|dev_map^|pnr^|report_timing^|gen_bit_stream^>
  exit /b 1
)
"%PDS%" -project "%PRJ%" -run %1