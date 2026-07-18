# llama-cpp.docker

Generic Docker image for running [llama.cpp](https://github.com/ggml-org/llama.cpp) (`llama-server`, CUDA variant).
Models are downloaded automatically on first startup via aria2c and cached in a named volume for subsequent runs.

## Requirements

- NVIDIA GPU + NVIDIA drivers
- Docker with GPU support (Docker 19.03+ with `--gpus` or Docker Compose `deploy.resources`)
- HuggingFace token (**required** if any model URL points to a gated repo)

## Configuration

### 1. Create a local `.env` file

The repo does **not** ship a `.env` file (it would leak secrets). Create one next to `docker-compose.yml` with at
least one model URL. The other env vars are optional — see [Environment variables](#environment-variables) below.

```bash
cp -n .env .env.disabled 2>/dev/null  # optional: keep a placeholder
nano .env
```

You must set at least one of `MODEL_URL`, `MMPROJ_URL`, or `MTP_URL` to point at a GGUF file on HuggingFace.

### 2. Set your HuggingFace token

If any of your model URLs point to a gated HuggingFace repository, you need a token with access:

1. Create a token at https://huggingface.co/settings/tokens
2. Accept the required license at the gated repository's page

Put it in your `.env`:

```env
HF_TOKEN=hf_your_token_here
```

Docker Compose reads `.env` automatically; the compose file references it via `${HF_TOKEN:-}` (docker-compose.yml).

### 3. Build and start

```bash
docker compose up -d --build
```

The first start downloads model files into the `models` named volume. Downloads use aria2c with parallel connections
and resume support.

### 4. Use the server

Once running, the llama-server listens on port `8080` (or whatever `PORT` is set to). The container exposes the
full **OpenAI-compatible API** under `/v1` (e.g. `/v1/chat/completions`, `/v1/embeddings`), the Anthropic Messages
API, and a built-in **Web UI** at `http://<host>:${PORT:-8080}/`.

### Subsequent starts

The `models` volume persists across `docker compose down` / `up`. The entrypoint skips any file already present, so
subsequent starts launch immediately without re-downloading. Only `docker compose down -v` (which deletes the volume)
forces a fresh download.

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `HF_TOKEN` | (empty) | HuggingFace token; **required** for gated repos. Optional if all URLs point to public repos. |
| `MODEL_DIR` | `/models` | Directory for model files (mapped to the `models` volume) |
| `PORT` | `8080` | llama-server HTTP port |
| `MAX_ATTEMPTS` | `3` | Max download retry attempts before failing |
| `MODEL_URL` | *(none — at least one URL must be set)* | URL for the main model GGUF file |
| `MMPROJ_URL` | *(none)* | URL for the multimodal projector GGUF file (vision/audio models) |
| `MTP_URL` | *(none)* | URL for the speculative-decoding draft model GGUF (e.g. MTP). Pairs with `SPEC_TYPE`. |
| `SPEC_TYPE` | *(none)* | Speculative-decoding type, e.g. `mtp`. Only emitted when `MTP_URL` is set. |
| `CTX_SIZE` | *(upstream default)* | Sets `--ctx-size` (e.g. `65536`) |
| `GPU_LAYERS` | *(upstream default)* | Sets `--n-gpu-layers` (e.g. `99` to offload all) |
| `TEMPERATURE` | *(upstream default)* | Sets `--temp` (e.g. `0.6`) |
| `TOP_P` | *(upstream default)* | Sets `--top-p` (e.g. `0.95`) |
| `TOP_K` | *(upstream default)* | Sets `--top-k` (e.g. `64`) |
| `PARALLEL` | *(upstream default)* | Sets `--parallel` (concurrent slots, e.g. `2`) |
| `FLASH_ATTN` | *(upstream default)* | Set to `1` to enable `--flash-attn on` |
| `NO_CONT_BATCHING` | *(upstream default)* | Set to `1` to enable `--no-cont-batching` (default is cont-batching ON) |
| `BATCH_SIZE` | *(upstream default)* | Sets `--batch-size` (e.g. `2048`) |
| `UBATCH_SIZE` | *(upstream default)* | Sets `--ubatch-size` (e.g. `512`) |

Local filenames are derived from each URL via `basename` (e.g. `.../foo.gguf` → `$MODEL_DIR/foo.gguf`).

Runtime/behavior vars have **no built-in defaults**: unset means "use llama-server's upstream default". Only the
infrastructure vars (`MODEL_DIR`, `PORT`, `MAX_ATTEMPTS`) have fallbacks so the container can run.

### Example: Gemma-4-26B-A4B (Unsloth, with MTP speculative decoding)

Sized for an RTX 5090 (32 GB) where this is the only GPU application. Doubles context to 65K
and runs two concurrent slots.

```env
HF_TOKEN=

MODEL_URL=https://huggingface.co/unsloth/gemma-4-26B-A4B-it-GGUF/resolve/main/gemma-4-26B-A4B-it-UD-Q5_K_XL.gguf
MMPROJ_URL=https://huggingface.co/unsloth/gemma-4-26B-A4B-it-GGUF/resolve/main/mmproj-BF16.gguf
MTP_URL=https://huggingface.co/unsloth/gemma-4-26B-A4B-it-GGUF/resolve/main/mtp-gemma-4-26B-A4B-it.gguf
SPEC_TYPE=mtp

CTX_SIZE=65536          # Doubled from 32K; fits comfortably in 32 GB VRAM
GPU_LAYERS=99           # Offload all layers to GPU
TEMPERATURE=0.6         # Deliberately conservative. Google's Gemma 4 recipe is 1.0;
                        # bump if you want more varied chat. Keep low for tool/OCR.
TOP_P=0.95
TOP_K=64
PARALLEL=2              # 2 concurrent slots; fits at 65K ctx on 32 GB.
                        # Bump to 4 only if you drop CTX_SIZE back to 32768.
FLASH_ATTN=1
BATCH_SIZE=2048         # Upstream default; ~3-4x faster prefill than 512
# UBATCH_SIZE omitted   # Default 512 fits all reasonable cases

PORT=8080
```

`NO_CONT_BATCHING` is deliberately omitted: continuous batching is enabled by default upstream.

## Web UI

llama-server ships a built-in Web UI on the same port. After the container reports healthy, open
`http://<host>:${PORT:-8080}/` in a browser for a chat playground.

## Security

The server binds to `0.0.0.0` with **no authentication** — anyone who can reach the port gets the OpenAI-compatible
API on `/v1`, the Anthropic Messages API, and the Web UI. Do not expose this container directly to the public
Internet; front it with a reverse proxy that enforces auth (e.g. an API gateway), or restrict the published port at
the host level.

## Using the pre-built GHCR image

The compose file is tagged for the GitHub Container Registry:

```bash
docker compose pull
docker compose up -d
```

Image: `ghcr.io/dontdrinkandroot/llama-cpp.docker:latest`
