<#
    FCP Pods Dashboard - PowerShell backend
    -----------------------------------------------------------------
    A tiny HTTP server backed by System.Net.HttpListener that:
      - Serves the static UI from ./public
      - Bridges browser requests to local gcloud / kubectl commands
      - Persists user config to ./config.json
    No external modules required. Works on Windows PowerShell 5.1 and PowerShell 7+.
#>

param(
    [string] $BindAddress = "localhost",
    [int]    $Port        = 8765
)

$ErrorActionPreference = 'Stop'

$ScriptRoot    = $PSScriptRoot
$PublicDir     = Join-Path $ScriptRoot 'public'
$ConfigFile    = Join-Path $ScriptRoot 'config.json'
$InstallScript = Join-Path $ScriptRoot 'Install.cmd'

# ---------- utilities ----------

function ConvertFromJsonSafe {
    param([string] $Json)
    if ([string]::IsNullOrWhiteSpace($Json)) { return @{} }
    try {
        return ($Json | ConvertFrom-Json -AsHashtable -ErrorAction Stop)
    } catch {
        $obj = $Json | ConvertFrom-Json
        $h = @{}
        if ($obj) { $obj.PSObject.Properties | ForEach-Object { $h[$_.Name] = $_.Value } }
        return $h
    }
}

function Send-Json {
    param($Context, $Object, [int] $Status = 200)
    $json  = $Object | ConvertTo-Json -Depth 12 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $Context.Response.StatusCode      = $Status
    $Context.Response.ContentType     = 'application/json; charset=utf-8'
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.Close()
}

function Send-Static {
    param($Context, [string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        $Context.Response.StatusCode = 404
        $Context.Response.Close()
        return
    }
    $ext = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    $ctype = switch ($ext) {
        '.html' { 'text/html; charset=utf-8' }
        '.js'   { 'application/javascript; charset=utf-8' }
        '.css'  { 'text/css; charset=utf-8' }
        '.json' { 'application/json; charset=utf-8' }
        '.svg'  { 'image/svg+xml' }
        '.png'  { 'image/png' }
        '.ico'  { 'image/x-icon' }
        default { 'application/octet-stream' }
    }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $Context.Response.StatusCode      = 200
    $Context.Response.ContentType     = $ctype
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.OutputStream.Flush()
    $Context.Response.Close()
}

function Read-Body {
    param($Context)
    $reader = New-Object System.IO.StreamReader($Context.Request.InputStream, [System.Text.Encoding]::UTF8)
    $body = $reader.ReadToEnd()
    return (ConvertFromJsonSafe -Json $body)
}

function Test-Cli {
    param([string] $Cmd)
    return [bool] (Get-Command $Cmd -ErrorAction SilentlyContinue)
}

function Run-Cmd {
    param(
        [string]   $Exe,
        [string[]] $Arguments,
        [int]      $TimeoutSec = 300
    )
    $stdoutFile = [System.IO.Path]::GetTempFileName()
    $stderrFile = [System.IO.Path]::GetTempFileName()
    try {
        $spArgs = @{
            FilePath               = $Exe
            NoNewWindow            = $true
            PassThru               = $true
            RedirectStandardOutput = $stdoutFile
            RedirectStandardError  = $stderrFile
        }
        if ($Arguments -and $Arguments.Count -gt 0) { $spArgs['ArgumentList'] = $Arguments }
        $p = Start-Process @spArgs

        if (-not $p.WaitForExit($TimeoutSec * 1000)) {
            try { $p.Kill() } catch {}
            return @{ ok = $false; code = -1; stdout = ''; stderr = "Timeout after $TimeoutSec s" }
        }
        $out = Get-Content -LiteralPath $stdoutFile -Raw -ErrorAction SilentlyContinue
        $err = Get-Content -LiteralPath $stderrFile -Raw -ErrorAction SilentlyContinue
        return @{
            ok     = ($p.ExitCode -eq 0)
            code   = $p.ExitCode
            stdout = if ($null -eq $out) { '' } else { $out }
            stderr = if ($null -eq $err) { '' } else { $err }
        }
    } catch {
        return @{ ok = $false; code = -1; stdout = ''; stderr = $_.Exception.Message }
    } finally {
        Remove-Item -LiteralPath $stdoutFile, $stderrFile -ErrorAction SilentlyContinue
    }
}

function Format-Age {
    param([datetime] $Start)
    $now  = [datetime]::UtcNow
    $diff = $now - $Start.ToUniversalTime()
    if ($diff.TotalSeconds -lt 60) { return "{0}s" -f [int]$diff.TotalSeconds }
    if ($diff.TotalMinutes -lt 60) { return "{0}m" -f [int]$diff.TotalMinutes }
    if ($diff.TotalHours   -lt 24) { return "{0}h{1}m" -f [int]$diff.TotalHours, ($diff.Minutes) }
    return "{0}d" -f [int]$diff.TotalDays
}

# ---------- config ----------

function Load-Config {
    if (Test-Path -LiteralPath $ConfigFile) {
        try {
            $raw = Get-Content -LiteralPath $ConfigFile -Raw
            $parsed = ConvertFromJsonSafe -Json $raw
            if (-not $parsed) { $parsed = @{} }
            # Ensure all expected keys exist so Send-Json never sees missing fields.
            foreach ($k in @('project','cluster','region','namespace')) {
                if (-not $parsed.ContainsKey($k)) { $parsed[$k] = '' }
            }
            if (-not $parsed.ContainsKey('recent_namespaces') -or -not $parsed['recent_namespaces']) {
                $parsed['recent_namespaces'] = @()
            } else {
                $parsed['recent_namespaces'] = @($parsed['recent_namespaces'])
            }
            return $parsed
        } catch { }
    }
    return @{
        project = ''
        cluster = ''
        region  = ''
        namespace = ''
        recent_namespaces = @()
    }
}

function Save-Config {
    param($Cfg)
    $json = $Cfg | ConvertTo-Json -Depth 6
    Set-Content -LiteralPath $ConfigFile -Value $json -Encoding UTF8
}

# ---------- API handlers ----------

function Handle-Health {
    param($Context)
    $hasGcloud  = Test-Cli 'gcloud'
    $hasKubectl = Test-Cli 'kubectl'
    $gcloudVer = ''; $kubectlVer = ''
    if ($hasGcloud)  {
        $r = Run-Cmd 'gcloud' @('version') 10
        if ($r.ok) { $gcloudVer = (($r.stdout -split "`n") | Select-Object -First 1).Trim() }
    }
    if ($hasKubectl) {
        $r = Run-Cmd 'kubectl' @('version','--client=true','--output=json') 10
        if ($r.ok) {
            try {
                $j = $r.stdout | ConvertFrom-Json
                if ($j.clientVersion -and $j.clientVersion.gitVersion) { $kubectlVer = $j.clientVersion.gitVersion }
            } catch { }
        }
    }
    Send-Json $Context @{
        gcloud  = $hasGcloud
        kubectl = $hasKubectl
        gcloud_version  = $gcloudVer
        kubectl_version = $kubectlVer
    }
}

function Handle-AuthStatus {
    param($Context)
    if (-not (Test-Cli 'gcloud')) { Send-Json $Context @{ authenticated = $false; account = '' }; return }
    $r = Run-Cmd 'gcloud' @('auth','list','--filter=status:ACTIVE','--format=value(account)') 15
    $acct = ''
    if ($r.ok) { $acct = ($r.stdout -split "`r?`n" | Where-Object { $_.Trim() -ne '' } | Select-Object -First 1) }
    Send-Json $Context @{
        authenticated = [bool]$acct
        account       = if ($null -eq $acct) { '' } else { $acct.Trim() }
    }
}

function Handle-Login {
    param($Context)
    if (-not (Test-Cli 'gcloud')) {
        Send-Json $Context @{ ok = $false; error = 'gcloud not found on PATH'; needs_install = $true } 400
        return
    }
    $r = Run-Cmd 'gcloud' @('auth','login','--update-adc','--brief') 600
    $out = ($r.stdout + "`n" + $r.stderr).Trim()
    Send-Json $Context @{ ok = $r.ok; code = $r.code; output = $out }
}

function Handle-Connect {
    param($Context)
    if (-not (Test-Cli 'gcloud')) {
        Send-Json $Context @{ ok = $false; error = 'gcloud not found on PATH'; needs_install = $true } 400
        return
    }
    $body    = Read-Body $Context
    $project = [string]$body.project
    $cluster = [string]$body.cluster
    $region  = [string]$body.region
    if (-not $project -or -not $cluster -or -not $region) {
        Send-Json $Context @{ ok = $false; error = 'project, cluster, region required' } 400
        return
    }
    $a = Run-Cmd 'gcloud' @('config','set','project',$project) 30
    $b = Run-Cmd 'gcloud' @('container','clusters','get-credentials',$cluster,'--region',$region,'--project',$project) 120
    $out = "$ gcloud config set project $project`n" + $a.stdout + $a.stderr + "`n" +
           "$ gcloud container clusters get-credentials $cluster --region $region --project $project`n" + $b.stdout + $b.stderr
    $ok = $a.ok -and $b.ok

    # persist
    $cfg = Load-Config
    $cfg.project = $project
    $cfg.cluster = $cluster
    $cfg.region  = $region
    Save-Config $cfg

    Send-Json $Context @{ ok = $ok; output = $out.Trim() }
}

function Handle-Contexts {
    param($Context)
    if (-not (Test-Cli 'kubectl')) { Send-Json $Context @{ contexts = @() }; return }
    $cur = Run-Cmd 'kubectl' @('config','current-context') 10
    $current = if ($cur.ok) { $cur.stdout.Trim() } else { '' }
    $r = Run-Cmd 'kubectl' @('config','get-contexts','-o','name') 10
    $names = @()
    if ($r.ok) { $names = @($r.stdout -split "`r?`n" | Where-Object { $_.Trim() -ne '' }) }
    $list = @(foreach ($n in $names) { @{ name = $n.Trim(); current = ($n.Trim() -eq $current) } })
    Send-Json $Context @{ contexts = $list }
}

function Handle-ContextSwitch {
    param($Context)
    $body = Read-Body $Context
    $name = [string]$body.name
    if (-not $name) { Send-Json $Context @{ ok = $false; error = 'name required' } 400; return }
    $r = Run-Cmd 'kubectl' @('config','use-context',$name) 15
    Send-Json $Context @{ ok = $r.ok; output = ($r.stdout + $r.stderr).Trim() }
}

function Parse-Pods {
    param([string] $Json)
    $result = @()
    if ([string]::IsNullOrWhiteSpace($Json)) { return $result }
    try { $obj = $Json | ConvertFrom-Json } catch { return $result }
    if (-not $obj -or -not $obj.items) { return $result }
    foreach ($p in $obj.items) {
        $cstats = @($p.status.containerStatuses)
        $totalContainers = if ($p.spec -and $p.spec.containers) { @($p.spec.containers).Count } else { $cstats.Count }
        $readyCount = ($cstats | Where-Object { $_.ready -eq $true }).Count
        $restarts   = ($cstats | Measure-Object -Property restartCount -Sum).Sum
        if (-not $restarts) { $restarts = 0 }

        # status (mimic kubectl logic, simplified)
        $status = [string]$p.status.phase
        if ($p.metadata.deletionTimestamp) { $status = 'Terminating' }
        foreach ($cs in $cstats) {
            if ($cs.state -and $cs.state.waiting -and $cs.state.waiting.reason) { $status = $cs.state.waiting.reason; break }
            if ($cs.state -and $cs.state.terminated -and $cs.state.terminated.reason) { $status = $cs.state.terminated.reason; break }
        }
        # init containers can also set status
        if ($p.status.initContainerStatuses) {
            foreach ($ic in $p.status.initContainerStatuses) {
                if ($ic.state -and $ic.state.waiting -and $ic.state.waiting.reason -and $ic.state.waiting.reason -ne 'PodInitializing') {
                    $status = "Init:$($ic.state.waiting.reason)"; break
                }
            }
        }

        $age = ''
        try { $age = Format-Age ([datetime]::Parse([string]$p.metadata.creationTimestamp)) } catch { }

        $containerNames = @()
        if ($p.spec -and $p.spec.containers) { $containerNames = @($p.spec.containers | ForEach-Object { $_.name }) }

        $result += @{
            name       = [string]$p.metadata.name
            ready      = ("{0}/{1}" -f $readyCount, $totalContainers)
            status     = $status
            restarts   = [int]$restarts
            age        = $age
            node       = [string]$p.spec.nodeName
            ip         = [string]$p.status.podIP
            containers = $containerNames
        }
    }
    return $result
}

function Handle-Pods {
    param($Context, [string] $Namespace)
    if (-not (Test-Cli 'kubectl')) { Send-Json $Context @{ pods = @(); error = 'kubectl not found' } 400; return }
    if (-not $Namespace) { Send-Json $Context @{ pods = @(); error = 'namespace required' } 400; return }
    $r = Run-Cmd 'kubectl' @('get','pods','-n',$Namespace,'-o','json') 60
    if (-not $r.ok) {
        Send-Json $Context @{ pods = @(); error = ($r.stderr.Trim()) } 500
        return
    }
    Send-Json $Context @{ pods = Parse-Pods $r.stdout }
}

function Handle-Logs {
    param($Context, [hashtable] $Query)
    if (-not (Test-Cli 'kubectl')) { Send-Json $Context @{ logs = ''; error = 'kubectl not found' } 400; return }
    $pod = [string]$Query['pod']; $ns = [string]$Query['namespace']
    $tail = if ($Query['tail']) { [int]$Query['tail'] } else { 200 }
    $container = [string]$Query['container']
    if (-not $pod -or -not $ns) { Send-Json $Context @{ logs = ''; error = 'pod and namespace required' } 400; return }
    $a = @('logs', $pod, '-n', $ns, '--tail', "$tail")
    if ($container) { $a += @('-c', $container) }
    $r = Run-Cmd 'kubectl' $a 60
    Send-Json $Context @{ ok = $r.ok; logs = ($r.stdout + $r.stderr) }
}

function Handle-Describe {
    param($Context, [hashtable] $Query)
    if (-not (Test-Cli 'kubectl')) { Send-Json $Context @{ describe = ''; error = 'kubectl not found' } 400; return }
    $pod = [string]$Query['pod']; $ns = [string]$Query['namespace']
    if (-not $pod -or -not $ns) { Send-Json $Context @{ describe = ''; error = 'pod and namespace required' } 400; return }
    $r = Run-Cmd 'kubectl' @('describe','pod',$pod,'-n',$ns) 60
    Send-Json $Context @{ ok = $r.ok; describe = ($r.stdout + $r.stderr) }
}

function Handle-Install {
    param($Context)
    if (-not (Test-Path -LiteralPath $InstallScript)) {
        Send-Json $Context @{ ok = $false; error = "Install.cmd placeholder not found at $InstallScript" } 404
        return
    }
    # invoke the placeholder via cmd.exe so .cmd extension is respected
    $r = Run-Cmd $env:ComSpec @('/c', $InstallScript) 900
    Send-Json $Context @{ ok = $r.ok; output = ($r.stdout + $r.stderr).Trim() }
}

function Handle-ConfigGet { param($Context) Send-Json $Context (Load-Config) }
function Handle-ConfigSet {
    param($Context)
    $body = Read-Body $Context
    $cfg = Load-Config
    foreach ($k in @('project','cluster','region','namespace')) {
        if ($body.ContainsKey($k)) { $cfg[$k] = [string]$body[$k] }
    }
    if ($body.ContainsKey('recent_namespaces')) { $cfg['recent_namespaces'] = @($body['recent_namespaces']) }
    Save-Config $cfg
    Send-Json $Context @{ ok = $true }
}

# ---------- request dispatch ----------

function Parse-QueryString {
    param([string] $Query)
    $h = @{}
    if (-not $Query) { return $h }
    $q = $Query.TrimStart('?')
    foreach ($pair in $q -split '&') {
        if (-not $pair) { continue }
        $kv = $pair -split '=', 2
        $k = [System.Uri]::UnescapeDataString($kv[0])
        $v = if ($kv.Count -gt 1) { [System.Uri]::UnescapeDataString($kv[1]) } else { '' }
        $h[$k] = $v
    }
    return $h
}

function Handle-Request {
    param($Context)
    $req    = $Context.Request
    $path   = $req.Url.AbsolutePath
    $method = $req.HttpMethod
    $query  = Parse-QueryString $req.Url.Query

    Write-Host ("{0} {1} {2}" -f (Get-Date -Format HH:mm:ss), $method, $req.Url.PathAndQuery)

    # ---- static
    if ($method -eq 'GET' -and ($path -eq '/' -or $path -eq '')) {
        Send-Static $Context (Join-Path $PublicDir 'index.html'); return
    }
    if ($method -eq 'GET' -and -not $path.StartsWith('/api/')) {
        $rel = $path.TrimStart('/')
        if ($rel -match '\.\.') { $Context.Response.StatusCode = 400; $Context.Response.Close(); return }
        $file = Join-Path $PublicDir $rel
        Send-Static $Context $file; return
    }

    # ---- api
    switch ("$method $path") {
        'GET /api/health'      { Handle-Health $Context; return }
        'GET /api/auth/status' { Handle-AuthStatus $Context; return }
        'POST /api/login'      { Handle-Login $Context; return }
        'POST /api/connect'    { Handle-Connect $Context; return }
        'GET /api/contexts'    { Handle-Contexts $Context; return }
        'POST /api/context'    { Handle-ContextSwitch $Context; return }
        'GET /api/pods'        { Handle-Pods $Context $query['namespace']; return }
        'GET /api/logs'        { Handle-Logs $Context $query; return }
        'GET /api/describe'    { Handle-Describe $Context $query; return }
        'POST /api/install'    { Handle-Install $Context; return }
        'GET /api/config'      { Handle-ConfigGet $Context; return }
        'POST /api/config'     { Handle-ConfigSet $Context; return }
    }
    Send-Json $Context @{ error = "Not found: $method $path" } 404
}

# ---------- run ----------

$listener = New-Object System.Net.HttpListener
$prefix = "http://${BindAddress}:${Port}/"
$listener.Prefixes.Add($prefix)
try {
    $listener.Start()
} catch {
    Write-Host "ERROR: could not bind to $prefix" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host "If the port is in use, pass -Port <other> when launching server.ps1." -ForegroundColor Yellow
    exit 1
}

Write-Host ""
Write-Host "FCP Pods Dashboard listening on $prefix" -ForegroundColor Green
Write-Host "Press Ctrl+C to stop." -ForegroundColor DarkGray
Write-Host ""

try {
    while ($listener.IsListening) {
        $ctx = $null
        try { $ctx = $listener.GetContext() } catch { break }
        try {
            Handle-Request $ctx
        } catch {
            try {
                $err = @{ error = $_.Exception.Message } | ConvertTo-Json -Compress
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($err)
                $ctx.Response.StatusCode = 500
                $ctx.Response.ContentType = 'application/json; charset=utf-8'
                $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                $ctx.Response.Close()
            } catch { }
            Write-Host "request error: $($_.Exception.Message)" -ForegroundColor DarkYellow
        }
    }
} finally {
    try { $listener.Stop(); $listener.Close() } catch {}
}
