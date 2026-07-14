import Config

# Load all configuration from environment at runtime.
# This allows secrets to be injected via obao, Concourse, SecretSpec, etc.
# without requiring code changes or recompilation.

# PVE (Proxmox Virtual Environment) Configuration
pve_host = System.get_env("PVE_HOST") || "localhost"
pve_port = System.get_env("PVE_PORT", "8006") |> String.to_integer()
pve_token_id = System.get_env("PVE_TOKEN_ID") || "root@pam!ebs-token"
pve_token_secret = System.get_env("PVE_TOKEN_SECRET")

config :ebs, :pve_config,
  host: pve_host,
  port: pve_port,
  token_id: pve_token_id,
  token_secret: pve_token_secret

# PBS (Proxmox Backup Server) Configuration
pbs_host = System.get_env("PBS_HOST") || "localhost"
pbs_port = System.get_env("PBS_PORT", "8007") |> String.to_integer()
pbs_user = System.get_env("PBS_USER") || "root@pam"
pbs_password = System.get_env("PBS_PASSWORD")

config :ebs, :pbs_config,
  host: pbs_host,
  port: pbs_port,
  user: pbs_user,
  password: pbs_password

# Storage Configuration
backup_storage_type = System.get_env("BACKUP_STORAGE_TYPE", "local")
backup_storage_path = System.get_env("BACKUP_STORAGE_PATH", "/mnt/backups")

config :ebs, :storage,
  type: backup_storage_type,
  path: backup_storage_path

# S3 Configuration (for cold storage tiering)
s3_endpoint = System.get_env("S3_ENDPOINT")
s3_bucket = System.get_env("S3_BUCKET")
s3_access_key = System.get_env("S3_ACCESS_KEY")
s3_secret_key = System.get_env("S3_SECRET_KEY")

config :ebs, :s3,
  endpoint: s3_endpoint,
  bucket: s3_bucket,
  access_key: s3_access_key,
  secret_key: s3_secret_key

# Database Configuration
db_path = System.get_env("EBS_DB_PATH", Path.expand("../priv/ebs.sqlite3", __DIR__))

config :ebs, EBS.Repo,
  database: db_path,
  migration_primary_key: [type: :binary_id],
  migration_timestamps: [type: :utc_datetime_usec],
  pragmas: [
    journal_mode: :wal,
    foreign_keys: true,
    synchronous: :full
  ]

# Logging
log_level = System.get_env("LOG_LEVEL", "info") |> String.to_atom()

config :logger,
  level: log_level

# Log structured JSON in production
if System.get_env("STRUCTURED_LOGGING") == "true" do
  config :logger,
    backends: [{:logger_json, :json}]
end
