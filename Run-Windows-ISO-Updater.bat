@echo off
setlocal

:: Version: 2026.11.18.1   (date-based, stamped automatically by tools\Update-Version.ps1 on commit)

:: Runs Windows-ISO-Updater.ps1 elevated, with an execution policy that lets it run, passing along every
:: argument given to this file. Dropping an ISO onto this file builds from that ISO.

:: PowerShell 7 when it is installed and works, otherwise Windows PowerShell 5.1, which ships with every Windows
:: this tool supports. Each pwsh.exe found is started once and has to report version 7 or newer, so a broken
:: install, a leftover PowerShell 6 or a Store alias with nothing behind it falls back instead of failing the run.
:: The elevated copy of this file picks again the same way. To use Windows PowerShell anyway, run
:: powershell.exe -File .\Windows-ISO-Updater.ps1, which elevates itself and stays in that edition.
set "WISO_PS="
for /f "delims=" %%P in ('where pwsh.exe 2^>nul') do if not defined WISO_PS call :TryPwsh "%%P"
:: Not on PATH yet, as in a window opened before PowerShell 7 was installed. ProgramW6432 covers a 32-bit cmd.exe.
if not defined WISO_PS call :TryPwsh "%ProgramFiles%\PowerShell\7\pwsh.exe"
if not defined WISO_PS if defined ProgramW6432 call :TryPwsh "%ProgramW6432%\PowerShell\7\pwsh.exe"
set "WISO_PS_NAME=PowerShell 7"
if defined WISO_PS goto :HavePowerShell
set "WISO_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "WISO_PS_NAME=Windows PowerShell 5.1 (PowerShell 7 was not found)"
:HavePowerShell

NET SESSION >NUL 2>&1
IF %ERRORLEVEL% EQU 0 GOTO :Elevated

ECHO Requesting administrative privileges...
:: Handed over in environment variables so PowerShell treats them as data, never as code to run.
set "WISO_BAT=%~f0"
set "WISO_CWD=%CD%"
set "WISO_ARGS=%*"
:: An elevated cmd.exe starts in System32, so the relaunch changes back to this folder first. Without that a
:: relative path such as .\Examples\autounattend-lab-admin.xml points at the wrong place.
:: Run from a terminal it waits, so the prompt gets the script's exit code back. Double-clicked or dropped
:: onto from Explorer, nobody is reading that code, so this window closes straight away.
"%WISO_PS%" -NoProfile -ExecutionPolicy Bypass -Command "$q = [char]34; $Line = '/d /c ' + $q + 'cd /d ' + $q + $env:WISO_CWD + $q + ' && ' + $q + $env:WISO_BAT + $q + ' ' + $env:WISO_ARGS + $q; $Caller = try { $Cmd = (Get-CimInstance Win32_Process -Filter ('ProcessId=' + $PID)).ParentProcessId; $Up = (Get-CimInstance Win32_Process -Filter ('ProcessId=' + $Cmd)).ParentProcessId; (Get-Process -Id $Up -ErrorAction Stop).ProcessName } catch { '' }; try { if ($Caller -and $Caller -ne 'explorer') { $p = Start-Process -FilePath $env:ComSpec -ArgumentList $Line -Verb RunAs -Wait -PassThru -ErrorAction Stop; exit $p.ExitCode } Start-Process -FilePath $env:ComSpec -ArgumentList $Line -Verb RunAs -ErrorAction Stop; exit 0 } catch { exit 1 }"
EXIT /B %ERRORLEVEL%

:Elevated
ECHO Running with administrative privileges in %WISO_PS_NAME%.

set "PS_SCRIPT=%~dp0Windows-ISO-Updater.ps1"

IF NOT EXIST "%PS_SCRIPT%" (
    ECHO Windows-ISO-Updater.ps1 was not found in the same folder as this batch file.
    ECHO Place Windows-ISO-Updater.ps1 next to Run-Windows-ISO-Updater.bat and run again.
    PAUSE
    EXIT /B 1
)

:: An ISO dropped onto this file arrives as its only argument.
set "WISO_DROP="
IF "%~2"=="" IF /I "%~x1"==".iso" IF EXIST "%~f1" set "WISO_DROP=%~f1"
IF NOT DEFINED WISO_DROP GOTO :Run
"%WISO_PS%" -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" -IsoPath "%WISO_DROP%"
EXIT /B %ERRORLEVEL%

:Run
"%WISO_PS%" -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" %*
:: Passed on so a caller can read -CheckOnly's 0 or 10.
EXIT /B %ERRORLEVEL%

:: Uses the pwsh.exe given if it starts and reports version 7 or newer.
:TryPwsh
IF NOT EXIST "%~1" EXIT /B
"%~1" -NoLogo -NoProfile -NonInteractive -Command "exit $PSVersionTable.PSVersion.Major" >NUL 2>&1
IF NOT ERRORLEVEL 7 EXIT /B
set "WISO_PS=%~1"
EXIT /B
