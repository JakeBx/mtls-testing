# mTLS Proxy Scaffold

Nginx-based mTLS termination proxy for testing LLM clients against mutual TLS. Generates a local CA, server cert, and client certs, then runs nginx in Docker to terminate mTLS and proxy upstream.

Two proxy routes are configured out of the box:
- `/generate` → Ollama on `localhost:11434`
- `/openrouter` → `openrouter.ai/api/v1/chat/completions` (API key injected by nginx at runtime)

## Project Structure

```
mtls-testing/
├── docker-compose.yml          # nginx mTLS proxy
├── nginx/
│   ├── nginx.conf              # mTLS termination → Ollama + OpenRouter
│   └── entrypoint.sh           # DNS fix (IPv4) + envsubst + nginx start
├── certs/
│   └── generate-certs.sh       # CA + server + client cert generation
├── garak/                      # garak RestGenerator mTLS tests — see garak/README.md
└── notes.md
```

## Setup

### 1. Generate certificates

```bash
chmod +x certs/generate-certs.sh
./certs/generate-certs.sh
```

Generates a local CA, server cert (SAN: `localhost`/`127.0.0.1`), plain client cert, and encrypted client cert (passphrase: `changeit`).

Use `--force` to regenerate: `./certs/generate-certs.sh --force`

### 2. Start the proxy

```bash
export OPENROUTER_API_KEY=<your-key>   # required for OpenRouter route
docker compose up -d
```

Nginx listens on `https://localhost:443` and terminates mTLS. Clients must present a certificate signed by `certs/ca.crt`.

### 3. Teardown

```bash
docker compose down
```

## Certificates

| File | Purpose |
|------|---------|
| `certs/ca.crt` | CA certificate — distribute to both sides |
| `certs/ca.key` | CA private key — keep secure |
| `certs/server.crt` / `server.key` | Server cert — mounted into nginx container |
| `certs/client.crt` / `client.key` | Plain client cert |
| `certs/client-encrypted.crt` / `client-encrypted.key` | Passphrase-protected client cert (`changeit`) |

## mTLS Parameters

All cert paths are relative to the directory where the client is invoked.

| Parameter | Description |
|-----------|-------------|
| CA bundle | `certs/ca.crt` — for server cert verification |
| Client cert | `certs/client.crt` |
| Client key | `certs/client.key` |
| Encrypted client key passphrase | `changeit` |

## Adding a new application

Create a subfolder (e.g. `myapp/`) with its own `README.md`, config files, and `environment.yml`. Point client cert paths at `../certs/` or use absolute paths. See [garak/README.md](garak/README.md) as a reference.
