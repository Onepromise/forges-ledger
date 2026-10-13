@echo off
rem Builds dist\ForgesLedger.exe from forges_ledger.py.
rem
rem Uses its own Python environment in %LOCALAPPDATA%\ForgesLedgerBuild
rem (outside OneDrive) so PyInstaller never touches your main Python install.
rem Safe to re-run any time; the first run downloads PyInstaller.
rem
rem Before building after an addon change: copy the addon into
rem addon\ForgeGoldTracker and bump its "## Version" line.

setlocal
cd /d "%~dp0"
set BUILD=%LOCALAPPDATA%\ForgesLedgerBuild
set VENV=%BUILD%\venv

if not exist "%VENV%\Scripts\python.exe" (
    echo Creating build environment...
    python -m venv "%VENV%" || goto :fail
)
"%VENV%\Scripts\python.exe" -m pip install --quiet --disable-pip-version-check pyinstaller==6.22.3 || goto :fail

rem --onefile   : a single .exe to hand out
rem --console   : keeps the status window; closing it stops the dashboard
rem --add-data  : files the app reads at runtime (absolute paths, because
rem               PyInstaller resolves relative ones from --specpath)
"%VENV%\Scripts\pyinstaller.exe" --noconfirm --clean --onefile --console ^
    --name ForgesLedger ^
    --add-data "%~dp0addon;addon" ^
    --add-data "%~dp0PRIVACY.md;." ^
    --workpath "%BUILD%\work" --specpath "%BUILD%" --distpath "%~dp0dist" ^
    "%~dp0forges_ledger.py" || goto :fail

echo.
echo Built: %~dp0dist\ForgesLedger.exe
exit /b 0

:fail
echo.
echo BUILD FAILED - see the messages above.
exit /b 1
