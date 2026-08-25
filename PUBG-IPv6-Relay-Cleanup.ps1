param(
    [int]$RelayPid = 0,
    [Parameter(Mandatory = $true)]
    [string]$Root,
    [string]$SessionId = '',
    [switch]$StopRelay
)

$ErrorActionPreference = 'SilentlyContinue'
$hostnames = @(
    'prod-live-front.playbattlegrounds.com',
    'prod-live-images.playbattlegrounds.com',
    'prod-live-cfentry.playbattlegrounds.com',
    'country-code.playbattlegrounds.com',
    'prod-live-xenuine.playbattlegrounds.com',
    'acrt-pcprod.acs.pubg.com',
    'zkd-pcprod.acs.pubg.com',
    'zk-ga-pcprod.acs.pubg.com',
    'log-brofront.kraftonde.com'
)

$pidPath = Join-Path $Root 'PUBG-IPv6-Relay.pid'
$controlAliasPath = Join-Path $Root 'PUBG-Control-Loopback-IPs.txt'
if ($StopRelay -and (Test-Path -LiteralPath $pidPath)) {
    $savedPid = [int](Get-Content -LiteralPath $pidPath -First 1)
    if ($savedPid -gt 0 -and $savedPid -ne $PID) {
        $savedProcess = Get-CimInstance Win32_Process -Filter "ProcessId=$savedPid"
        if ($savedProcess.CommandLine -like '*PUBG-IPv6-Relay.ps1*') {
            Stop-Process -Id $savedPid -Force -ErrorAction SilentlyContinue
            $RelayPid = $savedPid
        }
    }
}

if ($RelayPid -gt 0 -and $RelayPid -ne $PID) {
    Wait-Process -Id $RelayPid -ErrorAction SilentlyContinue
}

# An old watcher must never clean hosts belonging to a newer relay session.
if ($SessionId) {
    if (-not (Test-Path -LiteralPath $pidPath)) { exit 0 }
    $pidLines = @(Get-Content -LiteralPath $pidPath)
    if ($pidLines.Count -lt 2 -or $pidLines[1] -ne $SessionId) { exit 0 }
}

$hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
if (Test-Path -LiteralPath $hostsPath) {
    $cleanLines = @(Get-Content -LiteralPath $hostsPath | Where-Object {
        $line = $_
        -not ($hostnames | Where-Object { $line -match [regex]::Escape($_) })
    })
    [IO.File]::WriteAllLines($hostsPath, [string[]]$cleanLines, [Text.Encoding]::ASCII)
}

if (Test-Path -LiteralPath $controlAliasPath) {
    $controlAliases = @(Get-Content -LiteralPath $controlAliasPath |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ })
    foreach ($controlAlias in $controlAliases) {
        Get-NetIPAddress -AddressFamily IPv4 -IPAddress $controlAlias -ErrorAction SilentlyContinue |
            Where-Object { $_.InterfaceIndex -eq 1 -or $_.InterfaceAlias -match 'Loopback|Pseudo' } |
            Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
    }
}

Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $Root 'PUBG-IPv6-Relay-target.txt') -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $controlAliasPath -Force -ErrorAction SilentlyContinue
Clear-DnsClientCache
