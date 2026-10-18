@echo off
rem Start the persona chat backend. Double-click to run.
cd /d "%~dp0server"

rem Pick a Python that has fastapi/uvicorn installed.
set PY=
if exist "%~dp0.venv\Scripts\python.exe" set PY=%~dp0.venv\Scripts\python.exe
if "%PY%"=="" if exist "%USERPROFILE%\.workbuddy\binaries\python\envs\persona\Scripts\python.exe" set PY=%USERPROFILE%\.workbuddy\binaries\python\envs\persona\Scripts\python.exe
if "%PY%"=="" set PY=python

rem API key stays local: the server itself reads validator\.env (llm.load_env).
rem Do NOT parse .env in batch - trailing spaces / special chars silently corrupt keys.

echo using %PY%
echo http://127.0.0.1:8000/docs
"%PY%" -m uvicorn main:app --host 127.0.0.1 --port 8000
pause
