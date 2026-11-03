@echo off
chcp 65001 >nul
cd /d "%~dp0PC_VIEWER"
if exist .venv\Scripts\python.exe (
  .venv\Scripts\python.exe -X utf8 launcher.py
) else if exist D:\M7_STUDIO_RUNTIME\Scripts\python.exe (
  D:\M7_STUDIO_RUNTIME\Scripts\python.exe -X utf8 launcher.py
) else (
  echo Python runtime not found. Run PC_VIEWER\setup_runtime.cmd first.
)
pause
