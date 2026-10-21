@echo off
cd /d "%~dp0"
python "%~dp0export_connection.py" --output "%~dp0SamsungConnection.samsungconnection"
echo.
pause
