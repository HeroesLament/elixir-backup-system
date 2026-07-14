# Elixir Backup System (EBS)

A hyperconverged, Elixir-native backup engine inspired by Cohesity and Rubrik—but built for speed, extensibility, and home lab simplicity.

**Status:** Foundation phase. Core architecture in place. Ready for implementation.

## Why Elixir?

- **Concurrency**: OTP's supervisor trees handle thousands of concurrent block operations
- **Fault tolerance**: Automatic recovery without manual intervention
- **Hot reloading**: Deploy policy changes without stopping backups
- **Message passing**: Simple event-driven architecture between backup components

## Architecture

### Core Components

- **BlockPool**: Content-addressable deduplication engine. Hash → block. Deduplicates globally across all VMs and snapshots.
- **CBTMonitor**: Polls Proxmox for changed blocks via Changed Block Tracking (CBT)
- **Backup.Scheduler**: Dispatches backup jobs with concurrency control
- **Backup.Job**: Per-backup-run process. Reads blocks, deduplicates, publishes completion
- **Policy.Engine**: Retention and tiering automation
- **Restore.Reconstructor**: Reassemble blocks into consistent snapshots
- **Events**: Pub/sub event bus for inter-component communication

### Data Flow

```
CBTMonitor → Events → Scheduler → Job → BlockPool → Storage Backend
                                                    → (local/S3/NFS)
                      ↓
                Policy.Engine (retention, tiering)
                      ↓
            Restore.Reconstructor (on-demand)
```

## Getting Started

### Prerequisites

- Elixir 1.14+
- Debian 13 (target OS)
- Proxmox VE with CBT support
- ~2GB RAM, 10GB+ storage for backups

### Development

```bash
git clone https://github.com/HeroesLament/elixir-backup-system.git
cd elixir-backup-system
mix deps.get
mix compile
iex -S mix
```

Test the foundation:

```elixir
# Hash utility
EBS.Util.Hash.sha256("hello")

# Event bus
EBS.Events.subscribe(:test)
EBS.Events.publish(:test, %{data: "hello"})

# BlockPool deduplication
{:ok, hash1} = EBS.Storage.BlockPool.store("block content")
{:ok, hash2} = EBS.Storage.BlockPool.store("block content")
# hash1 == hash2 (deduplicated!)

# Stats
EBS.Storage.BlockPool.stats()
```

## Next Steps (Priority)

### Phase 1: End-to-End Backup Flow
1. Implement real Proxmox API client (auth, CBT queries, block reads)
2. Wire up CBTMonitor → Scheduler → Job → BlockPool
3. Test single-VM backup and deduplication

### Phase 2: Persistence
4. Implement local filesystem storage backend
5. Add snapshot metadata to SQLite (Ecto)
6. Test restore from backup

### Phase 3: Automation
7. Build Policy DSL for retention/tiering rules
8. Implement S3 cold storage tiering
9. Garbage collection for unreferenced blocks

### Phase 4: Ops
10. Create Phoenix web dashboard
11. Add monitoring and alerting
12. Systemd service file for Debian deployment

See `SETUP_AND_NEXT_STEPS.md` for detailed implementation guide.

## Design Decisions

- **Block size**: 4KB (hypervisor-aligned)
- **Dedup scope**: Global (across all VMs, all snapshots)
- **Immutability**: Policy-based retention windows
- **Concurrency**: 4 parallel jobs (configurable)
- **Metadata**: SQLite (Ecto) for simplicity, migrate to Postgres if needed

## Architecture Reference

```
┌──────────────────────────────────────┐
│ EBS.Application (OTP Supervisor)     │
├──────────────────────────────────────┤
│                                      │
│  CBTMonitor → Events ← Scheduler     │
│                         ↓            │
│                       Job → BlockPool│
│                              ↓       │
│                    Storage Backend   │
│                  (local/S3/NFS)      │
│                                      │
│  Policy.Engine (retention/tiering)   │
│  Restore.Reconstructor (recovery)    │
│                                      │
└──────────────────────────────────────┘
```

## Contributing

This is a personal project for now, but PRs welcome. Feedback on architecture and design very appreciated.

## License

MIT (TBD - decide when feature-complete)

---

**Goal:** Make Cohesity sweat. 🚀
