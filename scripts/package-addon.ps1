param(
    [string]$OutputDirectory = (Join-Path $PSScriptRoot "..\release-staging")
)

$ErrorActionPreference = "Stop"
$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$tocPath = Join-Path $projectRoot "EmberSync.toc"
$versionLine = Get-Content -LiteralPath $tocPath | Where-Object { $_ -match '^## Version:\s*(.+)$' } | Select-Object -First 1
if (-not $versionLine -or $versionLine -notmatch '^## Version:\s*(.+)$') {
    throw "EmberSync.toc does not contain a version."
}

$version = $Matches[1].Trim()
if ($version -notmatch '^\d+\.\d+\.\d+([-.][0-9A-Za-z.-]+)?$') {
    throw "Invalid addon version: $version"
}

$outputRoot = [System.IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
$stagingRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("embersync-addon-" + [guid]::NewGuid().ToString("N"))
$addonRoot = Join-Path $stagingRoot "EmberSync"
$archivePath = Join-Path $outputRoot "EmberSync-$version-addon.zip"

try {
    New-Item -ItemType Directory -Force -Path $addonRoot | Out-Null
    foreach ($directory in @("Collectors", "Core", "Locales", "UI")) {
        Copy-Item -LiteralPath (Join-Path $projectRoot $directory) -Destination $addonRoot -Recurse
    }
    Copy-Item -LiteralPath $tocPath -Destination $addonRoot
    Copy-Item -LiteralPath (Join-Path $projectRoot "LICENSE") -Destination $addonRoot
    if (Test-Path -LiteralPath $archivePath) {
        Remove-Item -LiteralPath $archivePath -Force
    }
    # Compress-Archive records Windows path separators in entry names. Build
    # the archive explicitly so the addon ZIP extracts portably on macOS and
    # Linux as well as Windows.
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::Open(
        $archivePath,
        [System.IO.Compression.ZipArchiveMode]::Create
    )
    try {
        Get-ChildItem -LiteralPath $addonRoot -Recurse -File | ForEach-Object {
            $relativePath = $_.FullName.Substring($stagingRoot.Length).TrimStart([char[]]"\/")
            $entryName = $relativePath.Replace("\", "/")
            [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $archive,
                $_.FullName,
                $entryName,
                [System.IO.Compression.CompressionLevel]::Optimal
            ) | Out-Null
        }
    }
    finally {
        $archive.Dispose()
    }
    Write-Output $archivePath
}
finally {
    if (Test-Path -LiteralPath $stagingRoot) {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force
    }
}
