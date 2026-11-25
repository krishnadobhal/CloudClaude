param(
    [Parameter(Mandatory = $true)][ValidatePattern('^[a-z][a-z0-9-]*$')][string]$Account,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$ClaudeArgs
)

$ErrorActionPreference = 'Stop'
if ($env:CLOUDCLAUDE_URL -notmatch '^https://[a-zA-Z0-9.-]+\.ts\.net$') {
    throw 'Set CLOUDCLAUDE_URL to your private Tailscale HTTPS origin.'
}
$claude = Get-Command claude -ErrorAction Stop
$secret = Read-Host "This laptop's gateway token" -AsSecureString
$pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secret)
try {
    $token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
} finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    $secret.Dispose()
}
if ($token -cnotmatch '^[0-9a-f]{64}$') {
    throw 'Expected a 64-character lowercase hexadecimal gateway token.'
}

$settings = @{
    ANTHROPIC_BASE_URL = $env:CLOUDCLAUDE_URL
    ANTHROPIC_AUTH_TOKEN = $token
    ANTHROPIC_API_KEY = ''
    ANTHROPIC_CUSTOM_HEADERS = "X-CloudClaude-Account: $Account"
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = '1'
    CLAUDE_CONFIG_DIR = Join-Path $env:USERPROFILE ".claude_gateway_${Account}"
}
$previous = @{}
try {
    foreach ($name in $settings.Keys) {
        $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        [Environment]::SetEnvironmentVariable($name, $settings[$name], 'Process')
    }
    & $claude @ClaudeArgs
    $code = $LASTEXITCODE
} finally {
    foreach ($name in $previous.Keys) {
        [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process')
    }
}
exit $code
