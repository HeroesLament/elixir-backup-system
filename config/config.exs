import Config

# Configure EBS application
config :ebs,
  ecto_repos: [EBS.Repo]

# Configure Ecto/SQLite
config :ebs, EBS.Repo,
  database: Path.expand("../priv/ebs_dev.sqlite3", __DIR__),
  migration_primary_key: [type: :binary_id],
  migration_timestamps: [type: :utc_datetime_usec],
  # WAL mode: write-ahead logging for crash safety
  # This is critical for metadata durability
  pragmas: [
    journal_mode: :wal,
    foreign_keys: true,
    synchronous: :full  # Full fsync after each transaction (safest)
  ]

# Import environment specific config
import_config "#{config_env()}.exs"
