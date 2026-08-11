$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'fiotransfer.ps1')

function Assert([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('fiotransfer-ps-test-' + [guid]::NewGuid())
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
$env:FIOTRANSFER_STATE_HOME = Join-Path $testRoot 'state'
$env:FIOTRANSFER_PROVIDERS = 'temp'
$env:FIOTRANSFER_CHUNK_SIZE_BYTES = '256'
$script:objects = @{}
$script:objectNumber = 0

function Measure-Providers([string[]] $Providers) { return @{ temp = 1L } }
function Send-Upload([string] $Provider, [string] $Path) {
    $script:objectNumber++
    $stored = Join-Path $testRoot "object-$script:objectNumber"
    Copy-Item -LiteralPath $Path -Destination $stored
    $script:objects["$script:objectNumber"] = $stored
    return "t:$script:objectNumber"
}
function Receive-File([string] $Url, [string] $Path) {
    $key = ([Uri]$Url).AbsolutePath.Trim('/')
    Copy-Item -LiteralPath $script:objects[$key] -Destination $Path
    return $null
}

try {
    $providers = Show-ProviderReport providers | Out-String
    Assert ($providers -match 'Loaded providers \(1\)') 'Provider report failed'
    Assert ((Show-ProviderReport limits | Out-String) -match '4 GB') 'Provider limits failed'
    Assert ((Show-ProviderReport status | Out-String) -match 'responsive') 'Provider status failed'

    $source = Join-Path $testRoot 'source.bin'
    [IO.File]::WriteAllBytes($source, (0..255 + 0..255 + 0..127 | ForEach-Object { [byte]$_ }))
    $upload = Invoke-Upload $source | Out-String
    Assert ($script:objectNumber -gt 1) 'Multipart upload was not exercised'
    Assert ($upload -match 'Code: (t:\d+)') 'Upload did not return a code'
    $code = $Matches[1]

    $output = Join-Path $testRoot 'result.bin'
    Invoke-Download $code $output
    Assert ((Get-FileHash $source -Algorithm SHA256).Hash -eq (Get-FileHash $output -Algorithm SHA256).Hash) 'Downloaded bytes differ'
    Assert ((Get-Item $source).Length -eq (Get-Item $output).Length) 'Downloaded size differs'

    $invalid = $false
    try { Convert-LocatorToUrl 'https://example.com/nope' | Out-Null } catch { $invalid = $true }
    Assert $invalid 'Unsupported URL was accepted'
    Write-Output 'All PowerShell tests passed.'
} finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
