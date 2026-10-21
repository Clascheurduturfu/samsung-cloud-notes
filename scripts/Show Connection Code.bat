@echo off
cd /d "%~dp0"
python "%~dp0export_connection.py" --show-code --output "%~dp0SamsungConnection.samsungconnection"
echo.
pause
