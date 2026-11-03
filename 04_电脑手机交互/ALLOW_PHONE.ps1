$ErrorActionPreference = 'Stop'
$config = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'PC_VIEWER\network_config.json') -Raw | ConvertFrom-Json
$lan = $config.pc_ip
$address = [System.Net.IPAddress]::Parse($lan)
if ($address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { throw 'IPv4 required' }
$subnet = (($lan -split '\.')[0..2] -join '.') + '.0/24'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run ALLOW_PHONE.cmd as administrator.' }
$ruleName = 'M7-Studio-Phone-TCP-8765'
if (Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue) {
    Set-NetFirewallRule -Name $ruleName -Enabled True -Direction Inbound -Action Allow -Profile Any
    Get-NetFirewallRule -Name $ruleName | Get-NetFirewallAddressFilter | Set-NetFirewallAddressFilter -LocalAddress $lan -RemoteAddress $subnet
} else {
    New-NetFirewallRule -Name $ruleName -DisplayName 'M7 phone viewer (board LAN only)' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 8765 -LocalAddress $lan -RemoteAddress $subnet -Profile Any | Out-Null
}
Write-Host "Allowed TCP 8765 on $lan from $subnet only. Firewall remains enabled."
Read-Host 'Press Enter to close'
