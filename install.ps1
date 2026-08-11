[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 5) {
    throw 'fiotransfer requires PowerShell 5 or newer on Windows.'
}

$source = Join-Path $PSScriptRoot 'fiotransfer.ps1'
if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
    throw 'fiotransfer.ps1 was not found next to install.ps1.'
}

$installDir = Join-Path $HOME '.local\share\fiotransfer'
$installFile = Join-Path $installDir 'fiotransfer.ps1'
$binDir = Join-Path $HOME '.local\bin'
$stateDir = Join-Path $HOME '.local\state\fiotransfer'
New-Item -ItemType Directory -Force -Path $installDir, $binDir, $stateDir | Out-Null
Copy-Item -LiteralPath $source -Destination $installFile -Force

$powershell = Join-Path $PSHOME 'powershell.exe'
if (-not (Test-Path -LiteralPath $powershell)) { $powershell = Join-Path $PSHOME 'pwsh.exe' }
foreach ($name in @('fiotransfer', 'fioget')) {
    $cmdText = "@echo off`r`n`"$powershell`" -NoProfile -ExecutionPolicy Bypass -File `"$installFile`" $name %*`r`n"
    [IO.File]::WriteAllText((Join-Path $binDir "$name.cmd"), $cmdText, [Text.ASCIIEncoding]::new())
}

[IO.File]::WriteAllText((Join-Path $stateDir 'bin-directory'), "$binDir`n")
Remove-Item -LiteralPath (Join-Path $stateDir 'installed-revision'), (Join-Path $stateDir 'installed-commit-message') -Force -ErrorAction SilentlyContinue
if (Get-Command git.exe -ErrorAction SilentlyContinue) {
    try {
        $revision = (& git.exe -C $PSScriptRoot rev-parse HEAD 2>$null).Trim()
        $dirty = & git.exe -C $PSScriptRoot diff --name-only HEAD -- fiotransfer.ps1 install.ps1
        if ($revision -match '^[0-9a-f]{40}$' -and -not $dirty) {
            [IO.File]::WriteAllText((Join-Path $stateDir 'installed-revision'), "$revision`n")
            $message = (& git.exe -C $PSScriptRoot log -1 --format=%s HEAD).Trim()
            [IO.File]::WriteAllText((Join-Path $stateDir 'installed-commit-message'), "$message`n")
        }
    } catch { }
}

$pathMarker = Join-Path $stateDir 'windows-path-added'
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$parts = @($userPath -split ';' | Where-Object { $_ })
if ($parts -notcontains $binDir) {
    [Environment]::SetEnvironmentVariable('Path', (($parts + $binDir) -join ';'), 'User')
    [IO.File]::WriteAllText($pathMarker, "$binDir`n")
}
if (($env:Path -split ';') -notcontains $binDir) { $env:Path += ";$binDir" }

Write-Host 'fiotransfer installed successfully for Windows.'
Write-Host "Commands were installed in $binDir. Open a new terminal before using them."
