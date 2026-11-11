<# Reads the manifest of a Jenkins WAR and returns its SHA-256 and declared versions. #>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Path)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

$text = ''
$zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
try {
    $entry = $zip.GetEntry('META-INF/MANIFEST.MF')
    if ($entry) {
        $sr = New-Object System.IO.StreamReader($entry.Open())
        $text = $sr.ReadToEnd()
        $sr.Dispose()
    }
} finally { $zip.Dispose() }

$map = @{}
$last = $null
foreach ($line in ($text -split "\r?\n")) {
    if ($line.Length -eq 0) { if ($map.Count -gt 0) { break } else { continue } }
    if ($line[0] -eq ' ' -and $last) { $map[$last] += $line.Substring(1); continue }
    $idx = $line.IndexOf(':')
    if ($idx -gt 0) { $last = $line.Substring(0, $idx); $map[$last] = $line.Substring($idx + 1).TrimStart(' ') }
}

$ver = ''
foreach ($k in 'Jenkins-Version', 'Implementation-Version', 'Build-Version') {
    if ($map[$k]) { $ver = $map[$k]; break }
}
[pscustomobject]@{
    path            = $Path
    size            = (Get-Item -LiteralPath $Path).Length
    sha256          = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    jenkins_version = $ver
    min_java        = $map['Minimum-Java-Version']
}
