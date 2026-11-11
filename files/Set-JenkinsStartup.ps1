<#
 Points the Jenkins startup (.bat) script at a new WAR and, optionally, a specific JDK.
  - replaces every jenkins[-x.y.z].war token on non-comment lines
  - updates existing "set JAVA_HOME=" lines
  - maintains a managed JAVA_HOME/PATH block (removed and re-added => idempotent)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ScriptPath,
    [Parameter(Mandatory)][string]$WarFileName,
    [string]$JavaHome = '',
    [string]$BackupCopy = ''
)
$ErrorActionPreference = 'Stop'
$begin = 'REM >>> ANSIBLE JENKINS JAVA (managed) >>>'
$end   = 'REM <<< ANSIBLE JENKINS JAVA <<<'

if (-not (Test-Path -LiteralPath $ScriptPath)) { throw "Startup script not found: $ScriptPath" }
$original = [IO.File]::ReadAllText($ScriptPath)
if ($BackupCopy) { Copy-Item -LiteralPath $ScriptPath -Destination $BackupCopy -Force }

$nl = "`r`n"
$lines = New-Object System.Collections.Generic.List[string]
$skip = $false
foreach ($l in ($original -split "\r?\n")) {
    if ($l.Trim() -eq $begin) { $skip = $true; continue }
    if ($l.Trim() -eq $end)   { $skip = $false; continue }
    if (-not $skip) { $lines.Add($l) }
}

$warRegex  = '(?i)jenkins(?:[-_]\d+(?:\.\d+)+)?\.war'
$homeRegex = '(?i)^(\s*set\s+"?JAVA_HOME=)[^"\r\n]*("?)\s*$'
$javaRegex = '(?i)[A-Za-z]:\\[^"\r\n]*?\\bin\\java(?:w)?(?:\.exe)?'
$warLines = 0
$diff = New-Object System.Collections.Generic.List[string]

for ($i = 0; $i -lt $lines.Count; $i++) {
    $old = $lines[$i]
    if ($old -match '^\s*(?i:rem\b|::)') { continue }
    $new = $old
    if ($new -match $warRegex) { $new = [regex]::Replace($new, $warRegex, $WarFileName); $warLines++ }
    if ($JavaHome) {
        if ($new -match $homeRegex) { $new = [regex]::Replace($new, $homeRegex, { param($mm) $mm.Groups[1].Value + $JavaHome + $mm.Groups[2].Value }) }
        elseif ($new -match $javaRegex) { $new = [regex]::Replace($new, $javaRegex, { param($mm) $JavaHome + '\bin\java.exe' }) }
    }
    if ($new -ne $old) { $diff.Add("- $old"); $diff.Add("+ $new"); $lines[$i] = $new }
}
if ($warLines -eq 0) { throw "No jenkins*.war reference found in $ScriptPath - refusing to guess." }

if ($JavaHome) {
    $block = @($begin, "set `"JAVA_HOME=$JavaHome`"", 'set "PATH=%JAVA_HOME%\bin;%PATH%"', $end)
    $at = 0
    if ($lines.Count -gt 0 -and $lines[0] -match '^\s*@?echo\s+off') { $at = 1 }
    $lines.InsertRange($at, [string[]]$block)
    foreach ($b in $block) { $diff.Add("+ $b") }
}

$result = $lines -join $nl
if ($result -ne $original) {
    [IO.File]::WriteAllText($ScriptPath, $result, (New-Object System.Text.UTF8Encoding($false)))
    $Ansible.Changed = $true
} else { $Ansible.Changed = $false }

if (-not ([IO.File]::ReadAllText($ScriptPath)).Contains($WarFileName)) { throw "Verification failed: $WarFileName not present in $ScriptPath" }
$Ansible.Result = @{ war_lines = $warLines; diff = @($diff) }
