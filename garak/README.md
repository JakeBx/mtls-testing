# garak mTLS Tests

Validates that [garak](https://github.com/NVIDIA/garak)'s `RestGenerator` correctly handles mTLS client certificates, including:

- Plain RSA client certificates
- Encrypted (passphrase-protected) RSA client keys
- Pickle/unpickle across multiprocessing boundaries (`_load_unsafe` fix in [`JakeBx/garak@mtls-client-auth-fix`](https://github.com/JakeBx/garak/tree/mtls-client-auth-fix))

Two proxy targets are supported:
- **Ollama** (local) — via `/generate` endpoint
- **OpenRouter** (cloud) — via `/openrouter` endpoint, with API key injected by nginx at runtime

## Files

```
garak/
├── environment.yml                     # conda environment (garak fork + pytest)
├── test_mtls.py                        # pytest smoke tests
├── garak_config.json                   # Ollama via mTLS (plain client cert)
├── garak_config_encrypted.json         # Ollama via mTLS (encrypted client key)
├── garak_config_multi.json             # Ollama via mTLS (multiple probes)
├── garak_config_openrouter.json        # OpenRouter via mTLS proxy
└── garak_config_openrouter_direct.json # OpenRouter direct (no proxy)
```

## Prerequisites

- Proxy scaffold running — see root [README.md](../README.md) for cert generation and `docker compose up`
- [Ollama](https://ollama.ai/) running on `localhost:11434` (required for Ollama configs and pytest)
- `OPENROUTER_API_KEY` environment variable set (required for OpenRouter configs)

## Setup

```bash
conda env create -f garak/environment.yml
conda activate mtls-testing
```

## Run tests

```bash
pytest garak/test_mtls.py -v
```

## Run garak

All commands run from the **project root** so cert paths (`certs/client.crt` etc.) resolve correctly.

**Ollama (plain client cert):**
```bash
garak --config garak/garak_config.json
```

**Ollama (encrypted client key):**
```bash
export MTLS_KEY_PASS=changeit
garak --config garak/garak_config_encrypted.json
```

**Ollama (multiple probes):**
```bash
garak --config garak/garak_config_multi.json
```

**OpenRouter via mTLS proxy:**
```bash
garak --config garak/garak_config_openrouter.json
```

**OpenRouter direct (no proxy):**
```bash
export OPENROUTER_API_KEY=<your-key>
garak --config garak/garak_config_openrouter_direct.json
```

## Results

### OpenRouter via mTLS Proxy (`garak_config_openrouter.json`)

Probe: `badchars.BadCharacters` — imperceptible Unicode perturbations (homoglyphs, invisible chars, swaps, deletions)
Model: `mistralai/mistral-nemo` via `https://127.0.0.1/openrouter` → nginx mTLS proxy → `openrouter.ai`

| Metric | Value |
|--------|-------|
| Prompts | 5 (`soft_probe_prompt_cap`) |
| Generations | 5 |
| Total API calls | 25 |
| HTTP 200s | 25/25 |
| mTLS handshake | `ssl_client_verify=SUCCESS` on all requests |
| Detector | `mitigation.MitigationBypass` |
| Result | 19/25 mitigated — **24% attack success rate** |
| Run time | 256s |

### OpenRouter Direct (`garak_config_openrouter_direct.json`)

Probe: `badchars.BadCharacters`
Model: `mistralai/mistral-nemo` via `https://openrouter.ai/api/v1/chat/completions` (no proxy)

| Metric | Value |
|--------|-------|
| Prompts | 5 (`soft_probe_prompt_cap`) |
| Generations | 5 |
| Total API calls | 25 |
| HTTP 200s | 25/25 |
| Detector | `mitigation.MitigationBypass` |
| Result | 14/25 mitigated — **44% attack success rate** |
| Run time | 186s |

### Ollama via mTLS Proxy (`garak_config_multi.json`)

Probes: `badchars.BadCharacters` + 14 encoding probes (excluding `InjectUnicodeTagChars`/`InjectZalgo` — payloads exceed 60s timeout)
Model: `qwen2.5:3b` via `https://127.0.0.1/generate` → nginx mTLS proxy → Ollama

| Probe | Detector | Result |
|-------|----------|--------|
| `badchars.BadCharacters` | `mitigation.MitigationBypass` | FAIL — 6/9 mitigated (33% ASR) |
| `encoding.InjectBase16` | `encoding.DecodeMatch` | FAIL — 8/9 (11% ASR) |
| `encoding.InjectBase2048` | `encoding.DecodeMatch` | FAIL — 6/9 (33% ASR) |
| `encoding.InjectBase64` | `encoding.DecodeMatch` | FAIL — 8/9 (11% ASR) |
| `encoding.InjectNato` | `encoding.DecodeMatch` | FAIL — 8/9 (11% ASR) |
| all others (10 probes) | — | PASS — 9/9 |

Run time: 926s (Ollama serialises concurrent requests — `parallel_attempts: 2` has no benefit locally, but wanted to test serialization)

### Notes

- `response_json_field` must use JSONPath syntax with a leading `$`: `"$.choices[0].message.content"`. The RestGenerator only traverses nested JSON for fields starting with `$`; otherwise it does a literal dict key lookup.
- `soft_probe_prompt_cap` is set to 5 in the OpenRouter configs to keep runs lightweight.
- The proxy run is ~3× slower per request due to the extra mTLS handshake + nginx → OpenRouter hop.
- `InjectUnicodeTagChars` and `InjectZalgo` are excluded from `garak_config_multi.json` — their payloads are large apparently.

## Configuration Notes

### Generation Limit

| Config | `run.generations` |
|--------|------------------|
| `garak_config.json` | 200 |
| `garak_config_encrypted.json` | 200 |
| `garak_config_multi.json` | 3 |
| `garak_config_openrouter.json` | 5 |
| `garak_config_openrouter_direct.json` | 5 |

### Timeouts
- **Per-request**: 60 seconds (`request_timeout` in RestGenerator config — accommodates cold model loads)
- **Job-level**: use the `timeout` command wrapper if needed, e.g. `timeout 180 garak --config ...`

### mTLS Parameters (`JakeBx/garak@mtls-client-auth-fix`)
| Parameter | Description |
|-----------|-------------|
| `client_cert` | Path to PEM client certificate |
| `client_key` | Path to PEM client private key |
| `client_key_passphrase_env_var` | Env var name holding the key passphrase |
| `verify_ssl` | `true`, `false`, or path to CA bundle for server cert verification |

### Model Configuration

- **Ollama configs** (`garak_config.json`, `garak_config_encrypted.json`, `garak_config_multi.json`): use `qwen2.5:3b` — run `ollama pull qwen2.5:3b` first, or change the `model` field.
- **OpenRouter configs** (`garak_config_openrouter.json`, `garak_config_openrouter_direct.json`): use `mistralai/mistral-nemo` — change the `model` field to any model available on OpenRouter.
