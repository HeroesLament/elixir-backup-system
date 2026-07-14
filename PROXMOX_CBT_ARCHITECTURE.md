# Proxmox Forever-Incremental CBT Architecture

## Control Plane: QMP over SSH

**Purpose:** Query dirty bitmaps, manage snapshots, get block status

**Implementation:**
```bash
ssh node -L 10809:localhost:10809 \
  "qemu-nbd -f qcow2 /path/to/disk.qcow2 --bitmap=incremental --listen=127.0.0.1:10809"
```

Then in Elixir, connect to `localhost:10809` over the SSH tunnel to query bitmap metadata.

**QMP Commands (via SSH):**
```bash
ssh node "virsh qemu-monitor-command --hmp vm-id 'query-dirty-bitmaps'"
ssh node "virsh qemu-monitor-command --json vm-id '{ \"execute\": \"query-dirty-bitmaps\" }'"
```

Returns:
```json
{
  "return": [
    {
      "name": "incremental",
      "count": 2048,          // dirty blocks
      "granularity": 65536,   // bytes per block
      "recording": true
    }
  ]
}
```

---

## Data Plane: Direct Network Transport

**Three-tier strategy based on bandwidth/latency:**

### 1. **Local (same node) — Direct file I/O**
- SSH tunnel is overkill
- Read `/var/lib/vz/images/{node}/{vmid}/vm-{vmid}-disk-*.qcow2` directly
- Fastest: no network overhead
- Use case: Single-machine backup

### 2. **LAN — NBD over direct TCP**
- No SSH tunnel needed
- QEMU exposes NBD on high-bandwidth port (e.g., 10809)
- Direct connection from EBS appliance
- Firewall rule: allow 10809 from backup appliance only
- Use case: Cluster within datacenter

### 3. **WAN — HTTPS/TLS NBD over SSH tunnel**
- SSH provides auth + encryption for QMP
- NBD data compressed (zstd) before tunnel
- Bandwidth-limited by SSH cipher (acceptable for DR)
- Use case: Remote sites, disaster recovery

---

## Architecture Decision Tree

```
                        ┌─────────────────────────────────────┐
                        │  Read Block Data from PVE VM        │
                        └──────────────┬──────────────────────┘
                                       │
                    ┌──────────────────┼──────────────────────┐
                    │                  │                      │
           ┌────────▼────────┐  ┌──────▼──────┐  ┌──────────▼────────┐
           │ Same Node       │  │ LAN (trusted)  │  │ WAN/Untrusted   │
           │ (EBS on PVE)    │  │ (cluster)      │  │ (remote site)   │
           └────────┬────────┘  └──────┬──────┘  └──────────┬────────┘
                    │                  │                    │
           ┌────────▼────────┐  ┌──────▼──────┐  ┌──────────▼────────┐
           │ Direct File I/O │  │ Direct NBD  │  │ NBD over SSH      │
           │ (qcow2 on disk) │  │ (unencrypted)  │  │ (encrypted/auth) │
           └────────┬────────┘  └──────┬──────┘  └──────────┬────────┘
                    │                  │                    │
           ┌────────▼────────┐  ┌──────▼──────┐  ┌──────────▼────────┐
           │ No latency      │  │ 1-10ms      │  │ 50-200ms          │
           │ Full bandwidth  │  │ ~1Gbps      │  │ ~10-100Mbps       │
           │ No auth needed  │  │ IP+firewall │  │ SSH key auth      │
           └─────────────────┘  └─────────────┘  └───────────────────┘
```

---

## Forever-Incremental Workflow

### First Backup (Full)

```
1. Snapshot VM
   └─ Freezes disk state at T0
   └─ Creates bitmap: name="incremental", count=0

2. Query Dirty Bitmap (via QMP over SSH)
   └─ Get granularity (65536 bytes typical)
   └─ Verify VM is qcow2 (bitmap-capable)

3. Start NBD Server
   └─ ssh node "qemu-nbd -f qcow2 /var/lib/vz/images/{vmid}/vm-{vmid}-disk-0.qcow2 --bitmap=incremental"

4. Connect Data Plane
   └─ If local:  Direct I/O to disk file
   └─ If LAN:    TCP connect to NBD port (10809)
   └─ If WAN:    SSH tunnel forward + NBD connect

5. Read All Blocks → Chunks
   └─ Read disk sequentially in 64KB blocks (match bitmap granularity)
   └─ SHA256 hash each block
   └─ Store to `/mnt/backups/chunks/{sha256-prefix}/{sha256}` (content-addressable)

6. Snapshot Metadata
   └─ SQLite: INSERT snapshots(
        snapshot_id, vm_id, timestamp, chunks[], total_size, 
        bitmap_state, checkpoint_hash, status='completed'
      )
   └─ Audit log: 'backup_full_completed'
   └─ Snapshot is immutable (soft-delete only)

7. Stop NBD Server
   └─ Bitmap persists (qcow2 only)
   └─ Next backup can reference dirty blocks since T0
```

### Subsequent Backups (Incremental)

```
1. Query Dirty Bitmap (via QMP over SSH)
   └─ Returns: count=512 (512 * 65KB = 33MB changed)
   └─ Granularity: 65536 bytes
   └─ Bitmap name: "incremental"

2. Map Bitmap to Block Ranges
   └─ Dirty bitmap tells which 64KB regions changed
   └─ Read ONLY those ranges (not whole disk)

3. Read Changed Blocks → Chunks
   └─ For each dirty 64KB:
      ├─ Read from NBD
      ├─ SHA256 hash
      ├─ Check if chunk already exists in chunk store
      └─ If new: store to `/mnt/backups/chunks/{sha256-prefix}/{sha256}`
         If exists: dedup (just reference)

4. Snapshot Metadata
   └─ SQLite: INSERT snapshots(
        snapshot_id, vm_id, timestamp, 
        chunks=[{sha256, offset, size}, ...], 
        changed_count=512, dedup_savings='2.1GB'
        status='completed'
      )
   └─ Audit: 'backup_incremental_completed', details: '512 blocks, 33MB changed, 2.1GB dedup'

5. Mark Bitmap
   └─ Reset bitmap for next cycle (QMP: block-dirty-bitmap-clear)
   └─ Or: keep cumulative (depends on retention strategy)
```

---

## Chunk Store Architecture

### Storage Layout

```
/mnt/backups/
├── chunks/                    # Content-addressable storage
│   ├── 0a/                   # Prefix (first 2 chars of SHA256)
│   │   ├── 0a1b2c3d...       # Chunk file (full SHA256 = name)
│   │   └── 0a9e8f7d...
│   ├── 1f/
│   │   ├── 1f2a3b4c...
│   │   └── 1f9d8c7b...
│   └── ...
├── snapshots.sqlite3         # Metadata
├── audit.log                 # Immutable append-only
└── gc_manifest.json          # Garbage collection
```

### Chunk Metadata (in SQLite)

```sql
CREATE TABLE chunks (
  id BINARY PRIMARY KEY,
  sha256 CHAR(64) UNIQUE NOT NULL,
  size INTEGER NOT NULL,
  compression TEXT,           -- 'none', 'zstd', 'lz4'
  tier TEXT DEFAULT 'hot',    -- 'hot', 'warm', 'cold'
  created_at DATETIME,
  last_referenced_at DATETIME,
  reference_count INTEGER DEFAULT 1,
  checksum_verified BOOLEAN DEFAULT FALSE
);

CREATE TABLE snapshot_chunks (
  snapshot_id BINARY NOT NULL,
  chunk_id BINARY NOT NULL,
  offset INTEGER,             -- Position in reconstructed disk
  size INTEGER,
  PRIMARY KEY (snapshot_id, chunk_id),
  FOREIGN KEY (snapshot_id) REFERENCES snapshots(id),
  FOREIGN KEY (chunk_id) REFERENCES chunks(id)
);
```

---

## Deduplication Strategy

### Across Snapshots (Same VM)

```
Time T0: Full backup
├─ Block 0x0000: hash=SHA256_A (size 65KB)
├─ Block 0x1000: hash=SHA256_B (size 65KB)
└─ Block 0x2000: hash=SHA256_C (size 65KB)

Time T1: Incremental (only block 1 changed)
├─ Block 0x0000: hash=SHA256_A ✓ SAME (reference existing chunk)
├─ Block 0x1000: hash=SHA256_D (NEW)
└─ Block 0x2000: hash=SHA256_C ✓ SAME (reference existing chunk)

Storage used:
├─ Snapshot_T0: [SHA256_A, SHA256_B, SHA256_C]  = 195KB
├─ Snapshot_T1: [SHA256_A, SHA256_D, SHA256_C]  = 0KB (refs only)
└─ Unique chunks on disk: 4 chunks × 65KB = 260KB (not 390KB)
```

### Across VMs (Cluster-wide Deduplication)

If two VMs have identical blocks:
```
VM#100:
├─ Disk 0: Block X = SHA256_DEADBEEF

VM#101:
├─ Disk 0: Block Y = SHA256_DEADBEEF (same content, different position)

Cluster storage: 1 copy of chunk SHA256_DEADBEEF
Both snapshots reference it
```

---

## Bitmap Lifecycle & Limitations

### qcow2 (Recommended)

```
✓ Persistent bitmap across VM restart
✓ Bitmap survives QEMU crash + restart
✓ Supports multiple named bitmaps
✓ Can query dirty state via QMP
✓ Use for incremental strategy

Limitation: Disk format must be qcow2 (not RAW)
```

### RAW & VMDK

```
✗ Bitmap LOST on VM shutdown
✗ Must do full backup after restart
✗ Use only if VM never restarts

Recommendation: Migrate to qcow2 for CBT support
```

---

## Restore Path

### Reconstruct from Forever-Incremental Chain

Instead of replaying 50 incremental backups, reconstruct disk in **one pass**:

```
SELECT chunk_id, offset, size FROM snapshot_chunks
WHERE snapshot_id = 'backup-vm100-2026-07-14'
ORDER BY offset ASC;

Result:
┌──────────────────────────┬────────┬──────┐
│ chunk_id (SHA256)        │ offset │ size │
├──────────────────────────┼────────┼──────┤
│ 0a1b2c3d...              │ 0x0000 │ 65K  │
│ 1f2a3b4c...              │ 0x1000 │ 65K  │
│ 0a1b2c3d...              │ 0x2000 │ 65K  │ (same chunk, different position)
│ 9e8f7d6c...              │ 0x3000 │ 65K  │
└──────────────────────────┴────────┴──────┘

Restore process:
1. Open destination disk
2. Seek to offset 0x0000, write chunk 0a1b2c3d...
3. Seek to offset 0x1000, write chunk 1f2a3b4c...
4. Seek to offset 0x2000, write chunk 0a1b2c3d... (same, already on disk)
5. Seek to offset 0x3000, write chunk 9e8f7d6c...
```

**Result:** O(1) restore time from any backup in the chain, no replay.

---

## Implementation Roadmap

### Phase 1 (MVP): Snapshot-Based Full

- [x] PVE client authentication
- [ ] SSH tunnel for QMP queries
- [ ] NBD direct file I/O (local)
- [ ] Read full disk → chunks
- [ ] SHA256 content-addressing
- [ ] SQLite snapshot metadata
- [ ] Restore from single backup

### Phase 2: True Incremental + Dedup

- [ ] Query dirty bitmap via QMP
- [ ] Read only changed blocks
- [ ] Dedup across snapshots
- [ ] Chunk reference counting
- [ ] Restore from incremental chain

### Phase 3: Multi-VM + Cluster Dedup

- [ ] Cluster-wide chunk store
- [ ] Cross-VM deduplication
- [ ] Garbage collection
- [ ] Chunk verification (bit-rot detection)

### Phase 4: Tiering

- [ ] Hot (local) → Warm (NFS) → Cold (S3)
- [ ] Automatic migration based on age/access
- [ ] Restore from cold (decompress + reconstruct)

---

## Key Design Decisions

1. **Content-addressable storage (SHA256):** Enables dedup without central index
2. **Immutable snapshots:** Soft-delete only (audit trail)
3. **Chunk-level granularity:** 64KB (matches bitmap), not full files
4. **Metadata-driven restore:** Query once, reconstruct in parallel
5. **Forever-incremental:** No full backup cycles needed after first backup

---

## Comparison: EBS vs Cohesity

| Feature | Cohesity | EBS (Target) |
|---------|----------|--------------|
| CBT | ✓ (proprietary) | ✓ (QEMU native) |
| Chunk dedup | ✓ (cluster-wide) | ✓ (filesystem-wide) |
| Forever-incremental | ✓ | ✓ |
| Metadata index | ✓ (in-memory) | ✓ (SQLite) |
| Restore speed | O(1) from any backup | O(1) from any backup |
| Cost | 7-figure licensing | Open source |

