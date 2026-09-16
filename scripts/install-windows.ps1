[CmdletBinding()]
param(
    [string]$SourceDirectory = "",
    [string]$InstallRootOverride = ""
)
$ErrorActionPreference = "Stop"
$ProjectDir = if ($SourceDirectory) { $SourceDirectory } else { Split-Path -Parent $PSScriptRoot }
$InstallRoot = if ($InstallRootOverride) { $InstallRootOverride } else { Join-Path $env:LOCALAPPDATA "SSHDESK" }
$BinDir = Join-Path $InstallRoot "bin"
New-Item -ItemType Directory -Force -Path $InstallRoot, $BinDir | Out-Null
$Zig = & (Join-Path $PSScriptRoot 'setup-zig.ps1') -ToolchainDirectory (Join-Path $InstallRoot 'toolchain')
Push-Location $ProjectDir
try {
    & $Zig build -Doptimize=ReleaseSafe --prefix $InstallRoot
    if ($LASTEXITCODE -ne 0) { throw "Native SSHDESK build failed" }
} finally { Pop-Location }
$UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
if (($UserPath -split ";") -notcontains $BinDir) {
    $NewPath = if ($UserPath) { "$UserPath;$BinDir" } else { $BinDir }
    [Environment]::SetEnvironmentVariable("Path", $NewPath, "User")
}
$env:Path = "$BinDir;$env:Path"
Write-Host "Installed native SSHDESK in $InstallRoot. PNG libraries are bundled."
Write-Host "Windows hosting must run in the logged-in interactive desktop session; Session 0 is unsupported."
