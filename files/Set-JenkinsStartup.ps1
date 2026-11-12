<#
 Points the Jenkins startup definition at a new WAR and, optionally, a specific JDK.
 Kind = bat   (start script)
  - replaces every jenkins[-x.y.z].war token on non-comment lines
  - updates existing "set JAVA_HOME=" lines
  - maintains a managed JAVA_HOME/PATH block (removed and re-added => idempotent)
 Kind = winsw (service XML, e.g. jenkins.xml from the official MSI)
  - replaces the jenkins[-x.y.z].war token inside <arguments>
  - sets <executable> to <JavaHome>\bin\java.exe and updates an existing
    <env name="JAVA_HOME"> entry
  - text edits only, never inside <!-- comments --> (comments/formatting kept);
    result must still parse as XML
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ScriptPath,
    [Parameter(Mandatory)][string]$WarFileName,
    [string]$JavaHome = '',
    [string]$BackupCopy = '',
    [ValidateSet('bat', 'winsw')][string]$Kind = 'bat'
)
$ErrorActionPreference = 'Stop'
$begin = 'REM >>> ANSIBLE JENKINS JAVA (managed) >>>'
$end   = 'REM <<< ANSIBLE JENKINS JAVA <<<'

if (-not (Test-Path -LiteralPath $ScriptPath)) { throw "Startup script not found: $ScriptPath" }
$original = [IO.File]::ReadAllText($ScriptPath)
if ($BackupCopy) { Copy-Item -LiteralPath $ScriptPath -Destination $BackupCopy -Force }

$warRegex  = '(?i)jenkins(?:[-_]\d+(?:\.\d+)+)?\.war'

if ($Kind -eq 'winsw') {
    $diff = New-Object System.Collections.Generic.List[string]
    # Edit only OUTSIDE <!-- comments -->: a comment may mention <arguments> or
    # <executable> (ours does), and editing inside it breaks the XML.
    # [regex]::Split with a capture group puts the comments at odd indexes.
    function Edit-OutsideComments([string]$text, [scriptblock]$edit) {
        $parts = [regex]::Split($text, '(<!--.*?-->)', [Text.RegularExpressions.RegexOptions]::Singleline)
        for ($i = 0; $i -lt $parts.Count; $i += 2) { $parts[$i] = & $edit $parts[$i] }
        return (-join $parts)
    }
    $bare = [regex]::Replace($original, '(?s)<!--.*?-->', '')
    $argsMatch = [regex]::Match($bare, '(?is)<arguments>(.*?)</arguments>')
    $warLines = 0
    if ($argsMatch.Success) { $warLines = [regex]::Matches($argsMatch.Groups[1].Value, $warRegex).Count }
    if ($warLines -eq 0) { throw "No jenkins*.war reference found inside <arguments> of $ScriptPath - refusing to guess." }
    $result = Edit-OutsideComments $original {
        param($s)
        [regex]::Replace($s, '(?is)(<arguments>)(.*?)(</arguments>)', {
                param($m) $m.Groups[1].Value + [regex]::Replace($m.Groups[2].Value, $warRegex, $WarFileName) + $m.Groups[3].Value })
    }
    if ($JavaHome) {
        $javaExe = (Join-Path $JavaHome 'bin\java.exe')
        if ($bare -notmatch '(?is)<executable>.*?</executable>') { throw "No <executable> element in $ScriptPath." }
        $result = Edit-OutsideComments $result {
            param($s)
            $s = [regex]::Replace($s, '(?is)(<executable>)(.*?)(</executable>)', { param($m) $m.Groups[1].Value + $javaExe + $m.Groups[3].Value })
            [regex]::Replace($s, '(?i)(<env\s+name="JAVA_HOME"\s+value=")[^"]*(")', { param($m) $m.Groups[1].Value + $JavaHome + $m.Groups[2].Value })
        }
    }
    # Line-level diff for the report
    $a = $original -split "\r?\n"; $b = $result -split "\r?\n"
    for ($i = 0; $i -lt [Math]::Max($a.Count, $b.Count); $i++) {
        $x = if ($i -lt $a.Count) { $a[$i] } else { '' }
        $y = if ($i -lt $b.Count) { $b[$i] } else { '' }
        if ($x -ne $y) { $diff.Add("- $($x.Trim())"); $diff.Add("+ $($y.Trim())") }
    }
    try { $null = [xml]$result } catch { throw "Refusing to write $ScriptPath - the edited XML does not parse: $($_.Exception.Message)" }
    if ($result -ne $original) {
        [IO.File]::WriteAllText($ScriptPath, $result, (New-Object System.Text.UTF8Encoding($false)))
        $Ansible.Changed = $true
    } else { $Ansible.Changed = $false }
    [xml]$check = [IO.File]::ReadAllText($ScriptPath)
    if (-not ([string]$check.service.arguments).Contains($WarFileName)) { throw "Verification failed: $WarFileName not in <arguments> of $ScriptPath" }
    $Ansible.Result = @{ war_lines = $warLines; diff = @($diff) }
    return
}

$nl = "`r`n"
$lines = New-Object System.Collections.Generic.List[string]
$skip = $false
foreach ($l in ($original -split "\r?\n")) {
    if ($l.Trim() -eq $begin) { $skip = $true; continue }
    if ($l.Trim() -eq $end)   { $skip = $false; continue }
    if (-not $skip) { $lines.Add($l) }
}

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
