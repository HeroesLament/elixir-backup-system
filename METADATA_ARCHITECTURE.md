# EBS Metadata Architecture - Cohesity-Grade Rock Solid

## Philosophy

**Metadata is the source of truth.** If metadata is wrong, your entire backup system is compromised. We build metadata handling with the same rigor Cohesity uses:

- **Immutability**: Snapshots never change once created
- **Durability**: ACID transactions, WAL mode, full fsync
- **Auditability**: Every operation is logged
- **Integrity**: Referential constraints, checksums, validation
- **Consistency**: Single-threaded access via Ecto, no races

## Storage Architecture

### SQLite + Ecto (Primary)

**Why SQLite?**
- ACID guarantees (all-or-nothing writes)
- WAL mode (write-ahead logging) = crash-safe
- Foreign keys = referential integrity
- Transactions = atomicity
- No separate server to manage

**SQLite Configuration (Production):**
```
journal_mode: :wal           # Write-ahead logging
foreign_keys: true           # Enforce constraints
synchronous: :full           # Full fsync after each transaction
wal_autocheckpoint: 1000     # Checkpoint every 1000 pages
```

This is the opposite of "fast but risky". We trade speed for safety on metadata writes. The backup data goes to S3/NFS; metadata goes to this hardened SQLite.

### Tables

#### `snapshots` (Immutable)
Every backup is an immutable record. Once created, it never changes (except for allowed tier/status updates).

```
snapshot_id:      "vm-100/2026-01-15T10:00:00Z" (unique key)
datastore:        "local" (where the backup lives)
backup_group:     "vm-100" (for organizing)
vm_id:            "100" (the source VM)
chunks:           [{hash, size, offset}, ...] (block-level refs)
total_size:       536870912 (bytes)
content_checksum: SHA256 of all chunks
status:           "pending" | "completed" | "failed" | "verified"
tier:             "hot" | "warm" | "cold"
created_at:       2026-01-15T10:00:00Z
backup_timestamp: 2026-01-15T10:00:00Z (VM state at this time)
incremental_from: "vm-100/2026-01-14T10:00:00Z" (if incremental)
```

**Allowed updates** (rare):
- `status`: pending → completed/verified/failed
- `tier`: hot → warm → cold (tiering)
- `cold_location`: where it lives in cold storage
- `deleted_at`: soft delete marker

**Forbidden updates** (enforced):
- Any field that defines the content (chunks, checksum, size, etc)
- Source/timestamp information
- Encryption/compression settings

#### `audit_logs` (Append-Only)
Every operation is logged. Logs are never modified, only appended.

```
action:      "snapshot_created" | "snapshot_verified" | "snapshot_tiered" | "snapshot_deleted"
snapshot_id: Which snapshot
datastore:   Which datastore
actor:       "system" | "user:mac" | "api-key:xxx"
result:      "success" | "failure"
details:     JSON with action-specific info
error_message: If failed, why
inserted_at: When it happened
```

**Use cases:**
- "Show me the entire history of this snapshot"
- "Who changed this snapshot and when?"
- "Why did the backup fail?"
- "Compliance audit: prove we didn't delete this backup"

#### `backup_groups`
Organizational metadata - groups related snapshots.

```
backup_group_id:  "vm-100"
datastore:        "local"
vm_type:          "qemu" | "lxc" | "file"
created_at:       When the first snapshot was created
```

#### `integrity_checks`
Periodic verification results (for detecting bit rot, corruption).

```
snapshot_id:       Which snapshot we verified
status:            "pass" | "fail"
checksum_match:    Does content_checksum still match?
chunk_verification: How many chunks verified OK
checked_at:        When
```

## Operational Guarantees

### Atomicity
**Problem**: Backup completes, but metadata write crashes before checkpoint.

**Solution**: Ecto transactions. Either metadata AND audit log are written together, or neither is.

```elixir
Repo.transaction(fn ->
  {:ok, snapshot} = Repo.insert(snapshot_changeset)
  {:ok, _log} = Repo.insert(audit_log_changeset)
  {:ok, snapshot}
end)
# If anything fails, BOTH are rolled back
```

### Durability
**Problem**: Server crashes after write() returns but before data hits disk.

**Solution**: SQLite WAL + synchronous=full.
- Every transaction waits for fsync() to complete
- Write-ahead log guarantees recovery on restart

### Immutability
**Problem**: Someone accidentally updates a snapshot's checksum, corrupting the record.

**Solution**: Ecto schema constraints + database constraints.
- Changeset validation prevents invalid updates
- Most fields have no update logic (only insert)
- Attempts to update immutable fields fail early

### Auditability
**Problem**: We don't know what happened to a backup.

**Solution**: Every operation logs to audit_logs.
- Snapshot created? → log
- Snapshot verified? → log
- Snapshot tiered? → log
- Snapshot failed? → log with error_message
- Can reconstruct entire lifecycle

### Integrity
**Problem**: Referential chaos - snapshot references chunks that don't exist.

**Solution**: SQLite foreign keys.
- If a backup group is deleted, dependent snapshots fail
- Database enforces constraints

## API

### Create a Snapshot
```elixir
EBS.Metadata.Service.record_snapshot(%{
  snapshot_id: "vm-100/2026-01-15T10:00:00Z",
  datastore: "local",
  backup_group: "vm-100",
  vm_id: "100",
  vm_type: "qemu",
  chunks: [
    %{hash: "abc123", size: 4194304, offset: 0},
    %{hash: "def456", size: 4194304, offset: 4194304}
  ],
  total_size: 8388608,
  content_checksum: "xyz789...",
  chunk_count: 2,
  created_at: DateTime.utc_now(),
  backup_timestamp: DateTime.utc_now(),
  retention_days: 30,
  source_type: "proxmox-cbt",
  source_path: "pve/qemu/100",
  status: "completed"
}, actor: "system")
```

### Get Previous Snapshot (for incremental)
```elixir
previous = EBS.Metadata.Service.get_previous_snapshot("vm-100", "local")
# Returns last completed snapshot or nil
```

### Verify a Snapshot
```elixir
EBS.Metadata.Service.verify_snapshot(
  "vm-100/2026-01-15T10:00:00Z",
  verification_checksum,
  actor: "system"
)
```

### Tier to Cold Storage
```elixir
EBS.Metadata.Service.tier_to_cold(
  "vm-100/2026-01-15T10:00:00Z",
  "s3://archive/2026/01/vm-100-20260115.tar",
  actor: "system"
)
```

### Get Audit Trail
```elixir
logs = EBS.Metadata.Service.audit_history("vm-100/2026-01-15T10:00:00Z")
# Returns all operations on this snapshot
```

## Why This Matters

### Traditional Backup Software
- Metadata in plaintext config files (fragile)
- No audit trail (compliance nightmare)
- Updates allowed anywhere (data corruption risk)
- Crash during write = corrupted metadata

### Cohesity
- Metadata in hardened database
- Every operation logged
- Snapshots immutable after creation
- ACID guarantees

### EBS (Now)
- SQLite with WAL (Cohesity-grade durability)
- Append-only audit logs (compliance-ready)
- Immutable snapshots (corruption prevention)
- Ecto validation (data integrity)

## Scaling Path

**Today**: SQLite (single machine, 1M+ snapshots is fine)
**Tomorrow**: Migrate to PostgreSQL (same Ecto code, just change config)
**Future**: Distributed metadata (Consul, etcd)

## Testing

Every metadata operation has tests that verify:
1. Valid data is recorded correctly
2. Invalid data is rejected
3. Immutability constraints work
4. Audit logs are created
5. Transactions roll back on error

---

**This is how you build backup systems that don't lose data.**
