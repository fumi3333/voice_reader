@echo off
echo Requesting Administrator privileges to fix Firewall...
powershell -Command "Start-Process cmd -ArgumentList '/c cd /d %CD% && netsh advfirewall firewall add rule name=""Voice Reader App"" dir=in action=allow protocol=TCP localport=8550 && echo Firewall Fixed! && echo. && echo Launching App... && .\.venv\Scripts\flet.exe run main.py --web --port 8550 --host 0.0.0.0' -Verb RunAs"
echo.
echo Please check the NEW window that opened (you might need to click 'Yes').
pause
