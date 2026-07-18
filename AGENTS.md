# AGENTS.md

## Project Overview

Generic Docker image for running **[llama.cpp](https://github.com/ggml-org/llama.cpp)** (`llama-server`, CUDA variant).
Uses the pre-built upstream CUDA server image and adds an entrypoint that downloads model weights on startup using
**aria2c** with resume support. Model URLs and runtime configuration are set via environment variables — there are no
hardcoded model defaults.

This project intentionally mirrors the structure of [`stable-diffusion-cpp.docker`](../stable-diffusion-cpp.docker)
(sister project) so the two remain interchangeable from an operator's perspective.

## Instructions

* **Get back to the user:** When seemingly stuck, when an approach does not work as expected, or when new decisions
  have to be taken, the LLM Agent MUST stop and get back to the user with the situation and options instead of
  continuing with assumptions. Do not silently pivot to a different approach.

## Model Download (aria2c)

Models are downloaded via `aria2c` with an input file listing all configured URLs (up to three: `MODEL_URL`,
`MMPROJ_URL`, `MTP_URL`):

- **`-c` (continue)**: resumes partial downloads via a `.aria2` control file + HTTP Range requests. An interrupted run
  continues where it left off on next start.
- **`-x16 -s16`**: 16 parallel connections per file (chunked download).
- **`-j3`**: downloads all 3 model files concurrently.
- **`--header "Authorization: Bearer $HF_TOKEN"`**: auth header sent on all requests (required for gated repos).
  Passed as a bash array element so the header value stays a single argument regardless of spaces.
- **`-i` (input file)**: each URL is paired with an explicit `out=` filename so the output name is controlled regardless
  of CDN redirects.
- **Retry loop**: the download is wrapped in a retry loop (default 3 attempts, configurable via `MAX_ATTEMPTS`). On
  failure, aria2c is re-invoked; `-c` ensures no wasted bandwidth.
- aria2 is installed via `apt-get` (Debian package `aria2`).

## No defaults for runtime/behavior config

The runtime configuration variables (`CTX_SIZE`, `GPU_LAYERS`, `TEMPERATURE`, `TOP_P`, `TOP_K`, `PARALLEL`,
`FLASH_ATTN`, `NO_CONT_BATCHING`, `BATCH_SIZE`, `UBATCH_SIZE`, `MMPROJ_URL`, `MTP_URL`, `SPEC_TYPE`) intentionally
have **no built-in defaults** in the entrypoint. An unset variable means "use whatever llama-server's upstream default
is" — we never substitute our own opinionated default. Only the three infrastructure-level variables that the host
needs to run the container have `${VAR:-default}` fallbacks: `MODEL_DIR` (`/models`), `PORT` (`8080`),
`MAX_ATTEMPTS` (`3`).

## Project Structure

```
.
├── .github/
│   └── workflows/
│       └── docker-publish.yml  # CI: build & push image to GHCR
├── Dockerfile          # FROM upstream CUDA server image; installs aria2, curl, sshd StrictModes fix + entrypoint; HEALTHCHECK
├── entrypoint.sh       # Downloads models via aria2c, then execs llama-server
├── docker-compose.yml  # Port 8080, GPU, models volume, all config via env vars
├── .dockerignore
└── AGENTS.md
```

## CI/CD (GitHub Actions)

The `.github/workflows/docker-publish.yml` workflow builds and pushes the image to the GitHub Container Registry
(GHCR).

- **Trigger:** push to `main` (when `Dockerfile`, `entrypoint.sh`, or the workflow itself changes), plus manual
  `workflow_dispatch`.
- **Registry:** `ghcr.io/dontdrinkandroot/llama-cpp.docker`
- **Tags produced:** `latest` and `sha-<short>` (e.g. `sha-ea0fba2`).
- **Platform:** `linux/amd64` only (upstream CUDA base is amd64; all target hosts are x86_64 NVIDIA GPUs).
- **Auth:** uses the auto-provisioned `GITHUB_TOKEN` with `packages: write`.
- **No GPU needed for build** — the Dockerfile only installs `aria2` and copies the entrypoint; the CUDA runtime comes
  from the upstream base image.

### Image retention (automatic cleanup)

After each successful build, a `cleanup` job runs `snok/container-retention-policy@v3.1.0` to prune old GHCR image
versions, keeping only the **5 newest** tagged versions (`cut-off: 0s` + `keep-n-most-recent: 5`). This prevents the
registry from accumulating stale `sha-<short>` versions over time. Deleted versions remain restorable for 30 days via
GitHub's grace period.

### One-time: make the GHCR package public

After the first workflow run, the package defaults to **private**. Since most consumers (incl. Vast.ai and anonymous
pulls) need access, flip it to public:

1. Go to `https://github.com/users/dontdrinkandroot/packages/container/llama-cpp.docker`
2. **Package settings** → **Danger Zone** → **Change visibility** → **Public**

Alternatively use the CLI:

```bash
gh api --method PATCH /user/packages/container/llama-cpp.docker/visibility \
  -f visibility=public
```

### One-time: grant the repository Admin role on the package

The cleanup job uses the auto-provisioned `GITHUB_TOKEN` to delete old image versions. For this to work, the repository
must have the **Admin** role on the GHCR package (write permission alone is not sufficient for deletion):

1. Go to the package page → **Package settings** → **Manage Actions access**
2. Add the repository `dontdrinkandroot/llama-cpp.docker`
3. Set its role to **Admin**

This step can only be done after the first build creates the package.

## Environment Variables

### Infrastructure (have defaults)

| Variable     | Default | Description                                                                               |
|--------------|---------|-------------------------------------------------------------------------------------------|
| `MODEL_DIR`  | `/models` | Directory for model files (mapped to the `models` volume)                              |
| `PORT`       | `8080`  | llama-server HTTP port (mapped to host `${PORT:-8080}` in `docker-compose.yml`)           |
| `MAX_ATTEMPTS` | `3`   | Max aria2c retry attempts before failing                                                  |
| `HOST`       | `0.0.0.0` (hardcoded) | Bind address for llama-server (always `0.0.0.0` for container operation)        |

### URLs (at least one required)

| Variable      | Required | Maps to           | Description                                                       |
|---------------|----------|-------------------|-------------------------------------------------------------------|
| `MODEL_URL`   | Yes\*    | `--model`         | URL for the main model GGUF file                                  |
| `MMPROJ_URL`  | No       | `--mmproj`        | URL for the multimodal projector GGUF file (vision/audio models)  |
| `MTP_URL`     | No       | `--spec-draft-model` | URL for the speculative-decoding draft model GGUF (e.g. MTP)   |

\* The entrypoint exits non-zero if **all three** are unset.

### Runtime / behavior (unset = upstream llama-server default)

| Variable             | Maps to                  | Default if unset (upstream)                    |
|----------------------|--------------------------|-----------------------------------------------|
| `CTX_SIZE`           | `--ctx-size` / `-c`      | 0 (read from model metadata)                  |
| `GPU_LAYERS`         | `--n-gpu-layers` / `-ngl`| `auto`                                        |
| `TEMPERATURE`        | `--temp`                 | `0.80`                                        |
| `TOP_P`              | `--top-p`                | `0.95`                                        |
| `TOP_K`              | `--top-k`                | `40`                                          |
| `PARALLEL`           | `--parallel` / `-np`     | `-1` (auto, one slot per core)                |
| `FLASH_ATTN`         | `--flash-attn on` (when `=1`) | `auto`                                   |
| `NO_CONT_BATCHING`   | `--no-cont-batching` (when `=1`) | cont-batching enabled                  |
| `BATCH_SIZE`         | `--batch-size` / `-b`    | `2048`                                        |
| `UBATCH_SIZE`        | `--ubatch-size` / `-ub`  | `512`                                         |
| `SPEC_TYPE`          | `--spec-type`            | _(unset; emitted only when `MTP_URL` is set)_ |

### Other

| Variable    | Description                                                                  |
|-------------|------------------------------------------------------------------------------|
| `HF_TOKEN`  | HuggingFace token. Required only for gated repos. Optional for public repos. |

Local filenames are derived from each URL via `basename` (e.g. `.../foo.gguf` → `$MODEL_DIR/foo.gguf`).

### Speculative decoding (MTP)

When `MTP_URL` is set, the entrypoint also passes `--spec-draft-model $MODEL_DIR/<basename>`. If `SPEC_TYPE` is set, it
additionally passes `--spec-type $SPEC_TYPE` — for the Gemma 4 MTP draft this should be `mtp`. The llama-server
default speculative type is `none`, so without `SPEC_TYPE` set alongside `MTP_URL` the draft model is loaded but not
actually used.

## Example: Gemma-4-26B-A4B (Unsloth, with MTP)

Sized for an RTX 5090 (32 GB) where this is the only GPU application. Uses Q6_K_XL
(higher-quality quant) at 65K context with a single slot — keeps ~5 GB VRAM headroom
even after the larger weights. Example values reproduced from `.env` (which is NOT
committed — see `README.md`):

```
HF_TOKEN=

MODEL_URL=https://huggingface.co/unsloth/gemma-4-26B-A4B-it-GGUF/resolve/main/gemma-4-26B-A4B-it-UD-Q6_K_XL.gguf
MMPROJ_URL=https://huggingface.co/unsloth/gemma-4-26B-A4B-it-GGUF/resolve/main/mmproj-BF16.gguf
MTP_URL=https://huggingface.co/unsloth/gemma-4-26B-A4B-it-GGUF/resolve/main/mtp-gemma-4-26B-A4B-it.gguf
SPEC_TYPE=mtp

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

(`NO_CONT_BATCHING` deliberately omitted: continuous batching is the llama-server upstream default.)

## Healthcheck

The Dockerfile defines a `HEALTHCHECK` that probes llama-server's `/health` endpoint via `curl --fail`:

```
HEALTHCHECK --interval=30s --timeout=10s --start-period=1800s --retries=3 \
    CMD curl --fail http://localhost:${PORT:-8080}/health || exit 1
```

- **`start-period=1800s` (30 min):** gives the container a grace period that covers the one-time ~23 GB model
  download (Q6_K_XL) on first start plus the model load and KV-cache init for a 65k context. During this window,
  healthcheck failures do not count against the container. On subsequent starts (models already in the volume), the
  server is ready much faster.
- **`curl`** is installed alongside `aria2` in the Dockerfile.
- The healthcheck respects the `PORT` env var (default `8080`).

## SSH StrictModes Fix (for vast.ai)

When using `--ssh` mode on vast.ai, the platform builds an overlay image that installs `openssh-server` and configures
sshd. Vast.ai's provisioning includes:

```
sed -i "s/StrictModes yes/StrictModes no/g" /etc/ssh/sshd_config
```

However, Ubuntu 24.04's default `sshd_config` ships with `#StrictModes yes` (commented out). The sed only changes it to
`#StrictModes no` — **still commented** — so `StrictModes` falls back to its default of `yes`. This causes sshd to reject
`/root/.ssh/authorized_keys` with:
`Authentication refused: bad ownership or modes for file /root/.ssh/authorized_keys`.

**Fix:** The Dockerfile creates a drop-in config at `/etc/ssh/sshd_config.d/99-strictmodes-no.conf` with
`StrictModes no`. This file:
- Is loaded via the `Include /etc/ssh/sshd_config.d/*.conf` directive in Ubuntu 24.04's `sshd_config`
- Is not a conffile, so it survives vast.ai's `openssh-server` installation
- Pre-creates `/root/.ssh` with `700` permissions as belt-and-suspenders

## Web UI (built-in)

llama-server ships a built-in Web UI on the same port. After the container reports healthy, open
`http://<host>:${PORT:-8080}/` in a browser for a chat playground.

> **Security note:** The server binds to `0.0.0.0` with **no authentication** — anyone who can reach the port gets
> the OpenAI-compatible API on `/v1`. Do not expose this container directly to the public Internet; front it with a
> reverse proxy that enforces auth (e.g. an API gateway), or restrict the published port at the host level.

## Reference

### Upstream llama.cpp

- Repository: https://github.com/ggml-org/llama.cpp
- Pre-built Docker images: https://github.com/ggml-org/llama.cpp/pkgs/container/llama.cpp
- CUDA server image (this project's base): `ghcr.io/ggml-org/llama.cpp:server-cuda`
- Build docs: https://github.com/ggml-org/llama.cpp/blob/master/docs/build.md
- Server README: https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md
- Container / Dockerfile source: `.devops/cuda.Dockerfile` in upstream repo (the server variant sets
  `LLAMA_ARG_HOST=0.0.0.0` and `ENTRYPOINT [/app/llama-server]`)

### Model Downloads (HuggingFace)

- gemma-4-26B-A4B GGUF (Unsloth, multimodal, with MTP draft): https://huggingface.co/unsloth/gemma-4-26B-A4B-it-GGUF
- gemma-4-26B-A4B model card (Google): https://huggingface.co/google/gemma-4-26B-A4B-it (referenced by Unsloth)

### aria2c

- Install: `apt-get install aria2` (Debian package `aria2`)
- aria2 docs: https://aria2.github.io/manual/en/html/aria2c.html
- Key flags: `-c` (continue), `-x` (max connections per server), `-s` (split), `-j` (concurrent downloads), `-i`
  (input file), `--header`, `-d` (dir), `-k` (min split size)
- Downloads page: https://aria2.github.io/

## Self-Update Instruction

This guidelines file is a living document and MUST be actively maintained by the LLM Agent.

* **Trigger:** Whenever significant changes are made to the tech stack, project structure, coding guidelines, or key
  features, the LLM Agent MUST immediately update this file (`AGENTS.md`) to reflect the current state of the project.
* **Content:**
    * Add any information that could have helped the agent to solve the task more efficiently or in fewer steps.
    * Remove outdated, obsolete, or incorrect information.
    * Ensure all tech stack versions and library names are accurate.
    * Make sure the most important features are clearly documented.
    * Keep the project structure up to date so that the most important files and directories are visible at a glance.
* **Proactivity:** Do not wait for explicit instructions to update these guidelines if you identify a discrepancy
  between the guidelines and the actual codebase.
