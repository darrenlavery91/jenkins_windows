<#
 Calls the Jenkins HTTP API with basic auth and, for POSTs, a CSRF crumb fetched
 in the same web session. API tokens do not need the crumb, passwords do; doing it
 always makes both work. Never throws on HTTP errors: returns status + content.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BaseUrl,
    [Parameter(Mandatory)][string]$Path,
    [ValidateSet('GET', 'POST')][string]$Method = 'GET',
    [string]$User = '',
    [string]$Token = '',
    [hashtable]$Form = @{},
    [bool]$ValidateCerts = $true,
    [int]$TimeoutSec = 60
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
if (-not $ValidateCerts) { [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true } }

$base = $BaseUrl.TrimEnd('/')
$headers = @{}
if ($User) {
    $headers['Authorization'] = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${User}:${Token}"))
}

# HttpWebRequest instead of Invoke-WebRequest: Windows PowerShell 5.1 drops the
# Authorization header when it follows a redirect (quietDown answers 302), and
# the session cookie must carry over from the crumb request.
function Invoke-Req([string]$Url, [string]$M, [hashtable]$Body, [hashtable]$H, $Cookies) {
    try {
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.Method = $M
        $req.AllowAutoRedirect = $false
        $req.CookieContainer = $Cookies
        $req.Timeout = $TimeoutSec * 1000
        $req.ReadWriteTimeout = $TimeoutSec * 1000
        foreach ($k in $H.Keys) { $req.Headers[$k] = $H[$k] }
        if ($M -eq 'POST') {
            $pairs = @(foreach ($k in $Body.Keys) { [Uri]::EscapeDataString($k) + '=' + [Uri]::EscapeDataString([string]$Body[$k]) })
            $bytes = [Text.Encoding]::UTF8.GetBytes(($pairs -join '&'))
            $req.ContentType = 'application/x-www-form-urlencoded'
            $req.ContentLength = $bytes.Length
            $s = $req.GetRequestStream(); $s.Write($bytes, 0, $bytes.Length); $s.Close()
        }
        $resp = $req.GetResponse()
    } catch [System.Net.WebException] {
        $resp = $_.Exception.Response
        if (-not $resp) { return @{ status = 0; content = $_.Exception.Message } }
    } catch {
        return @{ status = 0; content = $_.Exception.Message }
    }
    $txt = ''
    try { $sr = New-Object IO.StreamReader($resp.GetResponseStream()); $txt = $sr.ReadToEnd(); $sr.Dispose() } catch { }
    $code = [int]$resp.StatusCode
    $loc = [string]$resp.Headers['Location']
    $resp.Close()
    return @{ status = $code; content = $txt; location = $loc }
}

$session = New-Object System.Net.CookieContainer
$crumbUsed = $false
if ($Method -eq 'POST') {
    $c = Invoke-Req "$base/crumbIssuer/api/json" 'GET' $null $headers $session
    if ($c.status -eq 200) {
        try {
            $j = $c.content | ConvertFrom-Json
            $headers[$j.crumbRequestField] = $j.crumb
            $crumbUsed = $true
        } catch { }
    }
}
$body = $null
if ($Method -eq 'POST') { $body = $Form }
$res = Invoke-Req "$base$Path" $Method $body $headers $session
# quietDown / cancelQuietDown answer 302 (not followed) = success
# ...unless it bounces to the login page (not authenticated / not authorised)
$ok = ($res.status -ge 200 -and $res.status -lt 400) -and -not ([string]$res.location -match '/login')
$Ansible.Result = @{ status = $res.status; location = $res.location; content = $res.content; crumb_used = $crumbUsed; ok = $ok }
$Ansible.Changed = ($Method -eq 'POST')
