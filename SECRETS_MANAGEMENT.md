# Secrets Management

EBS reads all secrets from environment variables at runtime. This allows multiple secret injection methods without code changes or recompilation.

## Supported Secret Injection Methods

### 1. obao CLI (Recommended for Development)

```bash
# Create a secret in obao
obao secret create pve-token "root@pam!ebs-backup:xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

# Run EBS with obao injecting secrets
obao exec -- iex -S mix
# obao injects PVE_TOKEN_SECRET and other secrets into environment
```

### 2. Environment Variables (Shell)

```bash
export PVE_HOST="virt-2.admin.siliconiq.com"
export PVE_PORT="8006"
export PVE_TOKEN_ID="root@pam!ebs-backup"
export PVE_TOKEN_SECRET="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

iex -S mix
```

### 3. .env File (Development Only)

```bash
# Copy example file
cp .env.example .env

# Edit with your secrets
vim .env

# Load from shell
source .env
iex -S mix
```

### 4. Concourse CI/CD

```yaml
jobs:
  - name: backup
    plan:
      - task: run-backup
        config:
          platform: linux
          image_resource:
            type: docker-image
            source:
              repository: elixir
          params:
            PVE_HOST: ((pve_host))
            PVE_TOKEN_ID: ((pve_token_id))
            PVE_TOKEN_SECRET: ((pve_token_secret))
            PBS_HOST: ((pbs_host))
            PBS_PASSWORD: ((pbs_password))
          run:
            path: bash
            args:
              - -c
              - |
                mix ecto.migrate
                mix run --no-halt
```

### 5. Kubernetes SecretSpec / Sealed Secrets

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: ebs-secrets
type: Opaque
stringData:
  PVE_HOST: virt-2.admin.siliconiq.com
  PVE_TOKEN_ID: root@pam!ebs-backup
  PVE_TOKEN_SECRET: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
---
apiVersion: v1
kind: Pod
metadata:
  name: ebs-backup
spec:
  containers:
  - name: ebs
    image: ebs:latest
    envFrom:
    - secretRef:
        name: ebs-secrets
```

## Required Secrets

### PVE (Proxmox Virtual Environment) - Required

```
PVE_HOST              - Proxmox host/IP
PVE_PORT              - Proxmox API port (default: 8006)
PVE_TOKEN_ID          - API token ID, format: "root@pam!token-name"
PVE_TOKEN_SECRET      - API token secret (64-char hex string)
```

### PBS (Proxmox Backup Server) - Optional

```
PBS_HOST              - PBS host/IP
PBS_PORT              - PBS API port (default: 8007)
PBS_USER              - PBS user (default: root@pam)
PBS_PASSWORD          - PBS password
```

### Storage - Required

```
BACKUP_STORAGE_TYPE   - "local" | "nfs" | "s3" (default: local)
BACKUP_STORAGE_PATH   - Path to backup directory (default: /mnt/backups)
```

### S3 (Cold Storage Tiering) - Optional

```
S3_ENDPOINT           - S3 endpoint URL
S3_BUCKET             - S3 bucket name
S3_ACCESS_KEY         - AWS access key
S3_SECRET_KEY         - AWS secret key
```

### Logging - Optional

```
LOG_LEVEL             - Logging level: debug | info | warn | error (default: info)
STRUCTURED_LOGGING    - "true" for JSON logs (default: false)
```

## Security Best Practices

1. **Never commit secrets to git** — `.env` and `.env.local` are gitignored
2. **Use API tokens, not passwords** — Tokens can be revoked and scoped
3. **Rotate tokens regularly** — Especially in production
4. **Use sealed secrets in Kubernetes** — Don't store plaintext in git
5. **Audit secret access** — Log who/when secrets are used
6. **Use obao in development** — Keeps secrets out of shell history

## Testing Without Real Secrets

For testing, you can set fake values:

```bash
export PVE_HOST="localhost"
export PVE_TOKEN_ID="test!token"
export PVE_TOKEN_SECRET="fake-secret-for-testing"
export BACKUP_STORAGE_PATH="/tmp/test-backups"

iex -S mix

# In IEx:
iex> config = Application.get_env(:ebs, :pve_config)
%{host: "localhost", port: 8006, token_id: "test!token", token_secret: "fake-secret-for-testing"}
```

## Runtime Loading

All secrets are loaded at app startup via `config/runtime.exs`:

```elixir
# In runtime.exs
pve_host = System.get_env("PVE_HOST")
pve_token_secret = System.get_env("PVE_TOKEN_SECRET")

config :ebs, :pve_config,
  host: pve_host,
  token_secret: pve_token_secret
```

This means secrets are read AFTER compilation but BEFORE the app starts, ensuring:
- Secrets never appear in compiled code
- Same compiled artifact works in dev/staging/prod with different secrets
- obao/Concourse/SecretSpec can inject secrets at runtime

---

**To use EBS with your Proxmox setup:**

```bash
# Option 1: obao (recommended)
obao secret create pve-token "root@pam!ebs-backup:your-secret-here"
obao exec -- iex -S mix

# Option 2: Shell env vars
export PVE_HOST="virt-2.admin.siliconiq.com"
export PVE_TOKEN_ID="root@pam!ebs-backup"
export PVE_TOKEN_SECRET="your-secret-here"
iex -S mix

# Option 3: .env file
cp .env.example .env
# Edit .env with your values
source .env
iex -S mix
```
