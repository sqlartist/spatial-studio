#!/usr/bin/env sh
# Spatial Studio for SQL Server 2025 - starts the local server on http://localhost:8765
cd "$(dirname "$0")"
python3 -m pip install -r requirements.txt --quiet --disable-pip-version-check
python3 -m uvicorn server:app --app-dir app --host 127.0.0.1 --port 8765
