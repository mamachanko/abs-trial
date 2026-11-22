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
skip_local_model=${3:-}
if [[ "$action" != install && "$action" != upgrade ]] ||
   [[ ! "$version" =~ ^[1-9][0-9]{3}\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    echo 'Expected an exact numeric OpenClaw release (YYYY.M.N).' >&2; exit 1
fi

if [[ "$action" == install && "$skip_local_model" != --skip-local-model && $(uname -m) != x86_64 ]]; then
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
if [[ "$skip_local_model" != --skip-local-model ]]; then
    install_local_model
fi

"$claw" config patch --stdin <<'CONFIG'
{
  "gateway": {"mode": "local"},
  "models": {"providers": {"lab": {
    "baseUrl": "http://127.0.0.1:18080/v1",
    "api": "openai-completions",
    "apiKey": "asb-local",
    "models": [{
      "id": "asb-local", "name": "ASB lab model",
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
