param(
    [int]$Port = 0,
    [string]$ShareId = $env:PFS_SHARE_ID
)

$ErrorActionPreference = 'Stop'

function Escape-JsonString([string]$Value) {
    if ($null -eq $Value) { return '' }
    return $Value.Replace('\', '\\').Replace('"', '\"').Replace("`r", '\r').Replace("`n", '\n').Replace("`t", '\t')
}

function Write-Utf8NoBom([string]$Path, [string]$Content) {
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Path, $Content, $utf8)
}

function New-SecretPassword {
    $bytes = New-Object byte[] 16
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($bytes)
    }
    finally {
        $rng.Dispose()
    }
    return [BitConverter]::ToString($bytes).Replace('-', '').ToLowerInvariant()
}

function Get-SftpgoExe([string]$Root) {
    $arch = $env:PROCESSOR_ARCHITECTURE
    if ($arch -eq 'ARM64') {
        $arm = Join-Path $Root 'arm64\sftpgo.exe'
        if (Test-Path -LiteralPath $arm) { return $arm }
    }
    if ($arch -eq 'x86') {
        $x86 = Join-Path $Root 'x86\sftpgo.exe'
        if (Test-Path -LiteralPath $x86) { return $x86 }
    }
    $main = Join-Path $Root 'sftpgo.exe'
    if (Test-Path -LiteralPath $main) { return $main }
    throw "Could not find sftpgo.exe next to this script."
}

function Get-LanIPv4Addresses {
    $addresses = @()
    try {
        $addresses = @(
            Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
                Where-Object {
                    $_.IPAddress -notlike '127.*' -and
                    $_.IPAddress -notlike '169.254.*'
                } |
                Select-Object -ExpandProperty IPAddress -Unique
        )
    }
    catch {
        $addresses = @(
            ipconfig |
                Select-String 'IPv4' |
                ForEach-Object { ($_ -split ':')[-1].Trim() } |
                Where-Object { $_ -and $_ -notlike '127.*' -and $_ -notlike '169.254.*' }
        )
    }
    return @($addresses | Where-Object { $_ } | Select-Object -Unique)
}

function Try-AllowFirewallPort([int]$ListenPort) {
    $ruleName = 'PortableFileServer HTTP'
    $show = & netsh advfirewall firewall show rule name="$ruleName" 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -and $show -match [regex]::Escape($ruleName)) {
        & netsh advfirewall firewall set rule name="$ruleName" new localport=$ListenPort protocol=TCP | Out-Null
        return $LASTEXITCODE -eq 0
    }
    & netsh advfirewall firewall add rule name="$ruleName" dir=in action=allow protocol=TCP localport=$ListenPort profile=any | Out-Null
    return $LASTEXITCODE -eq 0
}

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location -LiteralPath $root

if ($Port -le 0) {
    if ($env:PFS_HTTP_PORT) { $Port = [int]$env:PFS_HTTP_PORT } else { $Port = 8080 }
}
if ([string]::IsNullOrWhiteSpace($ShareId)) { $ShareId = 'files' }

$portableDir = Join-Path $root '.portable'
$secretsFile = Join-Path $portableDir 'secrets.json'
$seedFile = Join-Path $portableDir 'seed.json'
$logFile = Join-Path $portableDir 'sftpgo.log'

$parentDir = Split-Path -Parent $root
$LibraryDir = [System.IO.Path]::GetFullPath((Join-Path $parentDir 'PublicFiles'))
if (-not (Test-Path -LiteralPath $LibraryDir -PathType Container)) {
    Write-Host ""
    Write-Host "ERROR: PublicFiles folder not found." -ForegroundColor Red
    Write-Host "Expected: $LibraryDir"
    Write-Host "Create that folder one level above this server and put the files in it."
    exit 1
}

if (-not (Test-Path -LiteralPath $portableDir)) {
    New-Item -ItemType Directory -Path $portableDir | Out-Null
}

$adminUser = 'admin'
$userName = 'library'
$userPass = $null

if (Test-Path -LiteralPath $secretsFile) {
    $secrets = Get-Content -LiteralPath $secretsFile -Raw | ConvertFrom-Json
    if ($secrets.admin_username) { $adminUser = [string]$secrets.admin_username }
    if ($secrets.user_username) { $userName = [string]$secrets.user_username }
    if ($secrets.user_password) { $userPass = [string]$secrets.user_password }
}

if ([string]::IsNullOrWhiteSpace($userPass)) { $userPass = New-SecretPassword }
$disabledAdminPass = New-SecretPassword

$secretsOut = @"
{
  "user_username": "$(Escape-JsonString $userName)",
  "user_password": "$(Escape-JsonString $userPass)",
  "share_id": "$(Escape-JsonString $ShareId)"
}
"@
Write-Utf8NoBom $secretsFile $secretsOut.Trim()

$seed = @"
{
  "admins": [
    {
      "status": 0,
      "username": "$(Escape-JsonString $adminUser)",
      "password": "$(Escape-JsonString $disabledAdminPass)",
      "permissions": ["*"]
    }
  ],
  "users": [
    {
      "status": 1,
      "username": "$(Escape-JsonString $userName)",
      "password": "$(Escape-JsonString $userPass)",
      "home_dir": "$(Escape-JsonString $LibraryDir)",
      "permissions": {
        "/": ["list", "download"]
      },
      "filters": {
        "denied_protocols": ["SSH", "FTP", "DAV"]
      },
      "filesystem": {
        "provider": 0
      }
    }
  ],
  "shares": [
    {
      "id": "$(Escape-JsonString $ShareId)",
      "name": "Public Files",
      "description": "Public read-only file share",
      "scope": 1,
      "paths": ["/"],
      "username": "$(Escape-JsonString $userName)",
      "expires_at": 0,
      "max_tokens": 0
    }
  ]
}
"@
Write-Utf8NoBom $seedFile $seed.Trim()

$exe = Get-SftpgoExe $root
$lanIps = Get-LanIPv4Addresses
$firewallOk = Try-AllowFirewallPort $Port

Write-Host ""
Write-Host "Portable file server" -ForegroundColor Cyan
Write-Host "PublicFiles: $LibraryDir"
Write-Host "Access is read-only. Visitors do not need a login."
Write-Host ""
Write-Host "Public URL (share this):" -ForegroundColor Green
Write-Host "  http://127.0.0.1:${Port}/"
foreach ($ip in $lanIps) {
    Write-Host "  http://${ip}:${Port}/"
}
if (-not $firewallOk) {
    Write-Host ""
    Write-Host "Windows Firewall may block other machines. Right-click LaunchFileServer.bat and run as administrator once to allow port $Port." -ForegroundColor Yellow
}
Write-Host ""
Write-Host "This window is the server. Press Ctrl+C to stop." -ForegroundColor DarkGray
Write-Host ""

$env:SFTPGO_HTTPD__BINDINGS__0__PORT = "$Port"
$env:SFTPGO_HTTPD__BINDINGS__0__ADDRESS = ''
$env:SFTPGO_HTTPD__BINDINGS__0__ENABLE_WEB_ADMIN = 'false'
$env:SFTPGO_HTTPD__BINDINGS__0__ENABLE_WEB_CLIENT = 'true'
$env:SFTPGO_HTTPD__BINDINGS__0__ENABLE_REST_API = 'true'
$env:SFTPGO_HTTPD__BINDINGS__0__RENDER_OPENAPI = 'false'
$env:SFTPGO_HTTPD__BINDINGS__0__HIDE_LOGIN_URL = '2'
$env:SFTPGO_HTTPD__BINDINGS__0__DISABLED_LOGIN_METHODS = '80'
$env:SFTPGO_SFTPD__BINDINGS__0__PORT = '0'
$env:SFTPGO_FTPD__BINDINGS__0__PORT = '0'
$env:SFTPGO_WEBDAVD__BINDINGS__0__PORT = '0'

$arguments = @(
    'serve',
    '-c', $root,
    '--loaddata-from', $seedFile,
    '--loaddata-mode', '0',
    '--log-file-path', $logFile,
    '--log-level', 'info'
)

& $exe @arguments
$exitCode = $LASTEXITCODE
if ($exitCode -ne 0) {
    Write-Host ""
    Write-Host "SFTPGo exited with code $exitCode. Last log lines:" -ForegroundColor Red
    if (Test-Path -LiteralPath $logFile) {
        Get-Content -LiteralPath $logFile -Tail 40
    }
}
exit $exitCode
