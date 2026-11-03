@echo off
cd /d "%~dp0PC_VIEWER"
if exist .venv\Scripts\python.exe (
  .venv\Scripts\python.exe -X utf8 stop_studio.py
) else (
  D:\M7_STUDIO_RUNTIME\Scripts\python.exe -X utf8 stop_studio.py
)
pause
