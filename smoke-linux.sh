#!/usr/bin/env bash
set +x
set -euo pipefail

base=${1:-http://127.0.0.1:8317}
model=${2:-}
mode=${3:-single}
account=${4:-}

fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }

[[ $base == http://127.0.0.1:8317 || $base =~ ^https://[a-zA-Z0-9.-]+\.ts\.net$ ]] ||
    fail 'Use http://127.0.0.1:8317 or a bare HTTPS .ts.net origin.'
[[ $model =~ ^claude-[a-zA-Z0-9.-]+$ ]] || fail 'Pass an exact Claude model ID as argument 2.'
[[ $mode == single || $mode == round-robin || $mode == revoked ]] ||
    fail 'Argument 3 must be single, round-robin, or revoked.'
[[ -z $account || $account =~ ^[a-z][a-z0-9-]*$ ]] ||
    fail 'Argument 4 must be a configured account name.'
for program in curl jq od tr awk grep; do
    command -v "$program" >/dev/null || fail "Missing $program."
done

prompt_token() {
    IFS= read -r -s -p 'PC gateway token: ' token </dev/tty || fail 'Could not read token.'
    printf '\n' >&2
    [[ $token =~ ^[0-9a-f]{64}$ ]] || fail 'Expected a 64-character lowercase hexadecimal token.'
}

request() {
    local expected=$1 path=$2 auth=${3:-} data=${4:-} wire
    local -a options=()
    if [[ -n $account ]]; then
        options+=(--header "X-CloudClaude-Account: $account")
    fi
    proof=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
    if [[ -n $data ]]; then
        options+=(--header 'Content-Type: application/json' --data-binary "$data")
    fi
    # Pass the bearer over stdin to curl, leaving its process arguments credential-free.
    wire=$(if [[ -n $auth ]]; then printf 'header = "Authorization: Bearer %s"\n' "$auth"; fi |
        curl -q --config - --silent --show-error --no-buffer --noproxy '*' --max-time 180 \
            --include --write-out $'\n%{http_code}' --header 'anthropic-version: 2023-06-01' \
            --header "X-CloudClaude-Proof: $proof" "${options[@]}" "$base$path") ||
        fail "Transport error on $path."
    local status=${wire##*$'\n'}
    [[ $status == "$expected" ]] || fail "$path returned $status, expected $expected (proof $proof)."
    wire=${wire%$'\n'*}
    local headers=${wire%%$'\r\n\r\n'*}
    body=${wire#*$'\r\n\r\n'}
    trace=$(awk 'tolower($1) == "x-cpa-trace-id:" { sub(/\r$/, "", $2); print $2 }' <<< "$headers")
    content_type=$(awk 'tolower($1) == "content-type:" { sub(/\r$/, "", $2); print $2 }' <<< "$headers")
    local trace_pattern='^[0-9]{14}-([0-9a-f]{16})-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    auth_index=''
    if [[ $trace =~ $trace_pattern ]]; then
        auth_index=${BASH_REMATCH[1]}
    else
        trace='-'
    fi
    printf 'PASS %s HTTP %s proof=%s trace=%s\n' "$path" "$status" "$proof" "$trace"
}

request 200 /healthz
request 401 /v1/models
prompt_token
if [[ $mode == revoked ]]; then
    request 401 /v1/models "$token"
    exit
fi
request 200 /v1/models "$token"
jq -e --arg model "$model" 'any((.data // [])[]; .id == $model)' <<< "$body" >/dev/null 2>&1 ||
    fail 'Selected model is absent from /v1/models.'
for path in /v0/management/config /v8/management/config /management.html; do
    request 404 "$path" "$token"
done

count_json=$(jq -cn --arg model "$model" '{model:$model,messages:[{role:"user",content:"Count these words."}]}')
request 200 /v1/messages/count_tokens "$token" "$count_json"
jq -e '.input_tokens | numbers | . > 0' <<< "$body" >/dev/null 2>&1 || fail 'Invalid token count.'

json=$(jq -cn --arg model "$model" '{model:$model,max_tokens:32,messages:[{role:"user",content:"Reply with the word OK."}]}')
check_message() {
    jq -e --arg model "$model" '.type == "message" and .model == $model and (.content | length > 0)' \
        <<< "$body" >/dev/null 2>&1 || fail 'Invalid Messages response or model mismatch.'
    [[ -n $auth_index ]] || fail 'Missing or malformed credential trace.'
}

if [[ $mode == round-robin ]]; then
    indices=()
    for ((i=0; i<8; i++)); do
        request 200 /v1/messages "$token" "$json"
        check_message
        indices+=("$auth_index")
    done
    [[ ${indices[0]} != "${indices[1]}" ]] || fail 'Expected two distinct upstream credentials.'
    for ((i=2; i<8; i++)); do
        [[ ${indices[i]} == "${indices[i % 2]}" ]] || fail 'Credential trace did not alternate.'
    done
    printf 'PASS two credential indices alternated across eight successful requests.\n'
else
    request 200 /v1/messages "$token" "$json"
    check_message
    first_index=$auth_index
    request 200 /v1/messages "$token" "$(jq -c '.stream = true' <<< "$json")"
    [[ $content_type == text/event-stream* && $auth_index == "$first_index" ]] ||
        fail 'Expected SSE from the same upstream credential.'
    for event in message_start content_block_delta message_stop; do
        grep -qE "^event: $event[[:space:]]*$" <<< "$body" || fail "Missing SSE event $event."
    done
    if grep -qE '^event: error[[:space:]]*$' <<< "$body"; then fail 'SSE reported an error.'; fi
    printf 'PASS complete SSE stream.\n'
fi
