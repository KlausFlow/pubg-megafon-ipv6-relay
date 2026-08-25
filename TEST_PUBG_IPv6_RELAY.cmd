@echo off
setlocal EnableDelayedExpansion
chcp 65001 >nul
cd /d "%~dp0"

set "OUTDIR=%USERPROFILE%\Desktop\PUBG-MegaFon-Diagnostics"
for /f "usebackq delims=" %%D in (`powershell.exe -NoProfile -Command "[Environment]::GetFolderPath('Desktop')"`) do set "OUTDIR=%%D\PUBG-MegaFon-Diagnostics"
if not exist "%OUTDIR%" mkdir "%OUTDIR%" >nul 2>&1
if not exist "%OUTDIR%" set "OUTDIR=%~dp0"
set "OUT=%OUTDIR%\PUBG-Russian-First-v12-test.txt"
> "%OUT%" echo PUBG IPv6 relay test
>> "%OUT%" echo Date: %date% %time%
>> "%OUT%" echo.
>> "%OUT%" echo ===== selected relay targets =====
if exist "%~dp0PUBG-IPv6-Relay-target.txt" (
    type "%~dp0PUBG-IPv6-Relay-target.txt" >> "%OUT%"
) else (
    >> "%OUT%" echo Target file is absent. Start the relay first.
)
for %%H in (
    prod-live-front.playbattlegrounds.com
    prod-live-images.playbattlegrounds.com
    prod-live-cfentry.playbattlegrounds.com
    country-code.playbattlegrounds.com
    prod-live-xenuine.playbattlegrounds.com
    acrt-pcprod.acs.pubg.com
    zkd-pcprod.acs.pubg.com
) do (
    >> "%OUT%" echo.
    >> "%OUT%" echo ===== %%H =====
    curl.exe -4 -skS -o NUL --connect-timeout 8 --max-time 20 -w "HTTP_CODE=%%{http_code}\n" "https://%%H/" >> "%OUT%" 2>&1
    >> "%OUT%" echo curl_exit_code=!errorlevel!
)
>> "%OUT%" echo.
>> "%OUT%" echo ===== zk-ga-pcprod.acs.pubg.com:40002 transparent relay =====
powershell.exe -NoProfile -Command "$ips=@(Resolve-DnsName 'zk-ga-pcprod.acs.pubg.com' -Type A -DnsOnly -ErrorAction SilentlyContinue ^| ? IPAddress ^| select -Expand IPAddress -Unique); foreach($ip in $ips){$c=[Net.Sockets.TcpClient]::new(); try {$t=$c.ConnectAsync([string]$ip,40002); if($t.Wait(5000) -and $c.Connected){'CONTROL_RELAY '+$ip+':40002=PASS'}else{'CONTROL_RELAY '+$ip+':40002=FAIL'}} catch {'CONTROL_RELAY '+$ip+':40002=FAIL: '+$_.Exception.Message} finally {$c.Dispose()}}" >> "%OUT%" 2>&1
>> "%OUT%" echo.
>> "%OUT%" echo ===== IPv6 route =====
route print -6 >> "%OUT%" 2>&1
type "%OUT%"
echo.
echo Result: %OUT%
pause
