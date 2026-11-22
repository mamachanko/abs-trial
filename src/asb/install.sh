#!/usr/bin/env bash
# Run as the ubuntu user inside the lab target.
set -euo pipefail
umask 077
state="$HOME/.local/state/asb"
mkdir -p "$state"
exec 9>"$state/install.lock"
flock -n 9 || { echo 'Another ASB installation or upgrade is running.' >&2; exit 1; }
action=${1:-install}
version=${2:-2026.11.6}
if [[ "$action" != install && "$action" != upgrade ]] ||
   [[ ! "$version" =~ ^[1-9][0-9]{3}\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    echo 'Expected an exact numeric OpenClaw release (YYYY.M.N).' >&2; exit 1
fi

if [[ $(uname -m) != x86_64 ]]; then
    echo 'The pinned lab inference runtime requires x86_64 Linux.' >&2
    exit 1
fi
if ! command -v curl >/dev/null || [[ ! -s /etc/ssl/certs/ca-certificates.crt ]]; then
    echo 'Missing lab prerequisites. Prepare Ubuntu with lab/Dockerfile before running asb install.' >&2
    exit 1
fi
claw="$HOME/.local/bin/openclaw"
node="$HOME/.local/tools/node/bin/node"
installed_version() {
    local output
    output=$("$claw" --version 2>/dev/null) || return 1
    [[ "$output" =~ (^|[[:space:]])([1-9][0-9]{3}\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*))($|[[:space:]]) ]] || return 1
    printf '%s\n' "${BASH_REMATCH[2]}"
}
prepare_installer() {
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    # Keep the installer and its policy pinned independently of the package target.
    local base="https://raw.githubusercontent.com/openclaw/openclaw/v2026.11.6/scripts"
    for script in install-cli.sh install-policy.sh; do
        curl -fsSL --retry 2 "$base/$script" -o "$tmp/$script"
    done
    (cd "$tmp" && sha256sum --check --status <<'SUMS'
908512f7dd88f0112d9e4f8c2910d3a88ee58879484e90f0d4c7fb87372a2191  install-cli.sh
63e2ea5d77a1f7e2db5fe5f221552b4a9ea0c4f463d4c519f1cb28b6119acac6  install-policy.sh
SUMS
    ) || { echo 'Installer checksum mismatch.' >&2; exit 1; }
}
install_package() {
    npm_config_cache="$tmp/npm-cache" npm_config_omit=optional bash "$tmp/install-cli.sh" --runtime-only \
        --prefix "$HOME/.local" --version "$version"
}
verify_version() {
    [[ $(installed_version) == "$version" ]] || {
        echo "OpenClaw did not report requested version $version." >&2; exit 1
    }
    "$claw" --version
}
current=$(installed_version || true)
if [[ "$action" == upgrade ]]; then
    if [[ -z "$current" ]]; then
        [[ $(cat "$state/upgrade-target" 2>/dev/null || true) == "$version" ]] || {
            echo 'No usable ASB OpenClaw installation. Run asb install first.' >&2; exit 1
        }
    elif [[ $(printf '%s\n%s\n' "$current" "$version" | sort -V | head -n1) != "$current" ]]; then
        echo "Refusing to downgrade OpenClaw $current to $version." >&2; exit 1
    fi
    if [[ "$current" == "$version" ]]; then
        gateway_start "$version" --restart-if-needed
        rm -f "$state/upgrade-target"
        exit 0
    fi

    prepare_installer
    # Check the release before taking the existing gateway offline.
    available=$(PATH="$HOME/.local/tools/node/bin:$PATH" npm_config_cache="$tmp/npm-cache" \
        "$node" "$HOME/.local/tools/node/lib/node_modules/npm/bin/npm-cli.js" \
        view "openclaw@$version" version --fetch-retries 1 --fetch-timeout 30000)
    [[ "$available" == "$version" ]] || { echo "OpenClaw $version is unavailable." >&2; exit 1; }

    gateway_stop
    printf '%s\n' "$version" > "$state/upgrade-target.tmp"
    mv "$state/upgrade-target.tmp" "$state/upgrade-target"
    if ! install_package; then
        if [[ -n "$current" && $(installed_version || true) == "$current" ]]; then
            echo "Upgrade failed; restarting the intact OpenClaw $current gateway." >&2
            gateway_start "$current" || true
        fi
        echo "Package installation failed. Retry asb upgrade --to $version." >&2
        exit 1
    fi
    verify_version
    gateway_start "$version"
    rm -f "$state/upgrade-target"
    exit 0
fi
if [[ ! -x "$claw" ]]; then
    prepare_installer
    install_package
elif [[ "$current" != "$version" ]]; then
    echo "Installed OpenClaw is ${current:-unusable}; use asb upgrade --to $version or choose its installed version." >&2
    exit 1
fi
verify_version
# Install the CPU inference server and model into the same unprivileged lab.
backend="$HOME/.local/share/asb-model"
release=b7772
server="$backend/llama-$release/llama-server"
model=LFM2.5-350M-Q4_K_M.gguf
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
    fetch_verified "https://huggingface.co/LiquidAI/LFM2.5-350M-GGUF/resolve/657e078c94084481950a2d555a941481f715536b/$model" \
        "$backend/$model" 7e6f72643caafc9a68256686638c4d7916f2cec76d1df478d4c3ddcd95a6aed4
fi
model_ready() {
    curl -fsS --max-time 2 -H 'Authorization: Bearer asb-local' \
        http://127.0.0.1:18080/v1/models 2>/dev/null |
        grep -Eq '"id"[[:space:]]*:[[:space:]]*"asb-local"'
}
pid=$(cat "$backend/server.pid" 2>/dev/null || true)
# Replace the previous Qwen model on a live reinstall.
if [[ "$pid" =~ ^[1-9][0-9]*$ && $(readlink "/proc/$pid/exe" || true) == "$server" ]]; then
    mapfile -d '' -t args < "/proc/$pid/cmdline"
    if [[ ${args[1]:-} == --model && ${args[2]:-} == "$backend/qwen2.5-0.5b-instruct-q4_k_m.gguf" ]]; then
        kill -- "$pid"
        for ((i=0; i<30; i++)); do
            [[ $(readlink "/proc/$pid/exe" || true) != "$server" ]] && break
            sleep 1
        done
        if [[ $(readlink "/proc/$pid/exe" || true) == "$server" ]]; then
            echo 'Previous lab inference server did not stop.' >&2; exit 1
        fi
        pid=
    fi
fi
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
      "id": "asb-local", "name": "LFM2.5 350M",
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
gateway_start "$version"
