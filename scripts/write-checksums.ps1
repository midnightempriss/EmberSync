param(
    [string]$ArtifactDirectory = (Join-Path $PSScriptRoot "..\installer"),
    [string]$OutputPath = (Join-Path $ArtifactDirectory "SHA256SUMS.txt")
)

$ErrorActionPreference = "Stop"
$artifactRoot = [System.IO.Path]::GetFullPath($ArtifactDirectory)
$checksumPath = [System.IO.Path]::GetFullPath($OutputPath)
$files = Get-ChildItem -LiteralPath $artifactRoot -Recurse -File | Where-Object {
    $_.FullName -ne $checksumPath -and $_.Name -notin @(".gitkeep", "README.md")
} | Sort-Object FullName

if ($files.Count -eq 0) {
    throw "No release artifacts were found under $artifactRoot."
}

$lines = foreach ($file in $files) {
    $relative = $file.FullName.Substring($artifactRoot.TrimEnd('\', '/').Length).TrimStart('\', '/').Replace('\', '/')
    $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $relative"
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllLines($checksumPath, [string[]]$lines, $utf8NoBom)
Write-Output $checksumPath
