# EBS NBD Daemon - Rust/Erlang Sidecar Architecture

## Overview

The NBD daemon runs as a **crash-isolated Rust/Tokio sidecar process** communicating with EBS (Elixir) via **Erlang Distribution Protocol (EDP) + ETF serialization**.

This architecture provides:
- **Crash isolation**: If daemon dies, EBS continues running (supervisor restarts it)
- **Binary efficiency**: ETF is compact native Erlang serialization (no JSON overhead)
- **GenServer-like API**: Standard Erlang RPC patterns familiar to Elixir developers
- **Distributed Erlang**: Foundation for multi-node EBS clusters (future)

---

## Architecture

```
┌─────────────────────────────────────────────┐
│    EBS (Elixir/OTP)                         │
│    ┌────────────────────────────────────┐   │
│    │ EBS.NBD.DistributedNode            │   │
│    │ ├─ Supervise ebs-nbd-daemon        │   │
│    │ └─ RPC calls to Rust node          │   │
│    └──────────────────────────────────────┘   │
│                    ↓                          │
│    Erlang Distribution Protocol (EDP)        │
│    + ETF serialization                       │
│                    ↓                          │
└─────────────────────────────────────────────┘

┌─────────────────────────────────────────────┐
│    ebs-nbd-daemon (Rust/Tokio)              │
│    ┌────────────────────────────────────┐   │
│    │ EDP Node: ebs-nbd@127.0.0.1        │   │
│    │ ├─ Tokio async runtime             │   │
│    │ ├─ RPC handlers (read_blocks, ...) │   │
│    │ ├─ NBD client (direct/LAN/WAN)     │   │
│    │ ├─ SSH tunnel mgmt (for QMP)       │   │
│    │ └─ SHA256 chunk computation        │   │
│    └────────────────────────────────────┘   │
│                    ↓                         │
│    Network I/O:                              │
│    - Direct: /var/lib/vz/images/*.qcow2    │
│    - LAN: NBD over TCP                     │
│    - WAN: NBD over SSH tunnel              │
└─────────────────────────────────────────────┘
```

---

## Communication Protocol

### Elixir → Rust: RPC Call

```elixir
# In Elixir
{:ok, chunks} = :rpc.call(
  :"ebs-nbd@127.0.0.1",
  EbsNBD,                    # Rust module name
  :read_blocks,              # Function
  ["virt-2", 100, "0", 0, 65536],  # Arguments
  60_000                     # Timeout (ms)
)
```

**Over the wire (EDP/ETF):**
```
{call, ebs@127.0.0.1, EbsNBD, read_blocks,
  ["virt-2", 100, "0", 0, 65536]}
```

### Rust → Elixir: Response

```rust
// In Rust (ebs-nbd-daemon)
pub async fn read_blocks(
    node: String,
    vmid: u32,
    disk: String,
    offset: u64,
    size: u64,
) -> Result<Vec<Chunk>> {
    // Read block, compute SHA256, return
    Ok(vec![
        Chunk { sha256: "abc123...", offset: 0, size: 65536, data: [...] },
    ])
}
```

**Over the wire (EDP/ETF):**
```
{reply, ebs@127.0.0.1,
  {ok, [{chunk, "abc123...", 0, 65536, <<...>>}]}}
```

---

## API Reference

### RPC Methods

All methods are called via `:rpc.call(:"ebs-nbd@127.0.0.1", EbsNBD, method, args, timeout)`

#### `read_blocks(node, vmid, disk, offset, size)`

Read a block range from a VM disk.

**Args:**
- `node`: Proxmox node name (string, e.g., "virt-2")
- `vmid`: VM ID (integer, e.g., 100)
- `disk`: Disk identifier (string, e.g., "0")
- `offset`: Starting byte offset (integer)
- `size`: Number of bytes to read (integer)

**Returns:**
```
{:ok, [%{sha256: "abc123...", offset: 0, size: 65536, data: <<...>>}]}
{:error, "reason"}
```

#### `query_bitmap(node, vmid, disk)`

Query dirty bitmap for changed blocks (qcow2 only, requires WAN/SSH).

**Args:**
- `node`: Proxmox node name
- `vmid`: VM ID
- `disk`: Disk identifier

**Returns:**
```
{:ok, [{offset, size}, {offset, size}, ...]}
{:error, "reason"}
```

#### `ping()`

Health check.

**Returns:**
```
{:ok, "pong"}
{:error, "reason"}
```

---

## Transport Modes

### Direct (Same Node)

Used when EBS daemon runs on the same Proxmox node.

```
EBS → File I/O → /var/lib/vz/images/{vmid}/vm-{vmid}-{disk}.qcow2
```

**Pros:**
- Zero network overhead
- Full disk bandwidth
- No auth needed

**Cons:**
- Only works on same node

### LAN (Cluster)

Used within trusted LAN (e.g., datacenter cluster).

```
EBS → NBD over TCP → Proxmox node:10809 → VM disk
```

**Pros:**
- Works across cluster
- No SSH overhead
- High bandwidth (~1Gbps)

**Cons:**
- Requires firewall rule
- No encryption

### WAN (Remote Sites)

Used for remote disaster recovery, encrypted channel.

```
EBS → SSH tunnel → Proxmox node → NBD server → VM disk
```

**Pros:**
- Encrypted (SSH)
- Authenticated (SSH key)
- Firewall-friendly (just SSH port)

**Cons:**
- Lower bandwidth (limited by SSH cipher)
- SSH tunnel overhead

**Also supports:**
- QMP over SSH for dirty bitmap queries
- Compression (zstd) of NBD data before tunnel

---

## Transport Detection

Currently hardcoded to `:Direct` in RPC handler. Should auto-detect based on:

1. If `node` == `hostname()` → Direct
2. If `node` in same LAN → LAN
3. Otherwise → WAN (via SSH)

Can also be parameterized per backup job.

---

## Building & Running

### Build Rust daemon

```bash
cd ebs-nbd
cargo build --release
# Binary: target/release/ebs-nbd-daemon
```

### Install daemon

```bash
sudo cp target/release/ebs-nbd-daemon /usr/local/bin/
chmod +x /usr/local/bin/ebs-nbd-daemon
```

### Start daemon manually

```bash
# Terminal 1: EBS node
iex --sname ebs@127.0.0.1 -S mix

# Terminal 2: NBD daemon
ebs-nbd-daemon
# Should connect and print: "EBS NBD Daemon running"

# Terminal 3: Test
iex --sname test@127.0.0.1 -r "IO.inspect :rpc.call(:'ebs-nbd@127.0.0.1', EbsNBD, :ping, [], 10000)"
# Output: {:ok, "pong"}
```

### Start daemon via systemd (production)

```ini
# /etc/systemd/system/ebs-nbd-daemon.service

[Unit]
Description=EBS NBD Daemon
After=network.target
Wants=ebs.service

[Service]
Type=simple
ExecStart=/usr/local/bin/ebs-nbd-daemon
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

---

## Dependencies (Rust)

- `edp-rs` - Erlang Distribution Protocol
- `erltf` - ETF encoding/decoding
- `tokio` - Async runtime
- `nbd` - NBD protocol (client, for future LAN/WAN)
- `sha2` - SHA256 hashing
- `ssh2` - SSH tunneling (future)
- `tracing` - Structured logging

---

## Future Work

### Phase 1 (MVP)
- [x] Scaffold Rust project with edp-rs + ETF
- [ ] Implement direct file I/O (read_blocks)
- [ ] Test with real Proxmox VM
- [ ] Integrate with EBS backup agent

### Phase 2
- [ ] Implement LAN NBD (TCP transport)
- [ ] Implement WAN NBD (SSH tunnel + compression)
- [ ] Query dirty bitmap via QMP over SSH

### Phase 3
- [ ] Parallel block reads (multiple threads)
- [ ] Streaming chunks (don't buffer all in memory)
- [ ] Connection pooling (reuse NBD connections)

---

## Troubleshooting

### Daemon doesn't connect

```bash
# Check if daemon started
ps aux | grep ebs-nbd-daemon

# Check logs
journalctl -u ebs-nbd-daemon -f

# Test manually
ebs-nbd-daemon
# Should print: "EBS NBD Daemon starting" and then wait
```

### RPC calls timeout

```elixir
# Check if daemon is responding
EBS.NBD.DistributedNode.ping()

# If timeout, daemon may be hanging
# Kill and restart
:os.cmd("pkill ebs-nbd-daemon")
# Then restart via systemd or manually
```

### "Disk file not found"

```bash
# Verify disk path is correct
ls -la /var/lib/vz/images/{vmid}/vm-{vmid}-{disk}.qcow2

# If running on different node, use WAN transport
# (requires SSH + QMP support)
```

---

## Performance Considerations

### Memory

- Direct file I/O: ~65KB per read (chunk size)
- LAN NBD: Same
- WAN NBD: Same (but with compression on wire)

### Throughput

- Direct: Full disk speed (depends on storage backend)
- LAN: ~1Gbps (100MB/s typical)
- WAN: 10-100Mbps (SSH limited)

### Latency

- Direct: <1ms
- LAN: 1-10ms
- WAN: 50-200ms (SSH overhead)

---

## Security

### Authentication

- Erlang distribution uses shared cookie (`ebs_nbd_secret`)
- SSH uses key-based auth (for WAN transport)

### Encryption

- EDP: Only authenticated, not encrypted (local network assumed)
- WAN: SSH provides encryption

### Future

- Enable EDP encryption (via TLS)
- Support SSH agent for daemon key management

