@echo off
cd /d "%~dp0"
python -m venv .venv
if errorlevel 1 goto done
.venv\Scripts\python.exe -m pip install -r requirements-lock.txt
:done
pause
