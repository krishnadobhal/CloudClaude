[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$BaseUrl,
    [Parameter(Mandatory = $true)][ValidatePattern('^claude-[A-Za-z0-9.-]+$')][string]$Model,
    [ValidateSet('Active', 'Revoked')][string]$Mode = 'Active',
    [switch]$LoopbackFixture,
    [ValidatePattern('^[a-z][a-z0-9-]*$')][string]$Account
)

$ErrorActionPreference = 'Stop'
if ($LoopbackFixture) {
    if ($BaseUrl -cne 'http://127.0.0.1:8317') { throw 'Use the local fixture origin.' }
} elseif ($BaseUrl -notmatch '^https://[a-zA-Z0-9.-]+\.ts\.net$') {
    throw 'Use a bare HTTPS .ts.net origin.'
}

Add-Type -AssemblyName System.Net.Http
$handler = [System.Net.Http.HttpClientHandler]::new()
$handler.AllowAutoRedirect = $false
$handler.UseProxy = $false
$client = [System.Net.Http.HttpClient]::new($handler)
$client.Timeout = [TimeSpan]::FromSeconds(180)

function Invoke-GatewayCheck {
    param([int]$Expected, [string]$Path, [string]$Bearer, [hashtable]$Payload)

    $proofId = [guid]::NewGuid().ToString('N')
    $method = [System.Net.Http.HttpMethod]::Get
    if ($Payload) { $method = [System.Net.Http.HttpMethod]::Post }
    $request = [System.Net.Http.HttpRequestMessage]::new($method, "$BaseUrl$Path")
    $response = $null
    try {
        $request.Headers.Add('anthropic-version', '2023-06-01')
        $request.Headers.Add('X-CloudClaude-Proof', $proofId)
        if ($Account) {
            $request.Headers.Add('X-CloudClaude-Account', $Account)
        }
        if ($Bearer) {
            $request.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $Bearer)
        }
        if ($Payload) {
            $json = ConvertTo-Json -InputObject $Payload -Depth 5 -Compress
            $request.Content = [System.Net.Http.StringContent]::new($json, [Text.Encoding]::UTF8, 'application/json')
        }
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        $status = [int]$response.StatusCode
        if ($status -ne $Expected) { throw "$Path returned $status, expected $Expected (proof $proofId)." }
        $trace = '-'
        if ($response.Headers.Contains('X-CPA-TRACE-ID')) {
            $candidate = @($response.Headers.GetValues('X-CPA-TRACE-ID'))[0]
            if ($candidate -cmatch '^\d{14}-[0-9a-f]{16}-[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$') {
                $trace = $candidate
            }
        }
        Write-Host "PASS $Path HTTP $status proof=$proofId trace=$trace"
        $mediaType = $response.Content.Headers.ContentType
        [pscustomobject]@{
            Body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            MediaType = $mediaType.MediaType
            Trace = $trace
        }
    } finally {
        if ($response) { $response.Dispose() }
        $request.Dispose()
    }
}

function Read-GatewayJson {
    param([string]$Body)
    try {
        ConvertFrom-Json -InputObject $Body -ErrorAction Stop
    } catch {
        throw 'Gateway returned invalid JSON.'
    }
}

try {
    $null = Invoke-GatewayCheck 200 '/healthz'
    $null = Invoke-GatewayCheck 401 '/v1/models'
    if ($LoopbackFixture) {
        $token = 'a' * 64
        if ($Mode -eq 'Revoked') { $token = 'b' * 64 }
    } else {
        $secret = Read-Host 'PC gateway token' -AsSecureString
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secret)
        try {
            $token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
        } finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
            $secret.Dispose()
        }
    }
    if ($token -cnotmatch '^[0-9a-f]{64}$') { throw 'Expected a 64-character lowercase hexadecimal token.' }
    if ($Mode -eq 'Revoked') {
        $null = Invoke-GatewayCheck 401 '/v1/models' $token
        return
    }
    $models = Invoke-GatewayCheck 200 '/v1/models' $token
    if ($Model -cnotin (Read-GatewayJson $models.Body).data.id) {
        throw 'Selected model is absent from /v1/models.'
    }
    foreach ($path in '/v0/management/config', '/v8/management/config', '/management.html') {
        $null = Invoke-GatewayCheck 404 $path $token
    }
    $messages = @(@{ role = 'user'; content = 'Reply with the word OK.' })
    $count = Invoke-GatewayCheck 200 '/v1/messages/count_tokens' $token @{ model = $Model; messages = $messages }
    if ((Read-GatewayJson $count.Body).input_tokens -le 0) { throw 'Invalid token count.' }

    $payload = @{ model = $Model; messages = $messages; max_tokens = 32 }
    $response = Invoke-GatewayCheck 200 '/v1/messages' $token $payload
    $message = Read-GatewayJson $response.Body
    if ($message.type -cne 'message' -or $message.model -cne $Model -or !$message.content -or $response.Trace -eq '-') {
        throw 'Invalid Messages response, model mismatch, or missing trace.'
    }
    $payload.stream = $true
    $stream = Invoke-GatewayCheck 200 '/v1/messages' $token $payload
    if ($stream.MediaType -ne 'text/event-stream' -or $stream.Trace -eq '-') { throw 'Invalid SSE response or missing trace.' }
    foreach ($event in 'message_start', 'content_block_delta', 'message_stop') {
        if ($stream.Body -cnotmatch "(?m)^event: $event\r?$") { throw "Missing SSE event $event." }
    }
    if ($stream.Body -cmatch '(?m)^event: error\r?$') { throw 'SSE reported an error.' }
    Write-Host 'PASS complete SSE stream.'
} finally {
    $token = $null
    $client.Dispose()
}
