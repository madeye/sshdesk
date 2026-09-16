[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$Repository = "rylena/sshdesk"
$Branch = "main"
$InstallerUrl = "https://raw.githubusercontent.com/rylena/sshdesk/main/scripts/install.ps1"

function Write-Step([string]$Message) {
    Write-Host "SSHDESK: $Message"
}

function Test-Administrator {
    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $Principal = [Security.Principal.WindowsPrincipal]::new($Identity)
    return $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not $IsWindows -and $env:OS -ne "Windows_NT") {
    throw "install.ps1 supports Windows; use install.sh on Linux or macOS"
}
if (-not (Test-Administrator)) {
    Write-Step "requesting Administrator permission..."
    $ElevatedCommand = "& ([scriptblock]::Create((Invoke-RestMethod '$InstallerUrl')))"
    $Arguments = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-Command",
        $ElevatedCommand
    )
    Start-Process powershell.exe -Verb RunAs -ArgumentList $Arguments | Out-Null
    return
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$TemporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) ("sshdesk-install-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $TemporaryDirectory | Out-Null

try {
    $Capability = Get-WindowsCapability -Online -Name "OpenSSH.Server~~~~0.0.1.0"
    if ($Capability.State -ne "Installed") {
        Write-Step "installing the Windows OpenSSH server..."
        Add-WindowsCapability -Online -Name "OpenSSH.Server~~~~0.0.1.0" | Out-Null
    }

    Write-Step "downloading SSHDESK..."
    $Archive = Join-Path $TemporaryDirectory "sshdesk.zip"
    $SourceDirectory = Join-Path $TemporaryDirectory "source"
    Invoke-WebRequest "https://github.com/$Repository/archive/refs/heads/$Branch.zip" `
        -OutFile $Archive -UseBasicParsing
    Expand-Archive -Path $Archive -DestinationPath $SourceDirectory
    $ProjectDirectory = Get-ChildItem $SourceDirectory -Directory | Select-Object -First 1
    if (-not $ProjectDirectory) {
        throw "downloaded SSHDESK archive is empty"
    }

    $InstallRoot = Join-Path $env:ProgramData "SSHDESK"
    Write-Step "installing the application..."
    & (Join-Path $ProjectDirectory.FullName "scripts\install-windows.ps1") `
        -SourceDirectory $ProjectDirectory.FullName `
        -InstallRootOverride $InstallRoot

    $Account = $env:USERNAME
    if ($Account -notmatch "^[A-Za-z0-9_.-]+$") {
        throw "the Windows account name cannot be represented safely in sshd_config"
    }
    $SshDirectory = Join-Path $env:ProgramData "ssh"
    $SshConfig = Join-Path $SshDirectory "sshd_config"
    $Sshd = Join-Path $env:SystemRoot "System32\OpenSSH\sshd.exe"
    if (-not (Test-Path $SshConfig) -or -not (Test-Path $Sshd)) {
        throw "Windows OpenSSH installed without its expected configuration files"
    }

    $ForcedCommand = (Join-Path $InstallRoot "bin\sshdesk-forced-command.exe").Replace("\", "/")
    $BeginMarker = "# BEGIN SSHDESK $Account"
    $EndMarker = "# END SSHDESK $Account"
    $OriginalConfig = [IO.File]::ReadAllText($SshConfig)
    $MarkerPattern = "(?ms)^" + [regex]::Escape($BeginMarker) + ".*?^" + `
        [regex]::Escape($EndMarker) + "\r?\n?"
    $BaseConfig = [regex]::Replace($OriginalConfig, $MarkerPattern, "").TrimEnd()
    $Block = @"
$BeginMarker
Match User $Account
    ForceCommand "$ForcedCommand"
    PermitTTY yes
    DisableForwarding yes
    X11Forwarding no
    AllowTcpForwarding no
    AllowAgentForwarding no
    PermitTunnel no
$EndMarker
"@
    $UpdatedConfig = $BaseConfig + "`r`n`r`n" + $Block.Trim() + "`r`n"
    $BackupConfig = "$SshConfig.before-sshdesk"
    Copy-Item $SshConfig $BackupConfig -Force
    [IO.File]::WriteAllText($SshConfig, $UpdatedConfig, [Text.UTF8Encoding]::new($false))
    & $Sshd -t -f $SshConfig
    if ($LASTEXITCODE -ne 0) {
        Copy-Item $BackupConfig $SshConfig -Force
        throw "OpenSSH rejected the SSHDESK configuration; it was rolled back"
    }

    Set-Service sshd -StartupType Automatic
    if (-not (Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name "OpenSSH-Server-In-TCP" `
            -DisplayName "OpenSSH SSH Server (sshd)" -Enabled True `
            -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
    }
    if ((Get-Service sshd).Status -eq "Running") {
        Restart-Service sshd
    } else {
        Start-Service sshd
    }
    Write-Step "installed and started OpenSSH. Connect with: ssh $Account@<server-address>"
    Write-Warning "Windows OpenSSH normally runs in Session 0. Desktop capture from a forced command is experimental and must reach the logged-in interactive desktop."

    Write-Step "installation complete."
} finally {
    Remove-Item -LiteralPath $TemporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
