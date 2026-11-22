# Local CPU inference runtime for the unprivileged Ubuntu lab.
install_local_model() (
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
)
