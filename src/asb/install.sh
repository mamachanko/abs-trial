#!/usr/bin/env bash
# Run as the ubuntu user inside the lab target.
set -euo pipefail
umask 077
state="$HOME/.local/state/asb"
mkdir -p "$state"
exec 9>"$state/install.lock"
flock -n 9 || { echo 'Another ASB installation is running.' >&2; exit 1; }

if [[ $(uname -m) != x86_64 ]]; then
    echo 'The pinned lab inference runtime requires x86_64 Linux.' >&2
    exit 1
fi
if ! command -v curl >/dev/null || [[ ! -s /etc/ssl/certs/ca-certificates.crt ]]; then
    echo 'Missing lab prerequisites. Prepare Ubuntu with lab/Dockerfile before running asb install.' >&2
    exit 1
fi
claw="$HOME/.local/bin/openclaw"
version=2026.11.6
if [[ ! -x "$claw" ]]; then
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    base="https://raw.githubusercontent.com/openclaw/openclaw/v$version/scripts"
    for script in install-cli.sh install-policy.sh; do
        curl -fsSL --retry 2 "$base/$script" -o "$tmp/$script"
    done
    (cd "$tmp" && sha256sum --check --status <<'SUMS'
908512f7dd88f0112d9e4f8c2910d3a88ee58879484e90f0d4c7fb87372a2191  install-cli.sh
63e2ea5d77a1f7e2db5fe5f221552b4a9ea0c4f463d4c519f1cb28b6119acac6  install-policy.sh
SUMS
    ) || { echo 'Installer checksum mismatch.' >&2; exit 1; }
    npm_config_cache="$tmp/npm-cache" npm_config_omit=optional bash "$tmp/install-cli.sh" --runtime-only \
        --prefix "$HOME/.local" --version "$version"
fi
"$claw" --version
# Install the CPU inference server and model into the same unprivileged lab.
backend="$HOME/.local/share/asb-model"
release=b7772
server="$backend/llama-$release/llama-server"
model=qwen2.5-0.5b-instruct-q4_k_m.gguf
mkdir -p "$backend"
fetch_verified() {
    local url=$1 file=$2 sha=$3
    curl -fsSL --retry 3 --connect-timeout 15 --max-time 600 "$url" -o "$file.part"
    printf '%s  %s\n' "$sha" "$file.part" | sha256sum --check --status || {
        echo "Checksum mismatch for $file" >&2; return 1
    }
    mv "$file.part" "$file"
}
if [[ ! -x "$server" ]]; then
    fetch_verified "https://github.com/ggml-org/llama.cpp/releases/download/$release/llama-$release-bin-ubuntu-x64.tar.gz" \
        "$backend/server.tar.gz" 61d62c9a5159ef5c7468b8d1254d25718aa95f2cd9f46d173b8c3ee7b248e84c
    unpack=$(mktemp -d "$backend/unpack.XXXXXX")
    tar -xzf "$backend/server.tar.gz" -C "$unpack"
    mv "$unpack/llama-$release" "$backend/"
    rmdir "$unpack"
    rm "$backend/server.tar.gz"
fi
if [[ ! -f "$backend/$model" ]]; then
    echo "Downloading $model"
    fetch_verified "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/9217f5db79a29953eb74d5343926648285ec7e67/$model" \
        "$backend/$model" 74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db
fi
model_ready() {
    curl -fsS --max-time 2 -H 'Authorization: Bearer asb-local' \
        http://127.0.0.1:18080/v1/models 2>/dev/null |
        grep -Eq '"id"[[:space:]]*:[[:space:]]*"asb-local"'
}
pid=$(cat "$backend/server.pid" 2>/dev/null || true)
if [[ -z "$pid" || $(readlink "/proc/$pid/exe" || true) != "$server" ]]; then
    nohup "$server" --model "$backend/$model" --alias asb-local --host 127.0.0.1 --port 18080 \
        --api-key asb-local --ctx-size 8192 --parallel 1 --threads 2 --threads-batch 2 \
        --n-gpu-layers 0 --no-webui --n-predict 64 --temp 0 --cache-ram 0 --batch-size 128 --ubatch-size 128 \
        >"$backend/server.log" 2>&1 </dev/null 9>&- &
    pid=$!
    echo "$pid" > "$backend/server.pid"
fi
for ((i=0; i<60; i++)); do
    if ! kill -0 "$pid" 2>/dev/null; then tail -10 "$backend/server.log" >&2; exit 1; fi
    if model_ready; then break; fi
    sleep 1
done
model_ready || { echo "Model failed to start. See $backend/server.log" >&2; exit 1; }

"$claw" config patch --stdin <<'CONFIG'
{
  "gateway": {"mode": "local"},
  "models": {"providers": {"lab": {
    "baseUrl": "http://127.0.0.1:18080/v1",
    "api": "openai-completions",
    "apiKey": "asb-local",
    "models": [{
      "id": "asb-local", "name": "Qwen2.5 0.5B Instruct",
      "contextWindow": 8192, "maxTokens": 64, "reasoning": false,
      "compat": {"supportsTools": false, "supportsDeveloperRole": false}
    }]
  }}},
  "agents": {"defaults": {
    "model": {"primary": "lab/asb-local", "fallbacks": []},
    "thinkingDefault": "off",
    "params": {"temperature": 0, "maxTokens": 64},
    "skipBootstrap": true,
    "contextInjection": "never"
  }},
  "tools": {"deny": ["*"], "toolSearch": false, "codeMode": false}
}
CONFIG
"$claw" config validate
ready() {
    curl -fsS --max-time 2 http://127.0.0.1:18789/readyz 2>/dev/null |
        "$HOME/.local/tools/node/bin/node" -e \
        'try {process.exit(JSON.parse(require("fs").readFileSync(0)).ready === true ? 0 : 1)} catch {process.exit(1)}'
}
if ready; then exit 0; fi
nohup "$claw" gateway run --bind loopback --port 18789 \
    </dev/null >"$state/gateway.log" 2>&1 9>&- &
pid=$!
for ((i=0; i<90; i++)); do
    if ready; then exit 0; fi
    if ! kill -0 "$pid" 2>/dev/null; then break; fi
    sleep 1
done
echo "Gateway failed to become ready. Inspect $state/gateway.log inside the container." >&2
exit 1
