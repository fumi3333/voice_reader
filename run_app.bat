@echo off
echo Voice Reader Launching...
echo ---------------------------------------------------
echo 1. Opening Port 8550 in Firewall (requires Admin if not already set)...
powershell -Command "New-NetFirewallRule -DisplayName 'Voice Reader App' -Direction Inbound -LocalPort 8550 -Protocol TCP -Action Allow" >nul 2>&1
echo.
echo 2. Getting Local IP Address...
python get_ip.py
echo.
echo 3. Starting Server...
echo ---------------------------------------------------
echo Please access the URL displayed above from your smartphone.
echo Press Ctrl+C to stop.
echo ---------------------------------------------------
flet run main.py --web --port 8550 --host 0.0.0.0
