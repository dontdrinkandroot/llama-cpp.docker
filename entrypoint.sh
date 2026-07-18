#!/bin/bash
set -e

MODEL_DIR="${MODEL_DIR:-/models}"
PORT="${PORT:-8080}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"

PROGRESS_PID_FILE=/tmp/progress-server.pid
ARIA2_PID_FILE=/tmp/aria2c.pid
ARIA2_RPC_URL="${ARIA2_RPC_URL:-http://127.0.0.1:6800/jsonrpc}"
ARIA2_RPC_PORT="${ARIA2_RPC_PORT:-6800}"

stop_progress_server() {
    if [ -f "$PROGRESS_PID_FILE" ]; then
        local pid
        pid="$(cat "$PROGRESS_PID_FILE")"
        kill "$pid" 2>/dev/null || true
        # wait for the socket to be released; SIGTERM'd child exits 143,
        # which we suppress so `set -e` does not abort before `exec`.
        wait "$pid" 2>/dev/null || true
        rm -f "$PROGRESS_PID_FILE"
    fi
}

# Tear down aria2c. Safe to call multiple times; safe to call when not started.
stop_aria2c() {
    if [ -f "$ARIA2_PID_FILE" ]; then
        local pid
        pid="$(cat "$ARIA2_PID_FILE")"
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            # Give aria2c up to 5s to flush and exit; then SIGKILL.
            for _ in $(seq 1 50); do
                kill -0 "$pid" 2>/dev/null || break
                sleep 0.1
            done
            kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
        rm -f "$ARIA2_PID_FILE"
    fi
}

# Tear down both background processes on any exit path.
cleanup() {
    stop_aria2c
    stop_progress_server
}
if [ -f /progress-server.py ]; then
    python3 /progress-server.py &
    echo $! > "$PROGRESS_PID_FILE"
    trap cleanup EXIT
    trap 'cleanup; exit 130' INT
    trap 'cleanup; exit 143' TERM
    # Wait until the progress server has bound the port (a few hundred ms for
    # Python startup) so requests that arrive immediately after this point
    # never see a closed port (which would RST inside the container's netns).
    for _ in $(seq 1 50); do
        if (exec 3<>/dev/tcp/127.0.0.1/"$PORT") 2>/dev/null; then
            exec 3<&- 3>&-
            break
        fi
        sleep 0.1
    done
fi

if [ -z "$MODEL_URL" ] && [ -z "$MMPROJ_URL" ] && [ -z "$MTP_URL" ]; then
    echo "ERROR: No model URLs configured."
    echo "Set at least one of MODEL_URL, MMPROJ_URL, or MTP_URL."
    echo "Example:"
    echo "  MODEL_URL=https://huggingface.co/unsloth/gemma-4-26B-A4B-it-GGUF/resolve/main/gemma-4-26B-A4B-it-UD-Q6_K_XL.gguf"
    echo "  MMPROJ_URL=https://huggingface.co/unsloth/gemma-4-26B-A4B-it-GGUF/resolve/main/mmproj-BF16.gguf"
    echo "  MTP_URL=https://huggingface.co/unsloth/gemma-4-26B-A4B-it-GGUF/resolve/main/mtp-gemma-4-26B-A4B-it.gguf"
    exit 1
fi

AUTH_HEADERS=()
if [ -n "$HF_TOKEN" ]; then
    AUTH_HEADERS=(--header "Authorization: Bearer $HF_TOKEN")
else
    echo "WARNING: HF_TOKEN is not set. Downloads from gated repos will fail."
fi

INPUT_FILE="/tmp/aria2-input.txt"
> "$INPUT_FILE"

if [ -n "$MODEL_URL" ]; then
    echo "${MODEL_URL}" >> "$INPUT_FILE"
    echo "  out=$(basename "$MODEL_URL")" >> "$INPUT_FILE"
fi

if [ -n "$MMPROJ_URL" ]; then
    echo "${MMPROJ_URL}" >> "$INPUT_FILE"
    echo "  out=$(basename "$MMPROJ_URL")" >> "$INPUT_FILE"
fi

if [ -n "$MTP_URL" ]; then
    echo "${MTP_URL}" >> "$INPUT_FILE"
    echo "  out=$(basename "$MTP_URL")" >> "$INPUT_FILE"
fi

attempt=1
download_ok=1
until [ $attempt -gt "$MAX_ATTEMPTS" ]; do
    echo "=== Downloading models (attempt $attempt/$MAX_ATTEMPTS) ==="
    # aria2c with --enable-rpc stays running after downloads complete (to
    # serve the JSON-RPC interface for the progress page), so we cannot just
    # `if aria2c ...; then`. Instead: start aria2c in the background, poll
    # its RPC until every file is complete (or it crashes), then shut it
    # down. -c resumes from any previous attempt's .aria2 control file.
    aria2c \
        -c \
        -x16 \
        -s16 \
        -j3 \
        -k 1M \
        --enable-rpc \
        --rpc-listen-port="$ARIA2_RPC_PORT" \
        --rpc-listen-all=false \
        "${AUTH_HEADERS[@]}" \
        -d "$MODEL_DIR" \
        -i "$INPUT_FILE" \
        >/tmp/aria2c.log 2>&1 &
    ARIA2_PID=$!
    echo "$ARIA2_PID" > "$ARIA2_PID_FILE"

    # Wait for the RPC socket to come up before polling (a few hundred ms).
    rpc_ready=0
    for _ in $(seq 1 50); do
        if (exec 3<>/dev/tcp/127.0.0.1/"$ARIA2_RPC_PORT") 2>/dev/null; then
            exec 3<&- 3>&-
            rpc_ready=1
            break
        fi
        # aria2c exited before RPC came up -> fatal error.
        if ! kill -0 "$ARIA2_PID" 2>/dev/null; then
            break
        fi
        sleep 0.1
    done

    download_ok=1
    if [ "$rpc_ready" = "1" ]; then
        # Poll until no active and no waiting downloads remain. We never
        # auto-retry on a single transient error: if aria2c crashes, the
        # process check below catches it and we restart with -c.
        # A curl failure here means RPC is unreachable (aria2c is still
        # alive per the kill -0 check); keep polling.
        while true; do
            if ! kill -0 "$ARIA2_PID" 2>/dev/null; then
                echo "ERROR: aria2c exited unexpectedly."
                cat /tmp/aria2c.log
                download_ok=0
                break
            fi
            active_resp="$(curl -fsS --max-time 2 \
                -H 'Content-Type: application/json' \
                --data '{"jsonrpc":"2.0","id":"x","method":"aria2.tellActive"}' \
                "$ARIA2_RPC_URL" 2>/dev/null || true)"
            waiting_resp="$(curl -fsS --max-time 2 \
                -H 'Content-Type: application/json' \
                --data '{"jsonrpc":"2.0","id":"x","method":"aria2.tellWaiting","params":[0,100]}' \
                "$ARIA2_RPC_URL" 2>/dev/null || true)"
            # If aria2c is alive but RPC is unreachable, keep waiting.
            if [ -z "$active_resp" ] || [ -z "$waiting_resp" ]; then
                sleep 1
                continue
            fi
            # Extract just the contents of "result":[...] for a length check.
            active="${active_resp#*\"result\":\[}"
            active="${active%%]*}"
            waiting="${waiting_resp#*\"result\":\[}"
            waiting="${waiting%%]*}"
            if [ -z "$active" ] && [ -z "$waiting" ]; then
                break
            fi
            sleep 2
        done
    else
        echo "ERROR: aria2c RPC did not become ready."
        cat /tmp/aria2c.log
        download_ok=0
    fi

    # Shut aria2c down cleanly (idempotent). tail the log for the operator.
    stop_aria2c
    if [ "$download_ok" = "1" ]; then
        echo "=== Download complete ==="
        break
    fi

    attempt=$((attempt + 1))
    if [ $attempt -gt "$MAX_ATTEMPTS" ]; then
        echo "ERROR: Download failed after $MAX_ATTEMPTS attempts."
        rm -f "$INPUT_FILE"
        exit 1
    fi
    echo "=== Download attempt $((attempt - 1)) failed; retrying with -c ==="
done

rm -f "$INPUT_FILE"

echo "=== Starting llama-server ==="

MODEL_FLAG=""
if [ -n "$MODEL_URL" ]; then
    MODEL_FLAG="--model $MODEL_DIR/$(basename "$MODEL_URL")"
fi

MMPROJ_FLAG=""
if [ -n "$MMPROJ_URL" ]; then
    MMPROJ_FLAG="--mmproj $MODEL_DIR/$(basename "$MMPROJ_URL")"
fi

MTP_FLAGS=""
if [ -n "$MTP_URL" ]; then
    MTP_FLAGS="--spec-draft-model $MODEL_DIR/$(basename "$MTP_URL")"
    if [ -n "$SPEC_TYPE" ]; then
        # Translate legacy/bare "mtp" to the current upstream value "draft-mtp"
        # (valid in recent llama.cpp builds; bare "mtp" is now rejected).
        spec_type="$SPEC_TYPE"
        if [ "$spec_type" = "mtp" ]; then
            spec_type="draft-mtp"
        fi
        MTP_FLAGS="$MTP_FLAGS --spec-type $spec_type"
    fi
fi

CTX_SIZE_FLAG=""
if [ -n "$CTX_SIZE" ]; then
    CTX_SIZE_FLAG="--ctx-size $CTX_SIZE"
fi

GPU_LAYERS_FLAG=""
if [ -n "$GPU_LAYERS" ]; then
    GPU_LAYERS_FLAG="--n-gpu-layers $GPU_LAYERS"
fi

TEMPERATURE_FLAG=""
if [ -n "$TEMPERATURE" ]; then
    TEMPERATURE_FLAG="--temp $TEMPERATURE"
fi

TOP_P_FLAG=""
if [ -n "$TOP_P" ]; then
    TOP_P_FLAG="--top-p $TOP_P"
fi

TOP_K_FLAG=""
if [ -n "$TOP_K" ]; then
    TOP_K_FLAG="--top-k $TOP_K"
fi

PARALLEL_FLAG=""
if [ -n "$PARALLEL" ]; then
    PARALLEL_FLAG="--parallel $PARALLEL"
fi

FLASH_ATTN_FLAG=""
if [ "${FLASH_ATTN}" = "1" ]; then
    FLASH_ATTN_FLAG="--flash-attn on"
fi

NO_CONT_BATCHING_FLAG=""
if [ "${NO_CONT_BATCHING}" = "1" ]; then
    NO_CONT_BATCHING_FLAG="--no-cont-batching"
fi

BATCH_SIZE_FLAG=""
if [ -n "$BATCH_SIZE" ]; then
    BATCH_SIZE_FLAG="--batch-size $BATCH_SIZE"
fi

UBATCH_SIZE_FLAG=""
if [ -n "$UBATCH_SIZE" ]; then
    UBATCH_SIZE_FLAG="--ubatch-size $UBATCH_SIZE"
fi

CMD=(
    /app/llama-server
    $MODEL_FLAG
    $MMPROJ_FLAG
    $MTP_FLAGS
    --host 0.0.0.0
    --port "$PORT"
    $CTX_SIZE_FLAG
    $GPU_LAYERS_FLAG
    $TEMPERATURE_FLAG
    $TOP_P_FLAG
    $TOP_K_FLAG
    $PARALLEL_FLAG
    $FLASH_ATTN_FLAG
    $NO_CONT_BATCHING_FLAG
    $BATCH_SIZE_FLAG
    $UBATCH_SIZE_FLAG
    "$@"
)

echo "=== llama-server command ==="
printf '%q ' "${CMD[@]}"
echo
echo "============================"

# aria2c is already stopped (stop_aria2c ran above). Now stop the progress
# server so llama-server can bind --port. exec below does not fire traps.
cleanup

exec "${CMD[@]}"
