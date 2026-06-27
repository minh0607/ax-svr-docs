# ============================================================================
# AX Svr — Apply firewall cho Web Server (Windows 2025). CHỈ admin RDP được.
# RDP (3389) chỉ từ IP admin; HTTP (80) chỉ từ 2 Proxy qua LAN.
# ----------------------------------------------------------------------------
# Dùng (PowerShell admin):
#   .\apply-firewall-windows.ps1 -AdminIps "107.118.210.50","107.118.210.51"
# ============================================================================
param(
  [Parameter(Mandatory=$true)][string[]]$AdminIps,
  [string[]]$ProxyLanIps = @("10.1.1.98","10.1.1.99"),
  [string]$MonIp = "10.1.1.96"
)

Write-Host "Áp firewall: RDP chỉ cho $($AdminIps -join ', '); HTTP từ proxy $($ProxyLanIps -join ', ')"

# Xóa rule cũ của AX (nếu chạy lại)
Get-NetFirewallRule -DisplayName "AX *" -ErrorAction SilentlyContinue | Remove-NetFirewallRule

# Mặc định: chặn inbound (profile), cho outbound
Set-NetFirewallProfile -Profile Domain,Private,Public -DefaultInboundAction Block -DefaultOutboundAction Allow

# RDP 3389 — CHỈ admin
New-NetFirewallRule -DisplayName "AX RDP from admin" -Direction Inbound -Protocol TCP `
  -LocalPort 3389 -RemoteAddress $AdminIps -Action Allow | Out-Null

# HTTP 80 — chỉ từ 2 Proxy (LAN)
New-NetFirewallRule -DisplayName "AX HTTP from proxy" -Direction Inbound -Protocol TCP `
  -LocalPort 80 -RemoteAddress $ProxyLanIps -Action Allow | Out-Null

# windows_exporter 9182 — chỉ cho mon
New-NetFirewallRule -DisplayName "AX win_exporter from mon" -Direction Inbound -Protocol TCP `
  -LocalPort 9182 -RemoteAddress $MonIp -Action Allow | Out-Null

Write-Host "XONG. RDP chỉ mở cho IP admin; HTTP chỉ từ proxy; 9182 chỉ cho mon."
Get-NetFirewallRule -DisplayName "AX *" | Format-Table DisplayName,Enabled,Direction,Action
