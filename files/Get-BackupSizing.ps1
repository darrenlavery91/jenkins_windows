<# Estimates backup size (robocopy /L) and free space on the backup volume. #>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$JenkinsHome,
    [Parameter(Mandatory)][string]$BackupDir,
    [string[]]$ExcludeDirs = @()
)
$ErrorActionPreference = 'Continue'
$probe = Join-Path $env:TEMP 'jenkins_sizing_probe_nonexistent'
$rcArgs = @($JenkinsHome, $probe, '/L', '/E', '/BYTES', '/NFL', '/NDL', '/NJH', '/XJ', '/R:0', '/W:0')
if ($ExcludeDirs.Count -gt 0) { $rcArgs += '/XD'; $rcArgs += $ExcludeDirs }
$out = & robocopy @rcArgs 2>&1 | Out-String
$m = [regex]::Match($out, 'Bytes\s*:\s*(\d+)')
$size = if ($m.Success) { [int64]$m.Groups[1].Value } else { -1 }

$free = -1
try {
    $root = [IO.Path]::GetPathRoot($BackupDir)
    if ($root -and $root -notlike '\\*') { $free = [int64]([IO.DriveInfo]::new($root).AvailableFreeSpace) }
} catch { }

$Ansible.Result = @{ home_bytes = $size; free_bytes = $free }
