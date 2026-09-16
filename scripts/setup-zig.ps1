[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$ToolchainDirectory)
$ErrorActionPreference = 'Stop'
$Existing = Get-Command zig -ErrorAction SilentlyContinue
if ($Existing -and (& $Existing.Source version) -eq '0.15.2') {
    Write-Output $Existing.Source
    return
}
$Architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
if ($Architecture -eq 'Arm64') {
    $Target = 'aarch64-windows'
    $Checksum = 'b926465f8872bf983422257cd9ec248bb2b270996fbe8d57872cca13b56fc370'
} elseif ($Architecture -eq 'X64') {
    $Target = 'x86_64-windows'
    $Checksum = '3a0ed1e8799a2f8ce2a6e6290a9ff22e6906f8227865911fb7ddedc3cc14cb0c'
} else { throw 'Zig bootstrap supports Windows x64 and ARM64' }
New-Item -ItemType Directory -Force $ToolchainDirectory | Out-Null
$Name = "zig-$Target-0.15.2"
$Archive = Join-Path $ToolchainDirectory "$Name.zip"
$Executable = Join-Path $ToolchainDirectory "$Name\zig.exe"
if (-not (Test-Path $Executable)) {
    Invoke-WebRequest "https://ziglang.org/download/0.15.2/$Name.zip" -OutFile $Archive
    if ((Get-FileHash $Archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Checksum) {
        throw 'Zig archive checksum mismatch'
    }
    Expand-Archive $Archive -DestinationPath $ToolchainDirectory -Force
}
if ((& $Executable version) -ne '0.15.2') { throw 'Zig 0.15.2 is required' }
Write-Output (Resolve-Path $Executable).Path
