<#
 Reads the Jenkins startup definition - a .bat script or a WinSW service XML
 (jenkins.xml, as laid down by the official Jenkins MSI) - and reports which WAR
 and java.exe it launches. When the WAR file name carries no version
 (e.g. "jenkins.war") the version is read from the WAR's own manifest.
 Read-only: safe in plan-only mode.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,
    [ValidateSet('bat', 'winsw')][string]$Kind = 'bat',
    # Service logon account, used to expand %LocalAppData% etc. as the SERVICE sees them
    [string]$ServiceAccount = ''
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

$baseDir = Split-Path -Parent $Path
$text = [IO.File]::ReadAllText($Path)

# Profile folder of the service account (built-in accounts only; others: leave as is)
$svcProfile = switch -Regex ($ServiceAccount) {
    '^(LocalSystem|NT AUTHORITY\\SYSTEM|\.\\LocalSystem)$' { Join-Path $env:windir 'System32\config\systemprofile' }
    'LocalService$'   { Join-Path $env:windir 'ServiceProfiles\LocalService' }
    'NetworkService$' { Join-Path $env:windir 'ServiceProfiles\NetworkService' }
    default { '' }
}
function Expand-ServiceEnv([string]$p) {
    if ($svcProfile) {
        $p = $p -replace '(?i)%LocalAppData%', (Join-Path $svcProfile 'AppData\Local')
        $p = $p -replace '(?i)%AppData%', (Join-Path $svcProfile 'AppData\Roaming')
        $p = $p -replace '(?i)%UserProfile%', $svcProfile
    }
    return [Environment]::ExpandEnvironmentVariables($p)
}

function Resolve-JenkinsPath([string]$p) {
    $p = $p.Trim().Trim('"')
    $p = $p -replace '(?i)%BASE%', $baseDir           # WinSW variable
    $p = $p -replace '(?i)%~dp0\\?', ($baseDir + '\') # .bat: script directory
    $p = Expand-ServiceEnv $p
    if (-not [IO.Path]::IsPathRooted($p)) { $p = Join-Path $baseDir $p }
    return $p
}

function Get-WarManifestVersion([string]$war) {
    if (-not (Test-Path -LiteralPath $war)) { return '' }
    $zip = [System.IO.Compression.ZipFile]::OpenRead($war)
    try {
        $e = $zip.GetEntry('META-INF/MANIFEST.MF')
        if (-not $e) { return '' }
        $sr = New-Object System.IO.StreamReader($e.Open())
        $mf = $sr.ReadToEnd(); $sr.Dispose()
    } finally { $zip.Dispose() }
    foreach ($k in 'Jenkins-Version', 'Implementation-Version') {
        $m = [regex]::Match($mf, "(?m)^$k\s*:\s*(\S+)")
        if ($m.Success) { return $m.Groups[1].Value }
    }
    return ''
}

$javaExe = ''
$jenkinsHome = ''
if ($Kind -eq 'winsw') {
    [xml]$doc = $text
    $svc = $doc.service
    if (-not $svc) { throw "$Path is not a WinSW service definition (<service> root missing)." }
    $searchIn = [string]$svc.arguments
    if ($svc.executable) { $javaExe = Resolve-JenkinsPath ([string]$svc.executable) }
    $envHome = @($svc.env | Where-Object { $_.name -eq 'JENKINS_HOME' } | Select-Object -First 1)
    if ($envHome.Count -gt 0 -and $envHome[0]) { $jenkinsHome = Expand-ServiceEnv ([string]$envHome[0].value) }
} else {
    # Ignore REM / :: comment lines
    $searchIn = (($text -split "\r?\n") | Where-Object { $_ -notmatch '^\s*(?i:rem\b|::)' }) -join "`n"
}

# Every WAR referenced: quoted paths may contain spaces, unquoted may not.
$warRefs = @([regex]::Matches($searchIn, '(?i)"(?<p>[^"]*?\.war)"|(?<p>[^\s"=]+\.war)\b') |
    ForEach-Object { $_.Groups['p'].Value } | Select-Object -Unique)
$warPaths = @($warRefs | ForEach-Object { Resolve-JenkinsPath $_ } | Select-Object -Unique)

$nameVersions = @($warRefs | ForEach-Object {
        $m = [regex]::Match($_, '(?i)jenkins[-_](?<v>\d+(?:\.\d+)+)\.war')
        if ($m.Success) { $m.Groups['v'].Value }
    } | Select-Object -Unique)

$manifestVersion = ''
if ($warPaths.Count -gt 0) { $manifestVersion = Get-WarManifestVersion $warPaths[0] }

$Ansible.Result = @{
    kind             = $Kind
    war_refs         = $warRefs
    war_paths        = $warPaths
    war_versions     = $nameVersions
    manifest_version = $manifestVersion
    java_exe         = $javaExe
    jenkins_home_env = $jenkinsHome
}
