[CmdletBinding()]
param(
    [Parameter(Position = 0)] [string] $EntryPoint,
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)] [string[]] $Arguments
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ProviderInfo = [ordered]@{
    fileio    = @{ Limit = 2000000000L; Hourly = 4000000000L; Endpoint = 'https://file.io/' }
    temp      = @{ Limit = 4000000000L; Hourly = 0L; Endpoint = 'https://temp.sh/' }
    litterbox = @{ Limit = 1000000000L; Hourly = 0L; Endpoint = 'https://litterbox.catbox.moe/' }
    '0x0'     = @{ Limit = 536870912L; Hourly = 0L; Endpoint = 'https://0x0.st/' }
    uguu      = @{ Limit = 134217728L; Hourly = 0L; Endpoint = 'https://uguu.se/' }
}

function Get-DataRoot {
    if ($env:XDG_DATA_HOME) { return $env:XDG_DATA_HOME }
    return (Join-Path $HOME '.local\share')
}

function Get-StateRoot {
    if ($env:FIOTRANSFER_STATE_HOME) { return $env:FIOTRANSFER_STATE_HOME }
    if ($env:XDG_STATE_HOME) { return (Join-Path $env:XDG_STATE_HOME 'fiotransfer') }
    return (Join-Path $HOME '.local\state\fiotransfer')
}

function Get-Providers {
    $names = if ($env:FIOTRANSFER_PROVIDERS) {
        @($env:FIOTRANSFER_PROVIDERS -split ',' | ForEach-Object { $_.Trim() })
    } else { @('temp', 'litterbox', '0x0', 'uguu') }
    foreach ($name in $names) {
        if (-not $ProviderInfo.Contains($name)) { throw "Unknown provider: $name" }
    }
    return $names
}

function Format-Bytes([long] $Bytes) {
    if ($Bytes -ge 1000000000L) { return "$([long]($Bytes / 1000000000L)) GB" }
    if ($Bytes -ge 1048576L) { return "$([long]($Bytes / 1048576L)) MiB" }
    if ($Bytes -ge 1024L) { return "$([long]($Bytes / 1024L)) KiB" }
    return "$Bytes B"
}

function Get-RecentUsage([string] $Provider) {
    $usageFile = Join-Path (Get-StateRoot) 'usage'
    if (-not (Test-Path -LiteralPath $usageFile)) { return 0L }
    $cutoff = [long]([DateTimeOffset]::UtcNow - [DateTimeOffset]'1970-01-01').TotalSeconds - 3600
    [long]$total = 0
    foreach ($line in [IO.File]::ReadLines($usageFile)) {
        $fields = $line -split ' '
        if ($fields.Count -eq 3 -and [long]$fields[0] -ge $cutoff -and $fields[1] -eq $Provider) {
            $total += [long]$fields[2]
        }
    }
    return $total
}

function Add-Usage([string] $Provider, [long] $Bytes) {
    $state = Get-StateRoot
    [IO.Directory]::CreateDirectory($state) | Out-Null
    $now = [long]([DateTimeOffset]::UtcNow - [DateTimeOffset]'1970-01-01').TotalSeconds
    [IO.File]::AppendAllText((Join-Path $state 'usage'), "$now $Provider $Bytes`n")
}

function New-HttpClient {
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $true
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromHours(6)
    $client.DefaultRequestHeaders.UserAgent.ParseAdd('fiotransfer-powershell/1')
    return $client
}

function Get-HttpText([string] $Url) {
    $client = New-HttpClient
    try {
        $response = $client.GetAsync($Url).GetAwaiter().GetResult()
        $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) { throw "HTTP $([int]$response.StatusCode): $($response.ReasonPhrase)" }
        return $body
    } finally { $client.Dispose() }
}

function Measure-Providers([string[]] $Providers) {
    $latency = @{}
    foreach ($provider in $Providers) {
        $watch = [Diagnostics.Stopwatch]::StartNew()
        try {
            $client = New-HttpClient
            $client.Timeout = [TimeSpan]::FromSeconds(4)
            $response = $client.GetAsync($ProviderInfo[$provider].Endpoint,
                [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
            $latency[$provider] = [long]$watch.ElapsedMilliseconds
            $response.Dispose(); $client.Dispose()
        } catch { $latency[$provider] = 10000L }
    }
    return $latency
}

function Send-Upload([string] $Provider, [string] $Path) {
    $client = New-HttpClient
    $multipart = [Net.Http.MultipartFormDataContent]::new()
    $stream = [IO.File]::OpenRead($Path)
    try {
        $part = [Net.Http.StreamContent]::new($stream)
        switch ($Provider) {
            fileio { $field = 'file'; $url = 'https://file.io' }
            temp { $field = 'file'; $url = 'https://temp.sh/upload' }
            '0x0' { $field = 'file'; $url = 'https://0x0.st' }
            litterbox {
                $multipart.Add([Net.Http.StringContent]::new('fileupload'), 'reqtype')
                $multipart.Add([Net.Http.StringContent]::new('72h'), 'time')
                $field = 'fileToUpload'; $url = 'https://litterbox.catbox.moe/resources/internals/api.php'
            }
            uguu { $field = 'files[]'; $url = 'https://uguu.se/upload?output=text' }
        }
        $multipart.Add($part, $field, [IO.Path]::GetFileName($Path))
        $response = $client.PostAsync($url, $multipart).GetAwaiter().GetResult()
        $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult().Trim()
        if (-not $response.IsSuccessStatusCode) { throw "$Provider upload failed: $body" }
        switch ($Provider) {
            fileio {
                $json = $body | ConvertFrom-Json
                if (-not $json.key) { throw 'file.io returned an unexpected response' }
                return "f:$($json.key)"
            }
            temp {
                if ($body -notlike 'https://temp.sh/*') { throw 'temp.sh returned an unexpected response' }
                return 't:' + $body.Substring('https://temp.sh/'.Length)
            }
            '0x0' {
                if ($body -notlike 'https://0x0.st/*') { throw '0x0.st returned an unexpected response' }
                return 'z:' + $body.Substring('https://0x0.st/'.Length)
            }
            litterbox {
                if ($body -notlike 'https://files.catbox.moe/*') { throw 'Litterbox returned an unexpected response' }
                return 'l:' + $body.Substring('https://files.catbox.moe/'.Length)
            }
            uguu {
                $uri = [Uri]$body
                if ($uri.Scheme -ne 'https' -or $uri.Host -notmatch '(^|\.)uguu\.se$') { throw 'Uguu returned an unexpected response' }
                return 'u:' + $uri.Host + $uri.PathAndQuery
            }
        }
    } finally {
        $multipart.Dispose(); $stream.Dispose(); $client.Dispose()
    }
}

function Write-Part([string] $InputPath, [string] $OutputPath, [byte[]] $Header,
    [long] $Offset, [long] $Count) {
    $output = [IO.File]::Create($OutputPath)
    $input = [IO.File]::OpenRead($InputPath)
    try {
        $output.Write($Header, 0, $Header.Length)
        $input.Position = $Offset
        $buffer = New-Object byte[] 1048576
        [long]$remaining = $Count
        while ($remaining -gt 0) {
            $read = $input.Read($buffer, 0, [int][Math]::Min($buffer.Length, $remaining))
            if ($read -le 0) { throw 'Unexpected end of input file' }
            $output.Write($buffer, 0, $read)
            $remaining -= $read
        }
    } finally { $input.Dispose(); $output.Dispose() }
}

function Invoke-Upload([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Not a regular file: $Path" }
    $file = Get-Item -LiteralPath $Path
    [long]$size = $file.Length
    $digest = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $encodedName = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($file.Name))
    $providers = Get-Providers
    $latency = Measure-Providers $providers
    $failed = @{}
    [long]$offset = 0; $partNumber = 1; $locator = '-'
    $tempDir = Join-Path ([IO.Path]::GetTempPath()) ("fiotransfer-" + [guid]::NewGuid())
    [IO.Directory]::CreateDirectory($tempDir) | Out-Null
    try {
        Write-Host "Uploading $($file.Name) ($(Format-Bytes $size)) with automatic provider fallback."
        while ($offset -lt $size -or ($size -eq 0 -and $partNumber -eq 1)) {
            $headerText = "FIOTRANSFER-CHAIN-V3`n$locator`n$encodedName`n$size`n$digest`n`n"
            $header = [Text.Encoding]::UTF8.GetBytes($headerText)
            $best = $null; [long]$bestScore = [long]::MaxValue; [long]$bestLimit = 0
            foreach ($provider in $providers) {
                if ($failed[$provider]) { continue }
                [long]$available = $ProviderInfo[$provider].Limit
                if ($env:FIOTRANSFER_CHUNK_SIZE_BYTES -and [long]$env:FIOTRANSFER_CHUNK_SIZE_BYTES -lt $available) {
                    $available = [long]$env:FIOTRANSFER_CHUNK_SIZE_BYTES
                }
                [long]$hourly = $ProviderInfo[$provider].Hourly
                if ($hourly -gt 0) { $available = [Math]::Min($available, $hourly - (Get-RecentUsage $provider)) }
                if ($available -le $header.Length) { continue }
                [long]$capacity = $available - $header.Length
                [long]$remaining = $size - $offset
                [long]$parts = [Math]::Max(1, [Math]::Ceiling($remaining / [double]$capacity))
                [long]$score = $latency[$provider] * [Math]::Min($parts, 1000000)
                if ($score -lt $bestScore) { $best = $provider; $bestScore = $score; $bestLimit = $available }
            }
            if (-not $best) { throw 'No provider can accept the remaining data' }
            [long]$payload = [Math]::Min($size - $offset, $bestLimit - $header.Length)
            $partPath = Join-Path $tempDir 'part'
            Write-Part $file.FullName $partPath $header $offset $payload
            Write-Host "Uploading part $partNumber through $best ($(Format-Bytes ($header.Length + $payload)))."
            try {
                $locator = Send-Upload $best $partPath
                Add-Usage $best ($header.Length + $payload)
                Write-Host "Part $partNumber uploaded through $best."
                $offset += $payload; $partNumber++
            } catch {
                Write-Warning $_.Exception.Message
                $failed[$best] = $true
            }
        }
        $partNumber--
        if ($locator -like 'f:*') { $locator = $locator.Substring(2) }
        Write-Host "Upload complete ($partNumber part(s))."
        Write-Output "Code: $locator"
        Write-Output "Download with: fioget $locator"
    } finally { if (Test-Path $tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force } }
}

function Convert-LocatorToUrl([string] $Locator) {
    $locator = ($Locator -split '[?#]')[0]
    if ($locator -match '^f:([A-Za-z0-9_-]+)$') { return "https://file.io/$($Matches[1])" }
    if ($locator -match '^t:(\S+)$') { return "https://temp.sh/$($Matches[1])" }
    if ($locator -match '^z:(\S+)$') { return "https://0x0.st/$($Matches[1])" }
    if ($locator -match '^l:(\S+)$') { return "https://files.catbox.moe/$($Matches[1])" }
    if ($locator -match '^u:((?:[A-Za-z0-9-]+\.)?uguu\.se/\S+)$') { return "https://$($Matches[1])" }
    if ($locator -match '^https://(www\.)?file\.io/' -or $locator -match '^https://(www\.)?temp\.sh/' -or
        $locator -match '^https://0x0\.st/' -or $locator -match '^https://files\.catbox\.moe/' -or
        $locator -match '^https://([A-Za-z0-9-]+\.)?uguu\.se/') { return $locator }
    $locator = $locator -replace '^(www\.)?file\.io/', '' -replace '^/', ''
    if ($locator -match '^[A-Za-z0-9_-]+$') { return "https://file.io/$locator" }
    throw "Invalid code or URL: $Locator"
}

function Receive-File([string] $Url, [string] $Path) {
    $client = New-HttpClient
    try {
        $method = if ($Url -like 'https://temp.sh/*' -or $Url -like 'https://www.temp.sh/*') { [Net.Http.HttpMethod]::Post } else { [Net.Http.HttpMethod]::Get }
        $request = [Net.Http.HttpRequestMessage]::new($method, $Url)
        $response = $client.SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) { throw "Download failed: $([int]$response.StatusCode) $($response.ReasonPhrase)" }
        $input = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $output = [IO.File]::Create($Path)
        try { $input.CopyTo($output) } finally { $input.Dispose(); $output.Dispose() }
        $name = $response.Content.Headers.ContentDisposition.FileName
        if ($name) { return $name.Trim('"') }
        return $null
    } finally { $client.Dispose() }
}

function Read-ChainHeader([string] $Path) {
    $stream = [IO.File]::OpenRead($Path)
    try {
        $lines = New-Object 'System.Collections.Generic.List[string]'
        $bytes = New-Object 'System.Collections.Generic.List[byte]'
        while ($lines.Count -lt 6 -and $stream.Position -lt $stream.Length -and $stream.Position -lt 16384) {
            $b = $stream.ReadByte()
            if ($b -eq 10) { $lines.Add([Text.Encoding]::UTF8.GetString($bytes.ToArray()).TrimEnd("`r")); $bytes.Clear() }
            else { $bytes.Add([byte]$b) }
        }
        if ($lines.Count -lt 1 -or $lines[0] -notmatch '^FIOTRANSFER-CHAIN-V[123]$') { return $null }
        $needed = if ($lines[0] -eq 'FIOTRANSFER-CHAIN-V3') { 6 } else { 4 }
        if ($lines.Count -lt $needed -or $lines[$needed - 1] -ne '') { throw 'Invalid multipart header' }
        return @{ Magic=$lines[0]; Previous=$lines[1]; Name=$lines[2]; Size=if($needed -eq 6){$lines[3]}else{$null}; Digest=if($needed -eq 6){$lines[4]}else{$null}; HeaderSize=$stream.Position }
    } finally { $stream.Dispose() }
}

function Copy-AfterHeader([string] $Source, [string] $Destination, [long] $Offset) {
    $input=[IO.File]::OpenRead($Source); $output=[IO.File]::Create($Destination)
    try { $input.Position=$Offset; $input.CopyTo($output) } finally { $input.Dispose(); $output.Dispose() }
}

function Invoke-Download([string] $Code, [string] $RequestedOutput) {
    $tempDir = Join-Path ([IO.Path]::GetTempPath()) ("fioget-" + [guid]::NewGuid())
    [IO.Directory]::CreateDirectory($tempDir) | Out-Null
    $parts = New-Object 'System.Collections.Generic.List[string]'; $seen=@{}; $locator=$Code
    $encodedName=$null; $expectedSize=$null; $expectedDigest=$null; $remoteName=$null
    try {
        while ($true) {
            if ($seen[$locator]) { throw 'Invalid multipart chain (repeated locator)' }; $seen[$locator]=$true
            $url=Convert-LocatorToUrl $locator; $node=Join-Path $tempDir 'node'
            $remoteName=Receive-File $url $node
            $header=Read-ChainHeader $node
            if (-not $header) { $parts.Add($node); break }
            $encodedName=$header.Name
            if ($header.Magic -eq 'FIOTRANSFER-CHAIN-V3') {
                if ($header.Size -notmatch '^\d+$' -or $header.Digest -notmatch '^[0-9a-f]{64}$') { throw 'Invalid validation metadata' }
                if ($expectedSize -ne $null -and ($expectedSize -ne [long]$header.Size -or $expectedDigest -ne $header.Digest)) { throw 'Inconsistent validation metadata' }
                $expectedSize=[long]$header.Size; $expectedDigest=$header.Digest
            }
            $part=Join-Path $tempDir ("part-"+$parts.Count); Copy-AfterHeader $node $part $header.HeaderSize; $parts.Add($part)
            if ($header.Magic -eq 'FIOTRANSFER-CHAIN-V3' -and $header.Previous -eq '-') { break }
            $locator = if ($header.Magic -eq 'FIOTRANSFER-CHAIN-V1') { 'f:'+$header.Previous } else { $header.Previous }
        }
        if ($RequestedOutput) { $output=$RequestedOutput }
        elseif ($encodedName) { $output=[IO.Path]::GetFileName([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encodedName))) }
        elseif ($remoteName) { $output=[IO.Path]::GetFileName($remoteName) }
        else { $output=([Uri](Convert-LocatorToUrl $Code)).Segments[-1].TrimEnd('/'); if(-not $output){$output='download'} }
        if (Test-Path -LiteralPath $output -PathType Container) { throw "Output path is a directory: $output" }
        $assembled=Join-Path $tempDir 'assembled'; $target=[IO.File]::Create($assembled)
        try { for($i=$parts.Count-1;$i-ge 0;$i--){$input=[IO.File]::OpenRead($parts[$i]);try{$input.CopyTo($target)}finally{$input.Dispose()}} } finally {$target.Dispose()}
        if ($expectedSize -ne $null) {
            if ((Get-Item $assembled).Length -ne $expectedSize) { throw 'Validation failed: downloaded size does not match' }
            if ((Get-FileHash $assembled -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expectedDigest) { throw 'Validation failed: downloaded checksum does not match' }
        }
        Move-Item -LiteralPath $assembled -Destination $output -Force
        if($expectedSize -ne $null){Write-Host "Downloaded, validated, and assembled $($parts.Count) part(s) into $output"}
        else{Write-Host "Downloaded and assembled $($parts.Count) part(s) into $output"}
    } finally { if(Test-Path $tempDir){Remove-Item -LiteralPath $tempDir -Recurse -Force} }
}

function Show-ProviderReport([string] $Report) {
    $providers=Get-Providers
    if($Report -eq 'providers'){ Write-Output "Loaded providers ($($providers.Count)):"; $providers|ForEach-Object{Write-Output "  $_"}; return }
    $latency=if($Report -in @('status','unresponsive')){Measure-Providers $providers}else{@{}}
    if($Report -eq 'limits'){Write-Output 'PROVIDER     OBJECT_LIMIT       HOURLY_LIMIT'}
    if($Report -eq 'usage'){Write-Output 'PROVIDER     LAST_HOUR         REMAINING'}
    if($Report -eq 'status'){Write-Output 'PROVIDER     HEALTH       LATENCY      OBJECT_LIMIT       HOURLY_USAGE'}
    foreach($p in $providers){
        $info=$ProviderInfo[$p];$used=Get-RecentUsage $p
        switch($Report){
            limits { Write-Output ("{0,-12} {1,-18} {2}" -f $p,(Format-Bytes $info.Limit),$(if($info.Hourly){Format-Bytes $info.Hourly}else{'not published'})) }
            usage { Write-Output ("{0,-12} {1,-18} {2}" -f $p,$(if($info.Hourly){Format-Bytes $used}else{'not tracked'}),$(if($info.Hourly){Format-Bytes ([Math]::Max(0,$info.Hourly-$used))}else{'unknown'})) }
            status { $health=if($latency[$p]-lt 10000){'responsive'}else{'unresponsive'};Write-Output ("{0,-12} {1,-12} {2,-12} {3,-18} {4}" -f $p,$health,$("$($latency[$p]) ms"),(Format-Bytes $info.Limit),$(if($info.Hourly){"$(Format-Bytes $used) / $(Format-Bytes $info.Hourly)"}else{'not tracked'})) }
            unresponsive { if($latency[$p]-ge 10000){Write-Output $p} }
        }
    }
}

function Show-Version {
    $state=Get-StateRoot;$revisionFile=Join-Path $state 'installed-revision';$messageFile=Join-Path $state 'installed-commit-message'
    Write-Output 'VERSION'
    if(Test-Path $revisionFile){$revision=(Get-Content -LiteralPath $revisionFile -Raw).Trim();Write-Output "  Revision: $($revision.Substring(0,[Math]::Min(12,$revision.Length))) (installer-managed)"}else{Write-Output '  Revision: unknown (installer-managed)'}
    if(Test-Path $messageFile){Write-Output "  Commit:   $((Get-Content -LiteralPath $messageFile -Raw).Trim())"}
}

function Invoke-Update {
    $state=Get-StateRoot;$installFile=Join-Path (Join-Path (Get-DataRoot) 'fiotransfer') 'fiotransfer.ps1'
    if(-not (Test-Path -LiteralPath $installFile)){throw 'This copy is not installer-managed; run install.ps1 first'}
    if([IO.Path]::GetFullPath($PSCommandPath) -ne [IO.Path]::GetFullPath($installFile)){throw 'This copy is not installer-managed; run the installed fiotransfer command'}
    [IO.Directory]::CreateDirectory($state)|Out-Null
    $revisionFile=Join-Path $state 'installed-revision';$messageFile=Join-Path $state 'installed-commit-message'
    $installed=if(Test-Path $revisionFile){(Get-Content $revisionFile -Raw).Trim()}else{$null}
    Write-Host 'Checking fiotransfer for updates...'
    $remote=(Get-HttpText 'https://api.github.com/repos/BogdanStamenovic/fiotransfer/commits/main')|ConvertFrom-Json
    $revision=[string]$remote.sha;$message=([string]$remote.commit.message -split "`n")[0]
    if($revision -notmatch '^[0-9a-f]{40}$'){throw 'GitHub returned an invalid revision'}
    Write-Host "Latest:   $($revision.Substring(0,12))  $message"
    if($installed -eq $revision){Write-Host 'fiotransfer is already up to date.';return}
    if($installed){
        if($installed -notmatch '^[0-9a-f]{40}$'){throw 'Invalid installed revision metadata'}
        $comparison=(Get-HttpText "https://api.github.com/repos/BogdanStamenovic/fiotransfer/compare/$installed...$revision")|ConvertFrom-Json
        if($comparison.status -ne 'ahead'){throw 'Refusing update because repository history is not a fast-forward'}
    }
    $temporary=Join-Path ([IO.Path]::GetTempPath()) ("fiotransfer-update-"+[guid]::NewGuid()+'.ps1')
    try{
        [IO.File]::WriteAllText($temporary,(Get-HttpText "https://raw.githubusercontent.com/BogdanStamenovic/fiotransfer/$revision/fiotransfer.ps1"),[Text.UTF8Encoding]::new($false))
        $tokens=$null;$errors=$null;[Management.Automation.Language.Parser]::ParseFile($temporary,[ref]$tokens,[ref]$errors)|Out-Null
        if($errors.Count){throw "Downloaded PowerShell failed syntax validation: $($errors[0].Message)"}
        $body=Get-Content $temporary -Raw
        if($body -notmatch 'function Invoke-Upload' -or $body -notmatch 'function Invoke-Download' -or $body -notmatch 'function Invoke-Update'){throw 'Downloaded file failed identity validation'}
        $backupDir=Join-Path $state 'backups';[IO.Directory]::CreateDirectory($backupDir)|Out-Null
        $stamp=[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ');Copy-Item $installFile (Join-Path $backupDir "fiotransfer-$stamp.ps1")
        Move-Item $temporary $installFile -Force
        [IO.File]::WriteAllText($revisionFile,"$revision`n");[IO.File]::WriteAllText($messageFile,"$message`n")
        Write-Host 'fiotransfer updated successfully. New commands use the update immediately.'
    }finally{if(Test-Path $temporary){Remove-Item $temporary -Force}}
}

function Invoke-Uninstall {
    $installDir=Join-Path (Get-DataRoot) 'fiotransfer';$binDir=Join-Path $HOME '.local\bin';$state=Get-StateRoot
    if((Read-Host "Remove fiotransfer from $installDir and $binDir? [y/N]") -notmatch '^(?i:y|yes)$'){Write-Host 'Uninstall cancelled.';return}
    Remove-Item -LiteralPath (Join-Path $binDir 'fiotransfer.cmd'),(Join-Path $binDir 'fioget.cmd') -Force -ErrorAction SilentlyContinue
    if(Test-Path (Join-Path $state 'windows-path-added')){
        $parts=@([Environment]::GetEnvironmentVariable('Path','User') -split ';' | Where-Object { $_ -and $_ -ne $binDir })
        [Environment]::SetEnvironmentVariable('Path',($parts -join ';'),'User')
    }
    Remove-Item -LiteralPath $installDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host 'fiotransfer has been uninstalled. Open a new terminal to finish.'
}

function Show-Usage { Write-Output "Usage: fiotransfer FILE`n       fiotransfer providers|limits|usage|unresponsive|status|update|uninstall`n       fioget CODE_OR_URL [OUTPUT_FILE]" }

if ($EntryPoint) {
    try {
        if($EntryPoint -eq 'fioget') { if($Arguments.Count -lt 1 -or $Arguments.Count -gt 2){Show-Usage;exit 2};Invoke-Download $Arguments[0] $(if($Arguments.Count -ge 2){$Arguments[1]}else{$null});exit }
        if($EntryPoint -ne 'fiotransfer'){Show-Usage;exit 2}
        if($Arguments.Count -lt 1){Show-Usage;exit 2}
        switch($Arguments[0]){
            {$_ -in @('help','-h','--help')} {Show-Usage}
            {$_ -in @('providers','loaded-providers')} {Show-ProviderReport providers}
            {$_ -in @('limits','usage-limits')} {Show-ProviderReport limits}
            'usage' {Show-ProviderReport usage}
            {$_ -in @('unresponsive','unresponsive-providers')} {Show-ProviderReport unresponsive}
            'status' {Show-Version;Write-Output '';Show-ProviderReport status}
            'uninstall' {Invoke-Uninstall}
            'update' {Invoke-Update}
            default {Invoke-Upload $Arguments[0]}
        }
    } catch { Write-Error $_.Exception.Message; exit 1 }
}
