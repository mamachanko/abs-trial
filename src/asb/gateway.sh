# Gateway lifecycle functions for the unprivileged Ubuntu lab.
_gateway_ready() {
    curl -fsS --max-time 2 http://127.0.0.1:18789/readyz 2>/dev/null |
        "$node" -e \
        'try {process.exit(JSON.parse(require("fs").readFileSync(0)).ready === true ? 0 : 1)} catch {process.exit(1)}'
}
_gateway_version_matches() {
    "$claw" gateway probe --json --timeout 30000 2>/dev/null |
        "$node" -e '
        try {
            const probe = JSON.parse(require("fs").readFileSync(0));
            process.exit(probe.targets?.some(t => t.url === "ws://127.0.0.1:18789" && t.server?.version === process.argv[1]) ? 0 : 1);
        } catch { process.exit(1); }' "$1"
}
# The CLI can respawn Node children. Its lifecycle lock identifies the gateway itself.
_gateway_owned_pid() {
    local pid
    pid=$("$node" - "$state/gateway.log" \
        "$HOME/.openclaw/tmp/openclaw-$(id -u)/gateway.state.lock" "$node" <<'NODE'
const fs = require("fs");
const [log, lockPath, node] = process.argv.slice(2);
let lock;
try { lock = JSON.parse(fs.readFileSync(lockPath)); } catch { process.exit(0); }
if (!Number.isSafeInteger(lock.pid) || lock.pid <= 0 || !Number.isSafeInteger(lock.startTime)) process.exit(0);
const proc = `/proc/${lock.pid}`;
let start;
try {
    const stat = fs.readFileSync(`${proc}/stat`, "utf8");
    start = Number(stat.slice(stat.lastIndexOf(")") + 2).split(" ")[19]);
} catch { process.exit(0); }
if (start !== lock.startTime) process.exit(0);
try {
    if (fs.readlinkSync(`${proc}/exe`) !== fs.realpathSync(node) ||
        fs.readlinkSync(`${proc}/fd/1`) !== log ||
        (lock.role && lock.role !== "gateway") || (lock.port && lock.port !== 18789)) {
        throw new Error("ownership mismatch");
    }
} catch {
    console.error("Gateway lock belongs to another process. Inspect openclaw gateway status --deep before retrying.");
    process.exit(1);
}
console.log(lock.pid);
NODE
    ) || return 1
    if [[ -z "$pid" ]] && _gateway_ready; then
        echo 'Gateway is reachable without a usable ASB lock. Inspect openclaw gateway status --deep and stop its owner manually, then retry.' >&2
        return 1
    fi
    printf '%s\n' "$pid"
}
gateway_stop() {
    local pid birth current i
    pid=$(_gateway_owned_pid) || return 1
    [[ -n "$pid" ]] || return 0
    birth=$(awk '{print $22}' "/proc/$pid/stat")
    # Recheck ownership immediately before signaling; stale PID files are never trusted.
    current=$(_gateway_owned_pid) || return 1
    [[ "$current" == "$pid" && $(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null) == "$birth" ]] || {
        echo 'Gateway ownership changed. Retry the upgrade.' >&2; return 1
    }
    kill -- "$pid" || return 1
    for ((i=0; i<30; i++)); do
        [[ $(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null || true) != "$birth" ]] && break
        sleep 1
    done
    current=$(_gateway_owned_pid) || return 1
    [[ -z "$current" ]] || {
        echo 'ASB gateway did not stop. Inspect its process before retrying.' >&2; return 1
    }
}
gateway_start() {
    local expected=$1 policy=${2:-} pid owner i
    pid=$(_gateway_owned_pid) || return 1
    if [[ -n "$pid" ]]; then
        if _gateway_ready && _gateway_version_matches "$expected"; then
            if [[ "$policy" == --restart-if-needed ]]; then
                echo "OpenClaw $expected gateway is already current."
            fi
            return 0
        fi
        if [[ "$policy" != --restart-if-needed ]]; then
            echo "A gateway is already running. Use asb upgrade --to $expected to restart it." >&2
            return 1
        fi
        gateway_stop || return 1
    fi
    nohup "$claw" gateway run --bind loopback --port 18789 \
        </dev/null >"$state/gateway.log" 2>&1 9>&- &
    pid=$!
    for ((i=0; i<90; i++)); do
        if _gateway_ready; then
            owner=$(_gateway_owned_pid) || return 1
            if [[ -n "$owner" ]] && _gateway_version_matches "$expected"; then return 0; fi
            break
        fi
        if ! kill -0 "$pid" 2>/dev/null; then break; fi
        sleep 1
    done
    echo "Gateway failed to start at version $expected. Inspect $state/gateway.log inside the container, then retry." >&2
    return 1
}
