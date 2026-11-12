<#
 Verifies a JENKINS_HOME backup tree.
  - Compare mode (Source given): robocopy /L lists what would still be copied from
    Source to Backup with the same exclusions. Anything left = incomplete backup.
  - Always: the backup must contain config.xml and a plugins folder, and its file
    count / size are returned so they can go into manifest.json.
 Read-only.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Backup,
    [string]$Source = '',
    [string[]]$ExcludeDirs = @()
)
$ErrorActionPreference = 'Stop'

$problems = New-Object System.Collections.Generic.List[string]
if (-not (Test-Path -LiteralPath $Backup)) { $problems.Add("backup folder missing: $Backup") }
else {
    if (-not (Test-Path -LiteralPath (Join-Path $Backup 'config.xml'))) { $problems.Add('config.xml missing') }
    if (-not (Test-Path -LiteralPath (Join-Path $Backup 'plugins'))) { $problems.Add('plugins folder missing') }
}

$files = 0; $bytes = [int64]0
if (Test-Path -LiteralPath $Backup) {
    foreach ($f in (Get-ChildItem -LiteralPath $Backup -Recurse -File -Force -ErrorAction SilentlyContinue)) {
        $files++; $bytes += $f.Length
    }
}

$pending = -1
if ($Source) {
    $rcArgs = @($Source, $Backup, '/L', '/E', '/XJ', '/BYTES', '/NJH', '/NFL', '/NDL', '/NP', '/R:0', '/W:0')
    if ($ExcludeDirs.Count -gt 0) { $rcArgs += '/XD'; $rcArgs += $ExcludeDirs }
    $out = & robocopy @rcArgs 2>&1 | Out-String
    # "Files :  Total  Copied  Skipped  Mismatch  FAILED  Extras"
    $m = [regex]::Match($out, '(?m)^\s*Files\s*:\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)')
    if ($m.Success) {
        $pending = [int]$m.Groups[2].Value + [int]$m.Groups[4].Value + [int]$m.Groups[5].Value
        if ($pending -gt 0) { $problems.Add("$pending file(s) in the source are missing or different in the backup") }
    } else { $problems.Add('could not parse robocopy verification output') }
}

$Ansible.Result = @{
    ok       = ($problems.Count -eq 0)
    problems = @($problems)
    files    = $files
    bytes    = $bytes
    pending  = $pending
}
