[CmdletBinding()]
param(
    [Parameter()]
    [string]$InstallerUrl = "https://blitz.gg/download/win",

    [Parameter(Mandatory)]
    [string]$OutputZip,

    [Parameter()]
    [string]$BaselineZip,

    [Parameter()]
    [string]$DiagnosticsDirectory,

    [Parameter()]
    [string]$SevenZipPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$ExpectedPublisher = "Swift Media Entertainment, Inc."
$TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("blitz-portable-" + [guid]::NewGuid().ToString("N"))

if ([string]::IsNullOrWhiteSpace($BaselineZip) -and (Test-Path -LiteralPath $OutputZip)) {
    $BaselineZip = $OutputZip
}

if ([string]::IsNullOrWhiteSpace($DiagnosticsDirectory)) {
    $DiagnosticsDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("blitz-portable-diagnostics-" + [guid]::NewGuid().ToString("N"))
}

New-Item -ItemType Directory -Path $TempRoot -Force | Out-Null
New-Item -ItemType Directory -Path $DiagnosticsDirectory -Force | Out-Null

$ResultPath = Join-Path $DiagnosticsDirectory "result.json"
$FailurePath = Join-Path $DiagnosticsDirectory "failure.txt"

function Get-FullPath {
    param([Parameter(Mandatory)][string]$Path)

    return [System.IO.Path]::GetFullPath($Path)
}

function Get-RelativePath {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Path
    )

    $rootPath = (Get-FullPath $Root).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $relativePath = [System.IO.Path]::GetRelativePath($rootPath, (Get-FullPath $Path))
    return $relativePath.Replace([System.IO.Path]::DirectorySeparatorChar, "/").Replace([System.IO.Path]::AltDirectorySeparatorChar, "/")
}

function Get-FileManifest {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ManifestPath,
        [Parameter()][switch]$IncludeUninstaller
    )

    $rootPath = Get-FullPath $Root
    if (!(Test-Path -LiteralPath $rootPath -PathType Container)) {
        throw "Manifest root does not exist: $rootPath"
    }

    $files = @(Get-ChildItem -LiteralPath $rootPath -File -Recurse -Force |
        Where-Object { $IncludeUninstaller -or $_.Name -ine "Uninstall Blitz.exe" } |
        Sort-Object { Get-RelativePath -Root $rootPath -Path $_.FullName })

    if ($files.Count -eq 0) {
        throw "No payload files were found under $rootPath"
    }

    $lines = @(
        foreach ($file in $files) {
            $relativePath = Get-RelativePath -Root $rootPath -Path $file.FullName
            $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToUpperInvariant()
            "$relativePath|$($file.Length)|$hash"
        }
    )

    Set-Content -LiteralPath $ManifestPath -Value $lines -Encoding utf8NoBOM
    return $lines
}

function Get-SignatureInfo {
    param([Parameter(Mandatory)][string]$Path)

    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    $certificate = $signature.SignerCertificate

    return [pscustomobject]@{
        Status = [string]$signature.Status
        Subject = if ($certificate) { [string]$certificate.Subject } else { "" }
        Issuer = if ($certificate) { [string]$certificate.Issuer } else { "" }
        NotAfter = if ($certificate) { $certificate.NotAfter.ToUniversalTime().ToString("o") } else { "" }
    }
}

function Assert-TrustedSignature {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Description
    )

    $signature = Get-SignatureInfo -Path $Path
    if ($signature.Status -ne "Valid") {
        throw "$Description has an invalid Authenticode signature: $($signature.Status)"
    }

    if ($signature.Subject -notlike "*$ExpectedPublisher*") {
        throw "$Description is signed by an unexpected publisher: $($signature.Subject)"
    }

    return $signature
}

function Download-Installer {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Destination
    )

    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $true
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [System.TimeSpan]::FromMinutes(10)
    $client.DefaultRequestHeaders.UserAgent.ParseAdd("Blitz-Portable-Updater/1.0")

    try {
        $response = $client.GetAsync(
            $Uri,
            [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
        ).GetAwaiter().GetResult()

        if (!$response.IsSuccessStatusCode) {
            throw "Installer download returned HTTP $([int]$response.StatusCode) $($response.ReasonPhrase)"
        }

        $finalUri = $response.RequestMessage.RequestUri.AbsoluteUri
        $statusCode = [int]$response.StatusCode
        $inputStream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $outputStream = [System.IO.File]::Open(
            $Destination,
            [System.IO.FileMode]::Create,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )

        try {
            $inputStream.CopyTo($outputStream)
        }
        finally {
            $outputStream.Dispose()
            $inputStream.Dispose()
            $response.Dispose()
        }

        return [pscustomobject]@{
            FinalUri = $finalUri
            StatusCode = $statusCode
        }
    }
    finally {
        $client.Dispose()
        $handler.Dispose()
    }
}

function Resolve-SevenZip {
    param([string]$RequestedPath)

    if (![string]::IsNullOrWhiteSpace($RequestedPath)) {
        $resolved = Get-FullPath $RequestedPath
        if (!(Test-Path -LiteralPath $resolved -PathType Leaf)) {
            throw "The requested 7-Zip executable does not exist: $resolved"
        }
        return $resolved
    }

    foreach ($commandName in @("7za.exe", "7z.exe")) {
        $command = Get-Command -Name $commandName -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($command) {
            return $command.Source
        }
    }

    throw "No 7-Zip executable was found. Pass -SevenZipPath or install 7z.exe."
}

function Get-SevenZipVersion {
    param([Parameter(Mandatory)][string]$Executable)

    $output = @(& $Executable 2>&1 | ForEach-Object { $_.ToString() })
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0 -and $output.Count -eq 0) {
        throw "Unable to execute 7-Zip at $Executable (exit code $exitCode)"
    }

    $versionLine = $output | Where-Object { $_ -match "7-Zip" } | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($versionLine)) {
        throw "The configured executable does not look like 7-Zip: $Executable"
    }

    return [string]$versionLine
}

function Expand-WithSevenZip {
    param(
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][string]$Archive,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$LogPath
    )

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $output = @(& $Executable x $Archive "-o$Destination" "-y" 2>&1 |
        ForEach-Object { $_.ToString() })
    $exitCode = $LASTEXITCODE
    Set-Content -LiteralPath $LogPath -Value $output -Encoding utf8NoBOM

    if ($exitCode -ne 0) {
        throw "7-Zip extraction failed for $Archive with exit code $exitCode. See $LogPath"
    }
}

function Test-LfsPointer {
    param([Parameter(Mandatory)][string]$Path)

    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    $prefixLength = [Math]::Min(200, (Get-Item -LiteralPath $Path).Length)
    if ($prefixLength -le 0) {
        return $false
    }

    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $buffer = New-Object byte[] $prefixLength
        [void]$stream.Read($buffer, 0, $buffer.Length)
        $prefix = [System.Text.Encoding]::UTF8.GetString($buffer)
        return $prefix.StartsWith("version https://git-lfs.github.com/spec/v1", [System.StringComparison]::Ordinal)
    }
    finally {
        $stream.Dispose()
    }
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory)]$Value,
        [Parameter(Mandatory)][string]$Path
    )

    $Value | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding utf8NoBOM
}

$result = [ordered]@{
    Success = $false
    Changed = $false
    InstallerUrl = $InstallerUrl
    FinalInstallerUrl = ""
    InstallerVersion = ""
    InstallerSize = 0
    InstallerSha256 = ""
    InstallerSignature = $null
    PayloadVersion = ""
    PayloadSignature = $null
    PayloadFileCount = 0
    PayloadBytes = 0
    SevenZipVersion = ""
    BaselinePresent = $false
    OutputZip = Get-FullPath $OutputZip
    CandidateManifest = Join-Path $DiagnosticsDirectory "candidate-manifest.txt"
    BaselineManifest = Join-Path $DiagnosticsDirectory "baseline-manifest.txt"
    PayloadManifest = Join-Path $DiagnosticsDirectory "payload-manifest.txt"
    DiagnosticsDirectory = Get-FullPath $DiagnosticsDirectory
    Error = ""
}

try {
    $outputPath = Get-FullPath $OutputZip
    $outputDirectory = Split-Path -Parent $outputPath
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null

    $sevenZip = Resolve-SevenZip -RequestedPath $SevenZipPath
    $result.SevenZipVersion = Get-SevenZipVersion -Executable $sevenZip
    Write-Host "Using $($result.SevenZipVersion) at $sevenZip"

    $installerPath = Join-Path $TempRoot "BlitzSetup.exe"
    Write-Host "Downloading Blitz installer from $InstallerUrl"
    $download = Download-Installer -Uri $InstallerUrl -Destination $installerPath
    $result.FinalInstallerUrl = $download.FinalUri

    $installerItem = Get-Item -LiteralPath $installerPath
    $result.InstallerSize = $installerItem.Length
    $result.InstallerVersion = [string]$installerItem.VersionInfo.ProductVersion
    $result.InstallerSha256 = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash.ToUpperInvariant()
    $result.InstallerSignature = Assert-TrustedSignature -Path $installerPath -Description "Downloaded Blitz installer"

    if ($result.InstallerSize -le 0) {
        throw "Downloaded Blitz installer is empty"
    }

    Write-Host "Installer version: $($result.InstallerVersion)"
    Write-Host "Installer size: $($result.InstallerSize) bytes"
    Write-Host "Installer SHA256: $($result.InstallerSha256)"
    Write-Host "Installer signature: $($result.InstallerSignature.Status) ($($result.InstallerSignature.Subject))"

    $payloadRoot = Join-Path $TempRoot "payload"
    Expand-WithSevenZip `
        -Executable $sevenZip `
        -Archive $installerPath `
        -Destination $payloadRoot `
        -LogPath (Join-Path $DiagnosticsDirectory "installer-extraction.log")

    $uninstallers = @(Get-ChildItem -LiteralPath $payloadRoot -File -Recurse -Force |
        Where-Object { $_.Name -ieq "Uninstall Blitz.exe" })
    foreach ($uninstaller in $uninstallers) {
        Remove-Item -LiteralPath $uninstaller.FullName -Force
    }

    $blitzExePath = Join-Path $payloadRoot "Blitz.exe"
    $asarPath = Join-Path $payloadRoot "resources\app.asar"
    if (!(Test-Path -LiteralPath $blitzExePath -PathType Leaf)) {
        throw "Extracted payload does not contain a root-level Blitz.exe"
    }
    if (!(Test-Path -LiteralPath $asarPath -PathType Leaf)) {
        throw "Extracted payload does not contain resources/app.asar"
    }
    if ((Get-Item -LiteralPath $asarPath).Length -le 0) {
        throw "Extracted resources/app.asar is empty"
    }

    $blitzSignature = Assert-TrustedSignature -Path $blitzExePath -Description "Extracted Blitz.exe"
    $result.PayloadVersion = [string](Get-Item -LiteralPath $blitzExePath).VersionInfo.ProductVersion
    $result.PayloadSignature = $blitzSignature

    $payloadManifest = @(Get-FileManifest -Root $payloadRoot -ManifestPath $result.PayloadManifest)
    $result.PayloadFileCount = $payloadManifest.Count
    $result.PayloadBytes = [int64]((Get-ChildItem -LiteralPath $payloadRoot -File -Recurse -Force |
        Where-Object { $_.Name -ine "Uninstall Blitz.exe" } |
        Measure-Object -Property Length -Sum).Sum)

    if ($result.PayloadBytes -le 0) {
        throw "Extracted payload is empty"
    }

    $candidateZip = Join-Path $TempRoot "blitzportable.candidate.zip"
    Write-Host "Creating candidate archive"
    Compress-Archive -Path (Join-Path $payloadRoot "*") -DestinationPath $candidateZip -CompressionLevel Optimal -Force

    if (!(Test-Path -LiteralPath $candidateZip -PathType Leaf) -or (Get-Item -LiteralPath $candidateZip).Length -le 0) {
        throw "Candidate portable ZIP was not created"
    }

    $candidateVerifyRoot = Join-Path $TempRoot "candidate-verify"
    Expand-WithSevenZip `
        -Executable $sevenZip `
        -Archive $candidateZip `
        -Destination $candidateVerifyRoot `
        -LogPath (Join-Path $DiagnosticsDirectory "candidate-verification.log")

    if (@(Get-ChildItem -LiteralPath $candidateVerifyRoot -File -Recurse -Force |
            Where-Object { $_.Name -ieq "Uninstall Blitz.exe" }).Count -gt 0) {
        throw "Candidate portable ZIP contains Uninstall Blitz.exe"
    }

    $candidateManifest = @(Get-FileManifest -Root $candidateVerifyRoot -ManifestPath $result.CandidateManifest)
    if (($candidateManifest -join "`n") -cne ($payloadManifest -join "`n")) {
        throw "Candidate ZIP manifest does not match the extracted payload"
    }

    $baselineManifest = @()
    $baselinePath = if ([string]::IsNullOrWhiteSpace($BaselineZip)) { "" } else { Get-FullPath $BaselineZip }
    if (![string]::IsNullOrWhiteSpace($baselinePath) -and (Test-Path -LiteralPath $baselinePath -PathType Leaf)) {
        $result.BaselinePresent = $true
        if (Test-LfsPointer -Path $baselinePath) {
            throw "Baseline ZIP is still a Git LFS pointer: $baselinePath"
        }

        $baselineRoot = Join-Path $TempRoot "baseline"
        Expand-WithSevenZip `
            -Executable $sevenZip `
            -Archive $baselinePath `
            -Destination $baselineRoot `
            -LogPath (Join-Path $DiagnosticsDirectory "baseline-extraction.log")
        $baselineManifest = @(Get-FileManifest -Root $baselineRoot -ManifestPath $result.BaselineManifest -IncludeUninstaller)
    }

    $result.Changed = !$result.BaselinePresent -or (($candidateManifest -join "`n") -cne ($baselineManifest -join "`n"))

    $outputEqualsBaseline = $false
    if ($result.BaselinePresent) {
        $outputEqualsBaseline = (Get-FullPath $baselinePath) -ieq $outputPath
    }

    if (!$outputEqualsBaseline -or $result.Changed) {
        $stagedOutput = Join-Path $outputDirectory ("." + [System.IO.Path]::GetFileName($outputPath) + "." + [guid]::NewGuid().ToString("N") + ".tmp")
        try {
            Copy-Item -LiteralPath $candidateZip -Destination $stagedOutput -Force
            if (Test-Path -LiteralPath $outputPath -PathType Leaf) {
                Move-Item -LiteralPath $stagedOutput -Destination $outputPath -Force
            }
            else {
                Move-Item -LiteralPath $stagedOutput -Destination $outputPath
            }
        }
        finally {
            if (Test-Path -LiteralPath $stagedOutput) {
                Remove-Item -LiteralPath $stagedOutput -Force
            }
        }
        Write-Host "Wrote candidate archive to $outputPath"
    }
    else {
        Write-Host "Payload content is unchanged; existing archive was left untouched"
    }

    $result.Success = $true
    Write-JsonFile -Value $result -Path $ResultPath
    Write-Output ($result | ConvertTo-Json -Depth 8 -Compress)
}
catch {
    $message = $_.Exception.Message
    $details = "$(Get-Date -Format o)`n$message`n$($_.ScriptStackTrace)"
    Set-Content -LiteralPath $FailurePath -Value $details -Encoding utf8NoBOM
    $result.Error = $message
    Write-JsonFile -Value $result -Path $ResultPath
    Write-Error $message
    exit 1
}
finally {
    if (Test-Path -LiteralPath $TempRoot) {
        Remove-Item -LiteralPath $TempRoot -Recurse -Force
    }
}
