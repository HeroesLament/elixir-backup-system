import Config

# Production config
config :logger, level: :info

# Production database: use full fsync for durability
config :ebs, EBS.Repo,
  database: "/var/lib/ebs/backups.sqlite3",
  pragmas: [
    journal_mode: :wal,
    foreign_keys: true,
    synchronous: :full,
    wal_autocheckpoint: 1000  # Checkpoint every 1000 pages
  ]
