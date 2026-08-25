param(
    [string[]]$Hostnames = @(
        'prod-live-front.playbattlegrounds.com',
        'prod-live-images.playbattlegrounds.com',
        'prod-live-cfentry.playbattlegrounds.com',
        'country-code.playbattlegrounds.com',
        'prod-live-xenuine.playbattlegrounds.com',
        'acrt-pcprod.acs.pubg.com',
        'zkd-pcprod.acs.pubg.com'
    ),
    [string]$ControlHostname = 'zk-ga-pcprod.acs.pubg.com',
    [int]$ListenPort = 443,
    [int]$RemotePort = 443,
    [int]$ControlPort = 40002
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$pidPath = Join-Path $root 'PUBG-IPv6-Relay.pid'
$targetPath = Join-Path $root 'PUBG-IPv6-Relay-target.txt'
$controlAliasPath = Join-Path $root 'PUBG-Control-Loopback-IPs.txt'
$cleanupScriptPath = Join-Path $root 'PUBG-IPv6-Relay-Cleanup.ps1'
$tag = '# PUBG_IPV6_RELAY'
$allManagedHostnames = @($Hostnames) + @($ControlHostname, 'log-brofront.kraftonde.com')

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Administrator)) {
    throw 'Run START_PUBG_IPv6_RELAY.cmd and approve the administrator prompt.'
}

# Stop relay copies launched from older folders and let their cleanup watchers finish.
$oldRelayProcesses = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object {
        $_.ProcessId -ne $PID -and
        $_.CommandLine -match 'PUBG-IPv6-Relay\.ps1' -and
        $_.CommandLine -notmatch 'PUBG-IPv6-Relay-Cleanup\.ps1'
    })
foreach ($oldRelayProcess in $oldRelayProcesses) {
    Stop-Process -Id $oldRelayProcess.ProcessId -Force -ErrorAction SilentlyContinue
}
if ($oldRelayProcesses.Count -gt 0) { Start-Sleep -Seconds 3 }

# Always recover from a stale previous run before doing DNS resolution.
& $cleanupScriptPath -RelayPid 0 -Root $root -StopRelay
$remainingHostEntries = @(Get-Content -LiteralPath $hostsPath | Where-Object {
    $line = $_
    $allManagedHostnames | Where-Object { $line -match [regex]::Escape($_) }
})
if ($remainingHostEntries.Count -gt 0) {
    throw 'Could not remove stale PUBG entries from hosts. Run STOP_AND_RESTORE.cmd as administrator.'
}

function Resolve-DnsAddresses([string]$Name, [string]$RecordType) {
    $addresses = @()
    try {
        $addresses = @(Resolve-DnsName -Name $Name -Type $RecordType -DnsOnly -ErrorAction Stop |
            Where-Object { $_.IPAddress } |
            Select-Object -ExpandProperty IPAddress -Unique)
    } catch {}

    if ($addresses.Count -eq 0) {
        $dnsServers = @(Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.ServerAddresses.Count -gt 0 } |
            ForEach-Object { $_.ServerAddresses } |
            Select-Object -Unique)
        foreach ($dnsServer in $dnsServers) {
            try {
                $addresses = @(Resolve-DnsName -Name $Name -Type $RecordType -Server $dnsServer -DnsOnly -ErrorAction Stop |
                    Where-Object { $_.IPAddress } |
                    Select-Object -ExpandProperty IPAddress -Unique)
                if ($addresses.Count -gt 0) { break }
            } catch {}
        }
    }
    return @($addresses)
}

function ConvertTo-Nat64Address([string]$IPv4Address, [string]$Prefix = '64:ff9b::') {
    $result = [Net.IPAddress]::Parse($Prefix).GetAddressBytes()
    $ipv4 = [Net.IPAddress]::Parse($IPv4Address).GetAddressBytes()
    [Array]::Copy($ipv4, 0, $result, 12, 4)
    return ([Net.IPAddress]::new([byte[]]$result)).ToString()
}

function Test-IPv6TcpTarget([string]$Address, [int]$Port, [int]$TimeoutMs = 8000) {
    $probe = [Net.Sockets.TcpClient]::new([Net.Sockets.AddressFamily]::InterNetworkV6)
    try {
        $connect = $probe.ConnectAsync([Net.IPAddress]::Parse($Address), $Port)
        return ($connect.Wait($TimeoutMs) -and $probe.Connected)
    } catch {
        return $false
    } finally {
        $probe.Dispose()
    }
}

function Measure-IPv6TcpTarget([string]$Address, [int]$Port, [int]$TimeoutMs = 5000) {
    $probe = [Net.Sockets.TcpClient]::new([Net.Sockets.AddressFamily]::InterNetworkV6)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        $connect = $probe.ConnectAsync([Net.IPAddress]::Parse($Address), $Port)
        if (-not $connect.Wait($TimeoutMs) -or -not $probe.Connected) { return $null }
        $timer.Stop()
        return [int][Math]::Max(1, $timer.ElapsedMilliseconds)
    } catch {
        return $null
    } finally {
        $timer.Stop()
        $probe.Dispose()
    }
}

function Get-Median([int[]]$Values) {
    $ordered = @($Values | Sort-Object)
    if ($ordered.Count -eq 0) { return [int]::MaxValue }
    $middle = [int][Math]::Floor($ordered.Count / 2)
    if (($ordered.Count % 2) -eq 1) { return [int]$ordered[$middle] }
    return [int][Math]::Round(($ordered[$middle - 1] + $ordered[$middle]) / 2.0)
}

function Test-IsNativeIPv6([string]$Address) {
    try {
        $normalized = ([Net.IPAddress]::Parse($Address)).ToString().ToLowerInvariant()
        $translatorPrefixes = @(
            '64:ff9b:',
            '2001:67c:2960:6464:',
            '2a00:1098:2b:',
            '2a00:1098:2c:1:',
            '2a01:4f8:c2c:123f:64:',
            '2a01:4f9:c010:3f02:64:'
        )
        foreach ($translatorPrefix in $translatorPrefixes) {
            if ($normalized.StartsWith($translatorPrefix)) { return $false }
        }
        return $true
    } catch {
        return $false
    }
}

function Resolve-Dns64Addresses([string]$Name, [string]$Server) {
    try {
        return @(Resolve-DnsName -Name $Name -Type AAAA -Server $Server -DnsOnly -ErrorAction Stop |
            Where-Object { $_.IPAddress } |
            Select-Object -ExpandProperty IPAddress -Unique)
    } catch {
        return @()
    }
}

function Get-Nat64PrefixesFromDns64([string[]]$Servers) {
    $prefixes = @()
    foreach ($server in $Servers) {
        $translatedAddresses = @(Resolve-Dns64Addresses 'ipv4only.arpa' $server)
        foreach ($translatedAddress in $translatedAddresses) {
            try {
                $bytes = [Net.IPAddress]::Parse([string]$translatedAddress).GetAddressBytes()
                if ($bytes.Length -ne 16) { continue }
                if ($bytes[12] -ne 192 -or $bytes[13] -ne 0 -or $bytes[14] -ne 0) { continue }
                if ($bytes[15] -ne 170 -and $bytes[15] -ne 171) { continue }
                [Array]::Clear($bytes, 12, 4)
                $prefixes += ([Net.IPAddress]::new([byte[]]$bytes)).ToString()
            } catch {}
        }
    }
    return @($prefixes | Select-Object -Unique)
}

Write-Host 'Resolving PUBG control channel...' -ForegroundColor Cyan
$controlIPv4Addresses = @(Resolve-DnsAddresses $ControlHostname 'A' |
    Where-Object {
        $parsed = $null
        [Net.IPAddress]::TryParse([string]$_, [ref]$parsed) -and
        $parsed.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork
    } |
    Select-Object -Unique)
if ($controlIPv4Addresses.Count -eq 0) {
    throw "No IPv4 address was returned for $ControlHostname."
}

$publicDns64Servers = @(
    '2001:67c:2b0::4',
    '2a01:4f9:c010:3f02::1',
    '2a01:4f8:c2c:123f::1',
    '2a00:1098:2b::1',
    '2a00:1098:2c::1'
)
$publicNat64Prefixes = @('2001:67c:2960:6464::')
$publicNat64Prefixes += @(Get-Nat64PrefixesFromDns64 $publicDns64Servers)
$publicNat64Prefixes = @($publicNat64Prefixes | Select-Object -Unique)

# MegaFon 64:ff9b::/96 is deliberately excluded for TCP 40002. Previous
# captures proved: SYN/SYN-ACK/ACK succeeds, but application data is lost.
$controlRoutes = @()
foreach ($prefix in $publicNat64Prefixes) {
    $latencies = @()
    $attemptCount = 0
    $successCount = 0
    $reachableAddresses = [ordered]@{}
    foreach ($controlIPv4Address in $controlIPv4Addresses) {
        $candidate = ConvertTo-Nat64Address ([string]$controlIPv4Address) $prefix
        for ($sample = 0; $sample -lt 5; $sample++) {
            $attemptCount++
            $sampleLatency = Measure-IPv6TcpTarget $candidate $ControlPort 2200
            if ($null -ne $sampleLatency) {
                $successCount++
                $latencies += $sampleLatency
                $reachableAddresses[[string]$controlIPv4Address] = $candidate
            }
        }
    }
    if ($reachableAddresses.Count -gt 0) {
        $controlRoutes += [pscustomobject]@{
            Prefix = $prefix
            MedianLatencyMs = Get-Median ([int[]]$latencies)
            LossPercent = [int][Math]::Round(100.0 * ($attemptCount - $successCount) / $attemptCount)
            SuccessCount = $successCount
            ReachableAddresses = $reachableAddresses
        }
    }
}
if ($controlRoutes.Count -eq 0) {
    throw "No external NAT64 can reach ${ControlHostname}:${ControlPort}."
}
$selectedControlRoute = (@($controlRoutes | Sort-Object LossPercent, MedianLatencyMs))[0]
$controlNat64Prefix = [string]$selectedControlRoute.Prefix
$controlNat64Mode = "external NAT64 ${controlNat64Prefix}/96 only for TCP 40002"
Write-Host "Control route selected: $controlNat64Mode, median $($selectedControlRoute.MedianLatencyMs) ms, TCP probe loss $($selectedControlRoute.LossPercent)%" -ForegroundColor Green

$controlTargetMap = [ordered]@{}
$fallbackControlAddress = @($selectedControlRoute.ReachableAddresses.Values)[0]
foreach ($controlIPv4Address in $controlIPv4Addresses) {
    $candidate = if ($selectedControlRoute.ReachableAddresses.Contains([string]$controlIPv4Address)) {
        [string]$selectedControlRoute.ReachableAddresses[[string]$controlIPv4Address]
    } else {
        [string]$fallbackControlAddress
    }
    $controlTargetMap[[string]$controlIPv4Address] = [pscustomobject]@{ Address = $candidate; Mode = $controlNat64Mode }
    Write-Host "$ControlHostname $controlIPv4Address -> $candidate ($controlNat64Mode)" -ForegroundColor Green
}

Write-Host 'Resolving PUBG HTTPS: native IPv6 -> MegaFon NAT64 -> external fallback...' -ForegroundColor Cyan
$targetMap = [ordered]@{}
$targetModeMap = [ordered]@{}
foreach ($hostname in $Hostnames) {
    $bestAddress = $null
    $bestLatency = [int]::MaxValue
    $bestMode = $null

    # First priority: true AAAA. The connection leaves with the PC's MegaFon
    # IPv6 address and does not pass through any translator.
    foreach ($nativeAddress in @(Resolve-DnsAddresses $hostname 'AAAA')) {
        if (-not (Test-IsNativeIPv6 ([string]$nativeAddress))) { continue }
        $latency = Measure-IPv6TcpTarget ([string]$nativeAddress) $RemotePort 3000
        if ($null -ne $latency -and $latency -lt $bestLatency) {
            $bestAddress = [string]$nativeAddress
            $bestLatency = $latency
            $bestMode = 'native IPv6 over MegaFon (Russian source IPv6)'
        }
    }

    # Second priority: MegaFon's own Russian NAT64 for IPv4-only HTTPS.
    if (-not $bestAddress) {
        foreach ($ipv4Address in @(Resolve-DnsAddresses $hostname 'A')) {
            $candidate = ConvertTo-Nat64Address ([string]$ipv4Address) '64:ff9b::'
            $latency = Measure-IPv6TcpTarget $candidate $RemotePort 3000
            if ($null -ne $latency -and $latency -lt $bestLatency) {
                $bestAddress = $candidate
                $bestLatency = $latency
                $bestMode = 'MegaFon Russian NAT64 64:ff9b::/96'
            }
        }
    }

    # Last resort: the already selected public translator. This is expected
    # only for an IPv4-only hostname that MegaFon NAT64 cannot reach.
    if (-not $bestAddress) {
        foreach ($ipv4Address in @(Resolve-DnsAddresses $hostname 'A')) {
            $candidate = ConvertTo-Nat64Address ([string]$ipv4Address) $controlNat64Prefix
            $latency = Measure-IPv6TcpTarget $candidate $RemotePort 3000
            if ($null -ne $latency -and $latency -lt $bestLatency) {
                $bestAddress = $candidate
                $bestLatency = $latency
                $bestMode = "external NAT64 fallback ${controlNat64Prefix}/96"
            }
        }
    }

    if (-not $bestAddress) { throw "No IPv6/NAT64 route can reach ${hostname}:${RemotePort}." }
    $targetMap[$hostname] = $bestAddress
    $targetModeMap[$hostname] = $bestMode
    Write-Host "$hostname -> $bestAddress ($bestMode, ${bestLatency} ms)" -ForegroundColor Green
}

$singleNat64Prefix = $controlNat64Prefix
$singleNat64Mode = 'Russian-first hybrid; external NAT64 only where mandatory'

# A separate loopback IP per hostname prevents Chromium/CEF from reusing one
# HTTP/2 TLS connection for several PUBG CloudFront hostnames.
$httpsListenMap = [ordered]@{}
$loopbackOctet = 2
foreach ($hostname in $targetMap.Keys) {
    $httpsListenMap[$hostname] = "127.0.0.$loopbackOctet"
    $loopbackOctet++
}

$sessionId = [guid]::NewGuid().ToString('N')
Set-Content -LiteralPath $pidPath -Value @($PID, $sessionId) -Encoding ASCII
$watcherArguments = "-NoProfile -ExecutionPolicy Bypass -File `"$cleanupScriptPath`" -RelayPid $PID -Root `"$root`" -SessionId $sessionId"
Start-Process -FilePath 'powershell.exe' -ArgumentList $watcherArguments -WindowStyle Hidden

# Keep the real zk-ga DNS answer. Assign only its exact AWS /32 addresses to
# Windows loopback so the game still sees the original destination address.
# The listener below binds only TCP 40002 on these aliases.
$loopbackInterface = Get-NetIPInterface -AddressFamily IPv4 -ErrorAction Stop |
    Where-Object { $_.InterfaceIndex -eq 1 -or $_.InterfaceAlias -match 'Loopback|Pseudo' } |
    Sort-Object @{ Expression = { if ($_.InterfaceIndex -eq 1) { 0 } else { 1 } } } |
    Select-Object -First 1
if (-not $loopbackInterface) {
    throw 'Windows IPv4 loopback interface was not found.'
}

Remove-Item -LiteralPath $controlAliasPath -Force -ErrorAction SilentlyContinue
foreach ($controlIPv4Address in $controlIPv4Addresses) {
    $existingAddresses = @(Get-NetIPAddress -AddressFamily IPv4 -IPAddress $controlIPv4Address -ErrorAction SilentlyContinue)
    $foreignAddress = @($existingAddresses | Where-Object { $_.InterfaceIndex -ne $loopbackInterface.InterfaceIndex })
    if ($foreignAddress.Count -gt 0) {
        throw "Cannot create the local control alias $controlIPv4Address because Windows already owns it on another interface."
    }

    # Record before creation: if New-NetIPAddress fails, cleanup only attempts
    # to remove a nonexistent address. It can never remove an unrelated address.
    Add-Content -LiteralPath $controlAliasPath -Value $controlIPv4Address -Encoding ASCII
    if ($existingAddresses.Count -eq 0) {
        New-NetIPAddress -InterfaceIndex $loopbackInterface.InterfaceIndex `
            -IPAddress $controlIPv4Address -PrefixLength 32 -SkipAsSource $true `
            -PolicyStore ActiveStore -ErrorAction Stop | Out-Null
    }
}
Start-Sleep -Milliseconds 500

$originalLines = @(Get-Content -LiteralPath $hostsPath -ErrorAction Stop)
$backupPath = Join-Path $root ('hosts-before-pubg-relay-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt')
Copy-Item -LiteralPath $hostsPath -Destination $backupPath -Force

$cleanLines = @($originalLines | Where-Object {
    $line = $_
    -not ($allManagedHostnames | Where-Object { $line -match [regex]::Escape($_) })
})
foreach ($hostname in $targetMap.Keys) {
    $cleanLines += "$($httpsListenMap[$hostname]) $hostname $tag"
}
[IO.File]::WriteAllLines($hostsPath, [string[]]$cleanLines, [Text.Encoding]::ASCII)
Clear-DnsClientCache

$targetLines = @(
    "Mode: $singleNat64Mode"
    "Control NAT64 prefix: ${controlNat64Prefix}/96"
    "Control TCP median: $($selectedControlRoute.MedianLatencyMs) ms"
    "Control TCP probe loss: $($selectedControlRoute.LossPercent)%"
    ''
    'HTTPS routes:'
)
$targetLines += @($targetMap.GetEnumerator() | ForEach-Object {
    "$($_.Key) $($httpsListenMap[$_.Key]):$ListenPort -> [$($_.Value)]:$RemotePort ($($targetModeMap[$_.Key]))"
})
$targetLines += @('', 'Control routes:')
$targetLines += @($controlIPv4Addresses | ForEach-Object {
    $controlTarget = $controlTargetMap[[string]$_]
    "$ControlHostname $_ -> [$($controlTarget.Address)]:$ControlPort ($($controlTarget.Mode))"
})
Set-Content -LiteralPath $targetPath -Value $targetLines -Encoding ASCII

$source = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;

public static class PubgSocketOptions
{
    public static void EnableKeepAlive(TcpClient client)
    {
        try
        {
            Socket socket = client.Client;
            socket.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.KeepAlive, true);

            // Windows SIO_KEEPALIVE_VALS: enabled, idle time (ms), interval (ms).
            byte[] values = new byte[12];
            BitConverter.GetBytes((uint)1).CopyTo(values, 0);
            BitConverter.GetBytes((uint)30000).CopyTo(values, 4);
            BitConverter.GetBytes((uint)5000).CopyTo(values, 8);
            socket.IOControl(IOControlCode.KeepAliveValues, values, null);
        }
        catch
        {
            // SO_KEEPALIVE above is sufficient on systems that reject custom intervals.
        }
    }
}

public static class PubgTcp6Relay
{
    private static List<TcpListener> listeners = new List<TcpListener>();
    private static volatile bool running;

    public static void Start(string[] hostnames, string[] listenAddresses, string[] targetAddresses, int listenPort, int remotePort)
    {
        if (running) return;
        running = true;

        for (int i = 0; i < hostnames.Length; i++)
        {
            TcpListener listener = new TcpListener(IPAddress.Parse(listenAddresses[i]), listenPort);
            IPAddress target = IPAddress.Parse(targetAddresses[i]);
            string hostname = hostnames[i];
            listener.Start(32);
            listeners.Add(listener);
            StartAcceptThread(listener, target, hostname, remotePort);
        }
    }

    private static void StartAcceptThread(TcpListener listener, IPAddress target, string hostname, int remotePort)
    {
        Thread acceptThread = new Thread(delegate()
        {
            while (running)
            {
                try
                {
                    TcpClient local = listener.AcceptTcpClient();
                    Thread worker = new Thread(delegate() { Handle(local, target, hostname, remotePort); });
                    worker.IsBackground = true;
                    worker.Start();
                }
                catch
                {
                    if (!running) return;
                }
            }
        });
        acceptThread.IsBackground = true;
        acceptThread.Start();
    }

    private static void Handle(TcpClient local, IPAddress target, string expectedHostname, int remotePort)
    {
        TcpClient remote = null;
        try
        {
            local.NoDelay = true;
            PubgSocketOptions.EnableKeepAlive(local);
            NetworkStream localStream = local.GetStream();

            // The timeout is only for the initial ClientHello. Leaving it enabled
            // kills an idle BIFROST WebSocket while the player is in a match.
            localStream.ReadTimeout = 10000;
            byte[] firstRecord = ReadFirstTlsRecord(localStream);
            localStream.ReadTimeout = Timeout.Infinite;
            string observedHostname = GetServerName(firstRecord);

            Console.WriteLine(expectedHostname + " (SNI " + (observedHostname ?? "unknown") + ") -> [" + target + "]:" + remotePort);
            remote = new TcpClient(AddressFamily.InterNetworkV6);
            remote.NoDelay = true;
            remote.Connect(target, remotePort);
            PubgSocketOptions.EnableKeepAlive(remote);

            NetworkStream remoteStream = remote.GetStream();
            remoteStream.Write(firstRecord, 0, firstRecord.Length);
            remoteStream.Flush();

            bool reportServiceData =
                expectedHostname.StartsWith("acrt-", StringComparison.OrdinalIgnoreCase) ||
                expectedHostname.StartsWith("zkd-", StringComparison.OrdinalIgnoreCase);
            Thread upload = new Thread(delegate()
            {
                Pump(localStream, remoteStream, false, expectedHostname + " client->server", reportServiceData);
                // Never leave a half-dead connection accepting client bytes.
                try { remote.Close(); } catch {}
            });
            upload.IsBackground = true;
            upload.Start();
            Pump(remoteStream, localStream, reportServiceData, expectedHostname + " server->client", reportServiceData);
        }
        catch (Exception ex)
        {
            Console.WriteLine("Relay connection error: " + ex.Message);
        }
        finally
        {
            try { local.Close(); } catch {}
            if (remote != null) try { remote.Close(); } catch {}
        }
    }

    private static byte[] ReadFirstTlsRecord(NetworkStream stream)
    {
        byte[] header = ReadExact(stream, 5);
        int length = (header[3] << 8) | header[4];
        if (length <= 0 || length > 65535) throw new IOException("Invalid TLS record length.");
        byte[] body = ReadExact(stream, length);
        byte[] result = new byte[5 + length];
        Buffer.BlockCopy(header, 0, result, 0, 5);
        Buffer.BlockCopy(body, 0, result, 5, length);
        return result;
    }

    private static byte[] ReadExact(Stream stream, int count)
    {
        byte[] data = new byte[count];
        int offset = 0;
        while (offset < count)
        {
            int n = stream.Read(data, offset, count - offset);
            if (n <= 0) throw new EndOfStreamException();
            offset += n;
        }
        return data;
    }

    private static string GetServerName(byte[] data)
    {
        try
        {
            if (data.Length < 9 || data[0] != 22 || data[5] != 1) return null;
            int p = 9 + 2 + 32;
            int sessionLength = data[p++];
            p += sessionLength;
            int cipherLength = (data[p] << 8) | data[p + 1];
            p += 2 + cipherLength;
            int compressionLength = data[p++];
            p += compressionLength;
            int extensionsLength = (data[p] << 8) | data[p + 1];
            p += 2;
            int extensionsEnd = Math.Min(data.Length, p + extensionsLength);

            while (p + 4 <= extensionsEnd)
            {
                int type = (data[p] << 8) | data[p + 1];
                int length = (data[p + 2] << 8) | data[p + 3];
                p += 4;
                if (p + length > extensionsEnd) return null;
                if (type == 0 && length >= 5)
                {
                    int q = p + 2;
                    int nameType = data[q++];
                    int nameLength = (data[q] << 8) | data[q + 1];
                    q += 2;
                    if (nameType == 0 && q + nameLength <= p + length)
                        return Encoding.ASCII.GetString(data, q, nameLength);
                }
                p += length;
            }
        }
        catch {}
        return null;
    }

    private static void Pump(Stream input, Stream output, bool reportFirstChunk, string label, bool reportLifecycle)
    {
        byte[] buffer = new byte[65536];
        bool firstChunk = true;
        string endReason = "EOF";
        try
        {
            int count;
            while ((count = input.Read(buffer, 0, buffer.Length)) > 0)
            {
                if (reportFirstChunk && firstChunk)
                {
                    Console.WriteLine(label + " data received: " + count + " bytes");
                    firstChunk = false;
                }
                output.Write(buffer, 0, count);
                output.Flush();
            }
        }
        catch (Exception ex)
        {
            endReason = ex.GetType().Name + ": " + ex.Message;
        }
        finally
        {
            if (reportLifecycle) Console.WriteLine(label + " stream ended: " + endReason);
        }
    }

    public static void Stop()
    {
        running = false;
        foreach (TcpListener listener in listeners)
            try { listener.Stop(); } catch {}
        listeners.Clear();
    }
}

public static class PubgFixedTcp6Relay
{
    private static List<TcpListener> listeners = new List<TcpListener>();
    private static volatile bool running;
    private static int targetPort;

    public static void Start(string[] listenAddresses, string[] targetAddresses, int listenPort, int remotePort)
    {
        if (running) return;
        targetPort = remotePort;
        running = true;

        for (int i = 0; i < listenAddresses.Length; i++)
        {
            TcpListener listener = new TcpListener(IPAddress.Parse(listenAddresses[i]), listenPort);
            IPAddress remoteTarget = IPAddress.Parse(targetAddresses[i]);
            listener.Start(32);
            listeners.Add(listener);
            StartAcceptThread(listener, remoteTarget);
        }
    }

    private static void StartAcceptThread(TcpListener listener, IPAddress remoteTarget)
    {
        Thread acceptThread = new Thread(delegate()
        {
            while (running)
            {
                try
                {
                    TcpClient local = listener.AcceptTcpClient();
                    Thread worker = new Thread(delegate() { Handle(local, remoteTarget); });
                    worker.IsBackground = true;
                    worker.Start();
                }
                catch
                {
                    if (!running) return;
                }
            }
        });
        acceptThread.IsBackground = true;
        acceptThread.Start();
    }

    private static void Handle(TcpClient local, IPAddress remoteTarget)
    {
        TcpClient remote = null;
        try
        {
            local.NoDelay = true;
            PubgSocketOptions.EnableKeepAlive(local);
            remote = new TcpClient(AddressFamily.InterNetworkV6);
            remote.NoDelay = true;
            remote.Connect(remoteTarget, targetPort);
            PubgSocketOptions.EnableKeepAlive(remote);
            Console.WriteLine("control connection " + local.Client.LocalEndPoint + " -> [" + remoteTarget + "]:" + targetPort);

            NetworkStream localStream = local.GetStream();
            NetworkStream remoteStream = remote.GetStream();
            Thread upload = new Thread(delegate()
            {
                Pump(localStream, remoteStream, false);
                try { remote.Close(); } catch {}
            });
            upload.IsBackground = true;
            upload.Start();
            Pump(remoteStream, localStream, true);
        }
        catch (Exception ex)
        {
            Console.WriteLine("Control relay error: " + ex.Message);
        }
        finally
        {
            try { local.Close(); } catch {}
            if (remote != null) try { remote.Close(); } catch {}
        }
    }

    private static void Pump(Stream input, Stream output, bool reportFirstChunk)
    {
        byte[] buffer = new byte[65536];
        bool firstChunk = true;
        try
        {
            int count;
            while ((count = input.Read(buffer, 0, buffer.Length)) > 0)
            {
                if (reportFirstChunk && firstChunk)
                {
                    Console.WriteLine("control server data received: " + count + " bytes");
                    firstChunk = false;
                }
                output.Write(buffer, 0, count);
                output.Flush();
            }
        }
        catch {}
    }

    public static void Stop()
    {
        running = false;
        foreach (TcpListener listener in listeners)
            try { listener.Stop(); } catch {}
        listeners.Clear();
    }
}
'@

Add-Type -TypeDefinition $source -Language CSharp
$targetNames = [string[]]@($targetMap.Keys)
$httpsListenAddresses = [string[]]@($targetNames | ForEach-Object { $httpsListenMap[$_] })
$targetAddresses = [string[]]@($targetNames | ForEach-Object { $targetMap[$_] })
$controlTargetAddresses = [string[]]@($controlIPv4Addresses | ForEach-Object {
    [string]($controlTargetMap[[string]$_].Address)
})
[PubgTcp6Relay]::Start($targetNames, $httpsListenAddresses, $targetAddresses, $ListenPort, $RemotePort)
[PubgFixedTcp6Relay]::Start([string[]]$controlIPv4Addresses, $controlTargetAddresses, $ControlPort, $ControlPort)

Write-Host ''
Write-Host 'PUBG Russian-first hybrid relay v12 is RUNNING.' -ForegroundColor Green
$httpsEndpointText = ($httpsListenAddresses | ForEach-Object { "${_}:$ListenPort" }) -join ', '
Write-Host "$httpsEndpointText -> PUBG HTTPS via native MegaFon IPv6 / MegaFon NAT64 first"
Write-Host (($controlIPv4Addresses -join ', ') + ":$ControlPort -> external NAT64 only for broken MegaFon TCP 40002")
Write-Host ("Control benchmark: median " + $selectedControlRoute.MedianLatencyMs + " ms, TCP probe loss " + $selectedControlRoute.LossPercent + "%")
Write-Host ("Redirected HTTPS hostnames: " + $targetNames.Count)
Write-Host 'PUBG match UDP traffic is untouched and goes directly through MegaFon.' -ForegroundColor Green
Write-Host 'Persistent WebSocket mode: infinite post-handshake timeout; TCP keepalive 30s' -ForegroundColor Green
Write-Host "Hosts backup: $backupPath"
Write-Host ''
Write-Host 'Keep this window open while playing.' -ForegroundColor Yellow
Write-Host 'Close this window after the game: hosts will be restored automatically.' -ForegroundColor Yellow
Write-Host ''

try {
    while ($true) { Start-Sleep -Seconds 2 }
} finally {
    [PubgFixedTcp6Relay]::Stop()
    [PubgTcp6Relay]::Stop()
}
