[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('New', 'Verify')][string]$Action,
    [Parameter(Mandatory = $true)][string]$Path
)

$ErrorActionPreference = 'Stop'
$repo = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)

function Invoke-ProofGit {
    $output = & git -C $repo @args
    if ($LASTEXITCODE -ne 0) { throw 'Git command failed.' }
    return $output
}

$proofFile = Join-Path $repo '.git/cloudclaude-proof.json'
if ($Action -eq 'New') {
    if (Test-Path -LiteralPath $repo) { throw 'Choose a new path for the proof repository.' }
    New-Item -ItemType Directory -Path $repo | Out-Null
    Invoke-ProofGit -c 'init.templateDir=' init --quiet
    Invoke-ProofGit config --local core.autocrlf false
    Set-Content -LiteralPath (Join-Path $repo 'local-marker.txt') -Encoding Ascii -Value ([guid]::NewGuid().ToString('N'))
    Set-Content -LiteralPath (Join-Path $repo 'answer.txt') -Encoding Ascii -Value 'pending'
    Set-Content -LiteralPath (Join-Path $repo 'Test-Proof.ps1') -Encoding Ascii -Value @'
$ErrorActionPreference = 'Stop'
$marker = (Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'local-marker.txt')).Trim()
$answer = (Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'answer.txt')).Trim()
if ($marker -cnotmatch '^[0-9a-f]{32}$' -or $answer -cne "verified-$marker") {
    throw 'FAIL answer mismatch.'
}
Write-Output 'PASS local marker and edit.'
'@
    Invoke-ProofGit add -- local-marker.txt answer.txt Test-Proof.ps1
    Invoke-ProofGit -c 'core.hooksPath=.git/cloudclaude-no-hooks' -c 'user.name=CloudClaude Proof' `
        -c 'user.email=proof@localhost' -c 'commit.gpgSign=false' commit --quiet -m 'Initialize local proof'
    $record = @{
        baseline = (Invoke-ProofGit rev-parse HEAD)
        proofId = [guid]::NewGuid().ToString('N')
    }
    ConvertTo-Json -InputObject $record | Set-Content -LiteralPath $proofFile -Encoding Ascii
    Write-Output "Project folder: $repo"
    Write-Output "ANTHROPIC_CUSTOM_HEADERS value: X-CloudClaude-Proof: $($record.proofId)"
    Write-Output 'Prompt for your harness: Run hostname and report its output. Read local-marker.txt. Edit only answer.txt so it contains verified- followed by the marker on one line. Run powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File ./Test-Proof.ps1 from this folder. Report the test output. Leave the change unstaged and uncommitted.'
    return
}

$record = Get-Content -LiteralPath $proofFile -Raw | ConvertFrom-Json
if ($record.proofId -cnotmatch '^[0-9a-f]{32}$') { throw 'Invalid local proof ID.' }
if ((Invoke-ProofGit rev-parse HEAD) -cne $record.baseline) { throw 'Baseline commit changed.' }
$changes = @(Invoke-ProofGit status --porcelain=v1 --untracked-files=all)
if ($changes.Count -ne 1 -or $changes[0] -cne ' M answer.txt') {
    throw 'Expected answer.txt as the sole unstaged edit.'
}
& (Join-Path $repo 'Test-Proof.ps1')
Write-Output "Local hostname: $([Environment]::MachineName)"
Invoke-ProofGit diff --no-ext-diff -- answer.txt
Write-Output "PASS Git baseline $($record.baseline) and sole unstaged edit answer.txt."
Write-Output "Proof ID: $($record.proofId)"
