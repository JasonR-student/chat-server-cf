param(
    [int]$StartPort = 8080,
    [int]$EndPort = 9000,
    [switch]$NoBrowser
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$webRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'web'))
if (-not (Test-Path -LiteralPath (Join-Path $webRoot 'index.html') -PathType Leaf)) {
    throw "Client files not found: $webRoot"
}
if ($StartPort -lt 1 -or $EndPort -gt 65535 -or $StartPort -gt $EndPort) {
    throw 'Invalid port range'
}

function Get-ContentType {
    param([string]$Path)

    switch ([System.IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        '.html' { return 'text/html; charset=utf-8' }
        '.js' { return 'text/javascript; charset=utf-8' }
        '.css' { return 'text/css; charset=utf-8' }
        '.json' { return 'application/json; charset=utf-8' }
        '.wasm' { return 'application/wasm' }
        '.png' { return 'image/png' }
        '.jpg' { return 'image/jpeg' }
        '.jpeg' { return 'image/jpeg' }
        '.svg' { return 'image/svg+xml' }
        '.ico' { return 'image/x-icon' }
        '.woff2' { return 'font/woff2' }
        '.ttf' { return 'font/ttf' }
        '.otf' { return 'font/otf' }
        default { return 'application/octet-stream' }
    }
}

function Send-Response {
    param(
        [System.IO.Stream]$Stream,
        [int]$StatusCode,
        [string]$StatusText,
        [string]$ContentType,
        [byte[]]$Body,
        [bool]$HeadOnly
    )

    $header = "HTTP/1.1 $StatusCode $StatusText`r`n" +
        "Content-Type: $ContentType`r`n" +
        "Content-Length: $($Body.Length)`r`n" +
        "Cache-Control: no-cache`r`n" +
        "Connection: close`r`n`r`n"
    $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($header)
    $Stream.Write($headerBytes, 0, $headerBytes.Length)
    if (-not $HeadOnly -and $Body.Length -gt 0) {
        $Stream.Write($Body, 0, $Body.Length)
    }
    $Stream.Flush()
}

$listener = $null
$selectedPort = $null
for ($port = $StartPort; $port -le $EndPort; $port++) {
    $candidate = $null
    try {
        $candidate = [System.Net.Sockets.TcpListener]::new(
            [System.Net.IPAddress]::Loopback,
            $port
        )
        $candidate.Server.ExclusiveAddressUse = $true
        $candidate.Start()
        $listener = $candidate
        $selectedPort = $port
        break
    } catch {
        if ($candidate) {
            $candidate.Stop()
        }
    }
}

if (-not $listener -or -not $selectedPort) {
    throw "No available port found in range $StartPort-$EndPort"
}

$url = "http://127.0.0.1:$selectedPort/"
Write-Host "Jason Chat started: $url" -ForegroundColor Green
Write-Host "PORT=$selectedPort"
Write-Host 'Keep this window open. Press Ctrl+C to stop.'

if (-not $NoBrowser) {
    Start-Process $url
}

try {
    while ($true) {
        $client = $listener.AcceptTcpClient()
        try {
            $stream = $client.GetStream()
            $reader = [System.IO.StreamReader]::new(
                $stream,
                [System.Text.Encoding]::ASCII,
                $false,
                1024,
                $true
            )
            $requestLine = $reader.ReadLine()
            if ([string]::IsNullOrWhiteSpace($requestLine)) {
                continue
            }

            while (($line = $reader.ReadLine()) -ne $null -and $line -ne '') {
                # Read and ignore the remaining request headers.
            }

            $parts = $requestLine.Split(' ')
            if ($parts.Count -lt 2) {
                $body = [System.Text.Encoding]::UTF8.GetBytes('Bad Request')
                Send-Response $stream 400 'Bad Request' 'text/plain; charset=utf-8' $body $false
                continue
            }

            $method = $parts[0].ToUpperInvariant()
            $headOnly = $method -eq 'HEAD'
            if ($method -ne 'GET' -and -not $headOnly) {
                $body = [System.Text.Encoding]::UTF8.GetBytes('Only GET and HEAD are supported')
                Send-Response $stream 405 'Method Not Allowed' 'text/plain; charset=utf-8' $body $false
                continue
            }

            $urlPath = ($parts[1] -split '\?')[0]
            $urlPath = [System.Uri]::UnescapeDataString($urlPath).TrimStart('/')
            if ([string]::IsNullOrWhiteSpace($urlPath)) {
                $urlPath = 'index.html'
            }

            $relativePath = $urlPath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
            $filePath = [System.IO.Path]::GetFullPath((Join-Path $webRoot $relativePath))
            $rootPrefix = $webRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) +
                [System.IO.Path]::DirectorySeparatorChar
            if (-not $filePath.StartsWith(
                $rootPrefix,
                [System.StringComparison]::OrdinalIgnoreCase
            )) {
                $body = [System.Text.Encoding]::UTF8.GetBytes('Forbidden')
                Send-Response $stream 403 'Forbidden' 'text/plain; charset=utf-8' $body $headOnly
                continue
            }

            if (-not (Test-Path -LiteralPath $filePath -PathType Leaf) -and
                [string]::IsNullOrEmpty([System.IO.Path]::GetExtension($filePath))) {
                $filePath = Join-Path $webRoot 'index.html'
            }

            if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
                $body = [System.Text.Encoding]::UTF8.GetBytes('Not Found')
                Send-Response $stream 404 'Not Found' 'text/plain; charset=utf-8' $body $headOnly
                continue
            }

            $body = [System.IO.File]::ReadAllBytes($filePath)
            Send-Response $stream 200 'OK' (Get-ContentType $filePath) $body $headOnly
        } catch {
            Write-Warning "Local request failed: $($_.Exception.Message)"
        } finally {
            $client.Dispose()
        }
    }
} finally {
    $listener.Stop()
}
