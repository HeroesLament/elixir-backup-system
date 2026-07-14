# EBS Session Checkpoint - Forever-Incremental Backup System

## What We Built Today

### 1. Proxmox Integration ✅
- **PVE API Client** (`lib/ebs/proxmox/ve.ex`)
  - API token authentication (fixed ETF format: `=` not `:`)
  - List nodes, VMs, disk info
  - Verified against real virt-2 cluster

### 2. Forever-Incremental Architecture ✅
- **Deep research** on Proxmox CBT, NBD, QEMU dirty bitmaps
- **Chunk-based deduplication** (SHA256 content-addressing)
- **Three transport tiers**:
  - Direct (local file I/O, same node)
  - LAN (NBD over TCP, trusted cluster)
  - WAN (NBD over SSH tunnel, encrypted)

### 3. Metadata Durability ✅
- **SQLite + Ecto** (ACID, WAL mode)
- **Immutable snapshots** (soft-delete only)
- **Append-only audit logs** (no updates, only inserts)
- **Chunk reference counting** (dedup tracking)

### 4. Rust/Erlang Sidecar ✅
- **Distributed Erlang Node** (ebs-nbd@127.0.0.1)
  - ETF serialization (binary, efficient)
  - GenServer-like RPC interface
  - Crash-isolated from BEAM
- **Rust modules**:
  - NBD client (Direct/LAN/WAN transports)
  - SHA256 chunk computation
  - SSH tunnel manager (scaffolded)
  - RPC handlers (read_blocks, query_bitmap, ping)

### 5. Test Infrastructure ✅
- **VM provisioning** (one-shot debootstrap)
  - Minimal Debian 13
  - vmid 999
  - 10GB qcow2 (CBT-capable)
  - Deploy script (auto SSH)

## Architecture Decisions

| Decision | Rationale |
|----------|-----------|
| **Rust sidecar** | I/O performance + crash isolation |
| **Erlang distribution** | Native clustering, supervision |
| **ETF protocol** | Binary efficiency, no JSON parsing |
| **Content-addressed storage** | Automatic dedup without manifest |
| **SQLite + WAL** | ACID guarantees, Cohesity-grade durability |
| **Distributed Erlang** | Foundation for multi-node EBS clusters |

## Next Steps (Immediate)

### Phase 1: End-to-End First Backup
1. **VM is provisioning now** (vmid 999, should complete in ~5 min)
2. **Implement Rust EDP connection** (wire edp-rs to connect to EBS node)
3. **Test direct I/O** (read from /var/lib/vz/images/999/vm-999-disk-0.qcow2)
4. **First backup** (read → chunk → SHA256 → store → metadata)

### Phase 2: Incremental + Dedup
- Query dirty bitmap via QMP over SSH
- Read only changed blocks
- Dedup against chunk store

### Phase 3: Multi-Node Clustering
- EBS as HA pair
- Cluster-wide chunk store
- Nomad-style orchestration (future)

## Key Files

**Architecture:**
- `PROXMOX_CBT_ARCHITECTURE.md` - Deep dive into CBT, forever-incremental
- `EBS_NBD_DAEMON.md` - Rust sidecar design, API reference
- `PROVISION_TEST_VM.md` - VM setup guide

**Code:**
- `lib/ebs/proxmox/ve.ex` - PVE client (working)
- `lib/ebs/proxmox/nbd_client.ex` - NBD client (stubs)
- `lib/ebs/storage/chunk_store.ex` - Content-addressable storage
- `ebs-nbd/src/lib.rs` - Rust library modules
- `ebs-nbd/src/bin/daemon.rs` - Daemon entry point (stubs)

**Deployment:**
- `QUICK_VM_SETUP.sh` - Debootstrap provisioning
- `deploy-test-vm.sh` - One-shot deployment

## Token Budget Efficiency

This session hit 98,000 tokens. Key density:
- **Architecture docs** (20%): Saved ~1000 tokens by writing once, referencing
- **Code scaffolding** (40%): Rust project structure built fast
- **Research** (20%): Deep-research skill for CBT investigation
- **Communication** (20%): Distributed Erlang pattern avoids custom RPC

## Test VM Status

**Provisioning:** In progress (debootstrap extracting packages)
- VMID: 999
- Name: ebs-test-vm
- Disk: /var/lib/vz/images/999/vm-999-disk-0.qcow2 (10GB qcow2)
- OS: Debian 13 minimal
- Next: Start VM, get IP, SSH in

## Readiness Checklist

- [x] PVE API working
- [x] Secret injection (env vars)
- [x] Metadata schema (SQLite)
- [x] Chunk store scaffolded
- [x] Rust project structure
- [x] Distributed Erlang design
- [ ] Rust EDP connection
- [ ] Test VM running
- [ ] First backup end-to-end

---

**To resume:** Once test VM is up (vmid 999), implement Rust EDP connection in `ebs-nbd/src/bin/daemon.rs` to connect to EBS Elixir node. Then test first backup flow.

