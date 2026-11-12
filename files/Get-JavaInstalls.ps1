<#
 Finds 64-bit JDK/JRE installs (Java 9+ layout) and reports version, major,
 vendor flavour (OpenJ9 or not).  Output: one object per install.
#>
[CmdletBinding()]
param(
    [string[]]$SearchPaths = @(),
    [string[]]$ExtraHomes = @()
)
$ErrorActionPreference = 'SilentlyContinue'

$candidates = New-Object 'System.Collections.Generic.Dictionary[string,bool]' ([System.StringComparer]::OrdinalIgnoreCase)

foreach ($root in $SearchPaths) {
    if ($root -and (Test-Path -LiteralPath $root)) {
        foreach ($dir in (Get-ChildItem -LiteralPath $root -Directory)) {
            $exe = Join-Path $dir.FullName 'bin\java.exe'
            if (Test-Path -LiteralPath $exe) { $candidates[$exe] = $false }
        }
    }
}
foreach ($h in $ExtraHomes) {
    if ($h) {
        $exe = Join-Path $h.TrimEnd('\') 'bin\java.exe'
        if (Test-Path -LiteralPath $exe) { $candidates[$exe] = $true }
    }
}
$machineHome = [Environment]::GetEnvironmentVariable('JAVA_HOME', 'Machine')
if ($machineHome) {
    $exe = Join-Path $machineHome 'bin\java.exe'
    if ((Test-Path -LiteralPath $exe) -and -not $candidates.ContainsKey($exe)) { $candidates[$exe] = $false }
}
$cmd = Get-Command java.exe -ErrorAction SilentlyContinue
if ($cmd -and -not $candidates.ContainsKey($cmd.Source)) { $candidates[$cmd.Source] = $false }

$seen = @{}
foreach ($exe in @($candidates.Keys)) {
    $javaHome = Split-Path -Parent (Split-Path -Parent $exe)
    if (-not (Test-Path -LiteralPath (Join-Path $javaHome 'lib\modules'))) { continue }   # skips shims / Java 8
    $key = $javaHome.ToLowerInvariant()
    if ($seen.ContainsKey($key)) {
        if ($candidates[$exe]) { $seen[$key].requested = $true }
        continue
    }

    # java -version writes to stderr. "& $exe -version 2>&1" returns nothing inside
    # win_powershell's runspace, so run the process with stderr redirected explicitly.
    $text = ''
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $exe
        $psi.Arguments = '-version'
        $psi.UseShellExecute = $false
        $psi.RedirectStandardError = $true
        $psi.RedirectStandardOutput = $true
        $psi.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        $stderr = $proc.StandardError.ReadToEndAsync()
        $stdout = $proc.StandardOutput.ReadToEnd()
        if (-not $proc.WaitForExit(30000)) { $proc.Kill() }
        $text = ($stderr.Result + "`n" + $stdout).Trim()
    } catch { continue }
    $raw  = @($text -split "\r?\n" | Where-Object { $_ })
    if ($text -notmatch 'version "(?<v>[^"]+)"') { continue }
    $ver   = $Matches['v']
    $parts = @([regex]::Matches($ver, '\d+') | ForEach-Object { [int64]$_.Value })
    if ($parts.Count -eq 0) { continue }

    $n = @([int64]0, [int64]0, [int64]0, [int64]0)
    for ($i = 0; $i -lt [Math]::Min(4, $parts.Count); $i++) { $n[$i] = $parts[$i] }
    $major = [int]$n[0]
    if ($ver -like '1.*') { $major = [int]$n[1] }
    $sortKey = [int64]($n[0] * 1000000000 + $n[1] * 1000000 + $n[2] * 1000 + $n[3])

    $obj = [pscustomobject]@{
        home      = $javaHome
        exe       = $exe
        version   = $ver
        major     = $major
        sort_key  = $sortKey
        is64      = [bool]($text -match '64-Bit')
        openj9    = [bool]($text -match 'OpenJ9')
        is_jdk    = [bool](Test-Path -LiteralPath (Join-Path $javaHome 'bin\javac.exe'))
        runtime   = $(if ($raw.Count -gt 1) { $raw[1] } else { '' })
        requested = [bool]$candidates[$exe]
    }
    $seen[$key] = $obj
}
$seen.Values | Sort-Object -Property sort_key
