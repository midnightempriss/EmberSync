param(
    [Parameter(Mandatory = $true)]
    [string]$Tag,
    [string]$Repository = "midnightempriss/EmberSync"
)

$ErrorActionPreference = "Stop"
if ($Tag -notmatch '^v\d+\.\d+\.\d+([-.][0-9A-Za-z.-]+)?$') {
    throw "Tag must look like v0.1.0."
}
if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
    throw "Repository must be in owner/name form."
}

$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$installerRoot = [System.IO.Path]::GetFullPath((Join-Path $projectRoot "installer"))
if (-not $installerRoot.StartsWith($projectRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Installer path escaped the EmberSync project."
}

$headers = @{ Accept = "application/vnd.github+json"; "User-Agent" = "EmberSync-artifact-fetcher" }
$release = Invoke-RestMethod -Headers $headers -Uri "https://api.github.com/repos/$Repository/releases/tags/$Tag"
$stagingRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("embersync-release-" + [guid]::NewGuid().ToString("N"))

function Get-DestinationDirectory([string]$Name) {
    switch -Regex ($Name) {
        '\.(exe|msi)(\.sig)?$' { return Join-Path $installerRoot "windows" }
        '(\.dmg|\.app\.tar\.gz)(\.sig)?$' { return Join-Path $installerRoot "macos" }
        '\.(deb|rpm|AppImage)(\.sig)?$' { return Join-Path $installerRoot "linux" }
        '^latest\.json$' { return Join-Path $installerRoot "updater" }
        '\.sig$' { return Join-Path $installerRoot "updater" }
        'addon\.zip$' { return $installerRoot }
        '^SHA256SUMS\.txt$' { return $installerRoot }
        default { return $null }
    }
}

try {
    New-Item -ItemType Directory -Force -Path $stagingRoot | Out-Null
    $downloaded = @()
    foreach ($asset in $release.assets) {
        $name = [string]$asset.name
        if (-not (Get-DestinationDirectory $name)) { continue }
        $stagedPath = Join-Path $stagingRoot $name
        Invoke-WebRequest -Headers $headers -Uri $asset.browser_download_url -OutFile $stagedPath
        $downloaded += Get-Item -LiteralPath $stagedPath
    }

    $checksumFile = Join-Path $stagingRoot "SHA256SUMS.txt"
    if (-not (Test-Path -LiteralPath $checksumFile)) {
        throw "The release does not contain SHA256SUMS.txt."
    }
    foreach ($pattern in @("*.exe", "*.dmg", "*.deb", "*.rpm", "*.AppImage", "*.sig", "*-addon.zip", "latest.json")) {
        if (-not ($downloaded | Where-Object Name -Like $pattern)) {
            throw "The release is incomplete; no asset matches $pattern."
        }
    }
    $expected = @{}
    foreach ($line in Get-Content -LiteralPath $checksumFile) {
        if ($line -notmatch '^([0-9A-Fa-f]{64})\s{2}(.+)$') {
            throw "Malformed checksum line: $line"
        }
        $expected[$Matches[2].Replace('\', '/')] = $Matches[1].ToLowerInvariant()
    }

    foreach ($file in $downloaded | Where-Object Name -ne "SHA256SUMS.txt") {
        $assetName = $file.Name.Replace('\', '/')
        if (-not $expected.ContainsKey($assetName)) {
            throw "SHA256SUMS.txt does not cover $assetName."
        }
        $actual = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $expected[$assetName]) {
            throw "Checksum verification failed for $assetName."
        }
    }

    $destinationDirectories = @(
        $installerRoot,
        (Join-Path $installerRoot "windows"),
        (Join-Path $installerRoot "macos"),
        (Join-Path $installerRoot "linux"),
        (Join-Path $installerRoot "updater")
    )
    foreach ($directory in $destinationDirectories) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }

    $staleFiles = @(
        Get-ChildItem -LiteralPath $installerRoot -File | Where-Object Name -Like "EmberSync-*-addon.zip"
        Get-Item -LiteralPath (Join-Path $installerRoot "SHA256SUMS.txt") -ErrorAction SilentlyContinue
        Get-ChildItem -LiteralPath (Join-Path $installerRoot "windows") -File | Where-Object Name -ne ".gitkeep"
        Get-ChildItem -LiteralPath (Join-Path $installerRoot "macos") -File | Where-Object Name -ne ".gitkeep"
        Get-ChildItem -LiteralPath (Join-Path $installerRoot "linux") -File | Where-Object Name -ne ".gitkeep"
        Get-ChildItem -LiteralPath (Join-Path $installerRoot "updater") -File | Where-Object Name -ne ".gitkeep"
    ) | Where-Object { $_ }
    foreach ($file in $staleFiles) {
        $resolved = [System.IO.Path]::GetFullPath($file.FullName)
        if (-not $resolved.StartsWith($installerRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to replace an artifact outside the installer folder: $resolved"
        }
        Remove-Item -LiteralPath $resolved -Force
    }

    foreach ($file in $downloaded) {
        $destinationDirectory = Get-DestinationDirectory $file.Name
        if ($destinationDirectory) {
            Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $destinationDirectory $file.Name)
        }
    }
    Write-Output "Downloaded and verified $Tag release artifacts into $installerRoot"
}
finally {
    if (Test-Path -LiteralPath $stagingRoot) {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force
    }
}
