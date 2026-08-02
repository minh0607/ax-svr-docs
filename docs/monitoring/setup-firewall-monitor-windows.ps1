#requires -RunAsAdministrator
# ============================================================================
# Setup Windows Firewall (wf.msc) monitoring cho Zabbix Agent 2 — Windows.
# Tao UserParameter + Include + Timeout=10 -> restart service -> test.
# Chay (PowerShell Admin):  .\setup-firewall-monitor-windows.ps1
# Sau do: gan template "Firewall Monitor Template for Windows" cho host trong Zabbix.
# LUU Y: giam sat Windows Firewall (wf.msc), KHONG phai Microsoft Defender Antivirus.
# ============================================================================
$ErrorActionPreference = 'Stop'

# 1) Xac dinh thu muc cai + file conf tu service
$svc = Get-CimInstance Win32_Service -Filter "Name='Zabbix Agent 2'" -ErrorAction SilentlyContinue
if ($svc) {
    $exe = ($svc.PathName -replace '^"([^"]+)".*', '$1')
    $dir = Split-Path $exe
} else {
    $dir = 'C:\Program Files\Zabbix Agent 2'
    $exe = Join-Path $dir 'zabbix_agent2.exe'
    Write-Warning "Khong tim thay service 'Zabbix Agent 2' — dung mac dinh $dir"
}
$conf   = Join-Path $dir 'zabbix_agent2.conf'
$incDir = Join-Path $dir 'zabbix_agent2.d'
if (-not (Test-Path $conf)) { throw "Khong thay $conf — Zabbix Agent 2 da cai chua?" }

# 2) UserParameter (single-quote de giu nguyen $_ va dau ngoac)
New-Item -ItemType Directory -Force -Path $incDir | Out-Null
$upFile = Join-Path $incDir 'firewall.conf'
$up = 'UserParameter=win.firewall.enabled,powershell -NoProfile -NonInteractive -Command "if(@(Get-NetFirewallProfile | Where-Object {-not $_.Enabled}).Count -eq 0){1}else{0}"'
Set-Content -Path $upFile -Value $up -Encoding ASCII
Write-Host ">> wrote $upFile"

# 3) Backup + dam bao Include + Timeout=10 trong conf chinh
Copy-Item $conf "$conf.bak" -Force
$c = Get-Content $conf -Raw
$incLine = "Include=$incDir\*.conf"
if ($c -notmatch [regex]::Escape($incLine)) { $c += "`r`n$incLine`r`n"; Write-Host ">> added Include" }
if ($c -match '(?m)^\s*#?\s*Timeout\s*=') {
    $c = [regex]::Replace($c, '(?m)^\s*#?\s*Timeout\s*=.*', 'Timeout=10')
} else {
    $c += "`r`nTimeout=10`r`n"
}
Set-Content -Path $conf -Value $c -Encoding ASCII
Write-Host ">> set Timeout=10 (backup: $conf.bak)"

# 4) Restart + test
Restart-Service 'Zabbix Agent 2'
Start-Sleep -Seconds 2
Write-Host ">> restarted 'Zabbix Agent 2'"
Write-Host ">> test 'win.firewall.enabled':"
& $exe -t win.firewall.enabled -c $conf

Write-Host ">> Xong. Trong Zabbix: gan template 'Firewall Monitor Template for Windows' cho host nay."
