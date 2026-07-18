#!/bin/bash
set -e

MODEL_DIR="${MODEL_DIR:-/models}"
PORT="${PORT:-8080}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"

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
until [ $attempt -gt "$MAX_ATTEMPTS" ]; do
    echo "=== Downloading models (attempt $attempt/$MAX_ATTEMPTS) ==="
    if aria2c \
        -c \
        -x16 \
        -s16 \
        -j3 \
        -k 1M \
        "${AUTH_HEADERS[@]}" \
        -d "$MODEL_DIR" \
        -i "$INPUT_FILE"; then
        echo "=== Download complete ==="
        break
    else
        echo "=== Download attempt $attempt failed ==="
        attempt=$((attempt + 1))
        if [ $attempt -gt "$MAX_ATTEMPTS" ]; then
            echo "ERROR: Download failed after $MAX_ATTEMPTS attempts."
            rm -f "$INPUT_FILE"
            exit 1
        fi
    fi
done

rm -f "$INPUT_FILE"

echo "=== Starting llama-server ==="

cd "$MODEL_DIR"

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
        MTP_FLAGS="$MTP_FLAGS --spec-type $SPEC_TYPE"
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

exec "${CMD[@]}"
