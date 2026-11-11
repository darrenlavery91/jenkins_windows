<#
 Reads every plugin archive in <JENKINS_HOME>\plugins and returns name, version,
 minimum core, minimum Java, disabled/pinned state and hard-dependency problems.
 Works while Jenkins is stopped and needs no credentials.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$JenkinsHome)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

function ConvertFrom-Manifest([string]$Text) {
    $map = @{}
    $last = $null
    foreach ($line in ($Text -split "\r?\n")) {
        if ($line.Length -eq 0) { if ($map.Count -gt 0) { break } else { continue } }
        if ($line[0] -eq ' ' -and $last) { $map[$last] += $line.Substring(1); continue }
        $idx = $line.IndexOf(':')
        if ($idx -gt 0) {
            $last = $line.Substring(0, $idx)
            $map[$last] = $line.Substring($idx + 1).TrimStart(' ')
        }
    }
    return $map
}

$pluginDir = Join-Path $JenkinsHome 'plugins'
if (-not (Test-Path -LiteralPath $pluginDir)) { throw "Plugin directory not found: $pluginDir" }

$plugins = New-Object System.Collections.Generic.List[object]
foreach ($f in (Get-ChildItem -LiteralPath $pluginDir -File | Where-Object { $_.Extension -in '.jpi', '.hpi' })) {
    $text = $null
    $zip = [System.IO.Compression.ZipFile]::OpenRead($f.FullName)
    try {
        $entry = $zip.GetEntry('META-INF/MANIFEST.MF')
        if ($entry) {
            $sr = New-Object System.IO.StreamReader($entry.Open())
            $text = $sr.ReadToEnd()
            $sr.Dispose()
        }
    } finally { $zip.Dispose() }
    if (-not $text) { continue }

    $m = ConvertFrom-Manifest $text
    $name = $m['Short-Name']
    if (-not $name) { $name = [IO.Path]::GetFileNameWithoutExtension($f.Name) }
    $deps = New-Object System.Collections.Generic.List[object]
    if ($m['Plugin-Dependencies']) {
        foreach ($d in $m['Plugin-Dependencies'].Split(',')) {
            $d = $d.Trim()
            if (-not $d) { continue }
            $nv = $d.Split(';')[0].Split(':')
            $deps.Add([pscustomobject]@{ name = $nv[0]; optional = ($d -match 'resolution:=optional') })
        }
    }
    $plugins.Add([pscustomobject]@{
        name          = $name
        version       = $m['Plugin-Version']
        long_name     = $m['Long-Name']
        required_core = $m['Jenkins-Version']
        min_java      = $m['Minimum-Java-Version']
        disabled      = [bool](Test-Path -LiteralPath ($f.FullName + '.disabled'))
        pinned        = [bool](Test-Path -LiteralPath ($f.FullName + '.pinned'))
        file          = $f.Name
        deps          = $deps
    })
}

$byName = @{}
foreach ($p in $plugins) { $byName[$p.name] = $p }

foreach ($p in ($plugins | Sort-Object name)) {
    $missing = New-Object System.Collections.Generic.List[string]
    if (-not $p.disabled) {
        foreach ($d in $p.deps) {
            if ($d.optional) { continue }
            if (-not $byName.ContainsKey($d.name)) { $missing.Add("$($d.name) (not installed)") }
            elseif ($byName[$d.name].disabled)     { $missing.Add("$($d.name) (disabled)") }
        }
    }
    [pscustomobject]@{
        name          = $p.name
        version       = $p.version
        long_name     = $p.long_name
        required_core = $p.required_core
        min_java      = $p.min_java
        disabled      = $p.disabled
        pinned        = $p.pinned
        file          = $p.file
        missing_deps  = @($missing)
    }
}
