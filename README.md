# llama-cpp.docker

Generic Docker image for running [llama.cpp](https://github.com/ggml-org/llama.cpp) (`llama-server`, CUDA variant).
Models are downloaded automatically on first startup via aria2c and cached in a named volume for subsequent runs.

## Requirements

- NVIDIA GPU + NVIDIA drivers
- Docker with GPU support (Docker 19.03+ with `--gpus` or Docker Compose `deploy.resources`)
- HuggingFace token (**required** if any model URL points to a gated repo)

## Configuration

### 1. Edit `.env`

The repo ships an example `.env` next to `docker-compose.yml` (currently configured for the
[Gemma 4 E2B-it testing setup](#example-gemma-4-e2b-it-unsloth-testing-with-mtp)). Edit it in place
to switch model, set `HF_TOKEN` for gated repos, or tweak runtime values. See
[Environment variables](#environment-variables) below for the full list.

> **Heads-up:** `.env` is tracked in git, so any change you push is public. Public HuggingFace URLs
> and tuning values are fine; **never** commit a real `HF_TOKEN` — for a gated repo, set the token
> locally and leave the field empty in the committed copy.

You must set at least one of `MODEL_URL`, `MMPROJ_URL`, or `MTP_URL` to point at a GGUF file on
HuggingFace.

### 2. Set your HuggingFace token

If any of your model URLs point to a gated HuggingFace repository, you need a token with access:

1. Create a token at https://huggingface.co/settings/tokens
2. Accept the required license at the gated repository's page

Put it in your `.env`:

```env
HF_TOKEN=hf_your_token_here
```

Docker Compose reads `.env` automatically; `docker-compose.yml` wires it in via `env_file: - .env`.

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
| `PORT` | `8080` | llama-server HTTP port (also used for the progress page during the download phase) |
| `MAX_ATTEMPTS` | `3` | Max download retry attempts before failing |
| `ARIA2_RPC_URL` | `http://127.0.0.1:6800/jsonrpc` | aria2c JSON-RPC endpoint that the progress server polls. Must match `--rpc-listen-port` used in `entrypoint.sh`. |
| `MODEL_URL` | *(none — at least one URL must be set)* | URL for the main model GGUF file |
| `MMPROJ_URL` | *(none)* | URL for the multimodal projector GGUF file (vision/audio models) |
| `MTP_URL` | *(none)* | URL for the speculative-decoding draft model GGUF (e.g. MTP). Pairs with `SPEC_TYPE`. |
| `SPEC_TYPE` | *(none)* | Speculative-decoding type, e.g. `mtp`. Only emitted when `MTP_URL` is set. |
| `CTX_SIZE` | *(upstream default)* | Sets `--ctx-size` (e.g. `65536`) |
| `GPU_LAYERS` | *(upstream default)* | Sets `--n-gpu-layers` (e.g. `99` to offload all) |
| `TEMPERATURE` | *(upstream default)* | Sets `--temp` (e.g. `0.6`) |
| `TOP_P` | *(upstream default)* | Sets `--top-p` (e.g. `0.95`) |
| `TOP_K` | *(upstream default)* | Sets `--top-k` (e.g. `64`) |
| `PARALLEL` | *(upstream default)* | Sets `--parallel` (concurrent slots, e.g. `1`) |
| `FLASH_ATTN` | *(upstream default)* | Set to `1` to enable `--flash-attn on` |
| `NO_CONT_BATCHING` | *(upstream default)* | Set to `1` to enable `--no-cont-batching` (default is cont-batching ON) |
| `BATCH_SIZE` | *(upstream default)* | Sets `--batch-size` (e.g. `2048`) |
| `UBATCH_SIZE` | *(upstream default)* | Sets `--ubatch-size` (e.g. `512`) |

Local filenames are derived from each URL via `basename` (e.g. `.../foo.gguf` → `$MODEL_DIR/foo.gguf`).

Runtime/behavior vars have **no built-in defaults**: unset means "use llama-server's upstream default". Only the
infrastructure vars (`MODEL_DIR`, `PORT`, `MAX_ATTEMPTS`) have fallbacks so the container can run.

### Example: Gemma-4-26B-A4B (Unsloth, with MTP speculative decoding)

Sized for an RTX 5090 (32 GB) where this is the only GPU application. Uses Q6_K_XL
(higher-quality quant) at 65K context with a single slot — keeps ~5 GB VRAM headroom
even after the larger weights.

```env
HF_TOKEN=

MODEL_URL=https://huggingface.co/unsloth/gemma-4-26B-A4B-it-GGUF/resolve/main/gemma-4-26B-A4B-it-UD-Q6_K_XL.gguf
MMPROJ_URL=https://huggingface.co/unsloth/gemma-4-26B-A4B-it-GGUF/resolve/main/mmproj-BF16.gguf
MTP_URL=https://huggingface.co/unsloth/gemma-4-26B-A4B-it-GGUF/resolve/main/mtp-gemma-4-26B-A4B-it.gguf
SPEC_TYPE=draft-mtp

CTX_SIZE=65536          # Doubled from 32K; fits in 32 GB VRAM with Q6_K_XL + 1 slot
GPU_LAYERS=99           # Offload all layers to GPU
TEMPERATURE=0.6         # Deliberately conservative. Google's Gemma 4 recipe is 1.0;
                        # bump if you want more varied chat. Keep low for tool/OCR.
TOP_P=0.95
TOP_K=64
PARALLEL=1              # Single slot; required on 32 GB with Q6_K_XL at 65K ctx.
                        # Bump to 2 only if you drop CTX_SIZE back to 32768.
FLASH_ATTN=1
BATCH_SIZE=2048         # Upstream default; ~3-4x faster prefill than 512
# UBATCH_SIZE omitted   # Default 512 fits all reasonable cases

PORT=8080
```

`NO_CONT_BATCHING` is deliberately omitted: continuous batching is enabled by default upstream.

### Example: Gemma 4 E2B-it (Unsloth, testing, with MTP)

A **small** setup for local smoke tests — exercises all three download paths (`MODEL_URL` +
`MMPROJ_URL` + `MTP_URL`) and the speculative-decoding branch of the entrypoint in a single run.
Sized to fit on a 6 GB consumer GPU with audio + image + text inputs.

This is the configuration shipped in the repo's `.env`.

```env
HF_TOKEN=

MODEL_URL=https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it-Q4_K_M.gguf
MMPROJ_URL=https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF/resolve/main/mmproj-F16.gguf
MTP_URL=https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF/resolve/main/mtp-gemma-4-E2B-it.gguf
SPEC_TYPE=draft-mtp

CTX_SIZE=32768          # E2B advertises 128K; stay conservative on tight memory
GPU_LAYERS=99           # Offload all layers to GPU
TEMPERATURE=0.7
TOP_P=0.95
TOP_K=64
PARALLEL=1
FLASH_ATTN=1
BATCH_SIZE=2048         # Upstream default; faster prefill than 512

PORT=8080
```

| File | Size | Purpose |
|------|------|---------|
| `gemma-4-E2B-it-Q4_K_M.gguf` | 3.11 GB | main model |
| `mmproj-F16.gguf` | 986 MB | vision/audio projector |
| `mtp-gemma-4-E2B-it.gguf` | 97.8 MB | speculative drafter (~0.4 B params) |

**Total download:** ~4.2 GB. **VRAM:** ~6 GB. **Context:** 128K (we use 32K to stay safe).

> **Known caveat:** Speculative decoding + `mmproj` together was historically broken in
> `llama-server` (see [ggml-org/llama.cpp#19712](https://github.com/ggml-org/llama.cpp/issues/19712)).
> Recent upstream builds reportedly fixed it; if startup fails with this combo, drop `MTP_URL`
> first to confirm the model itself runs, then re-add it.

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
