@echo off
rem Spatial Studio for SQL Server 2025 - starts the local server and opens the browser
cd /d "%~dp0"
python -m pip install -r requirements.txt --quiet --disable-pip-version-check
rem Optional: set SPATIAL_STUDIO_SERVER=localhost\SQL2025
start "" http://localhost:8765
python -m uvicorn server:app --app-dir app --host 127.0.0.1 --port 8765
