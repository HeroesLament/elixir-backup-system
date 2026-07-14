/// EBS NBD Daemon - Distributed Erlang Node
///
/// Runs as a separate Tokio sidecar process, communicating with EBS (Elixir)
/// via Erlang Distribution Protocol (EDP) + ETF serialization.
///
/// Exposes GenServer-like RPC interface:
///   - read_blocks(node, vmid, disk, offset, size) -> {:ok, chunks} | {:error, reason}
///   - query_bitmap(node, vmid, disk) -> {:ok, bitmap} | {:error, reason}

use anyhow::Result;
use tracing::{info, error, debug};

#[tokio::main]
async fn main() -> Result<()> {
    // Initialize logging
    tracing_subscriber::fmt()
        .with_max_level(tracing::Level::DEBUG)
        .init();

    info!("EBS NBD Daemon starting");

    // TODO: Initialize EDP node
    // let mut node = Node::new("ebs-nbd", "127.0.0.1:9999")?;
    // node.connect("ebs", "127.0.0.1:9998").await?;

    // TODO: Register RPC handlers
    // node.register_handler("read_blocks", handle_read_blocks);
    // node.register_handler("query_bitmap", handle_query_bitmap);

    // TODO: Run node
    // node.run().await?;

    info!("EBS NBD Daemon running");

    // Keep alive
    tokio::signal::ctrl_c().await?;
    info!("EBS NBD Daemon shutting down");

    Ok(())
}

/// Handle read_blocks RPC call from Elixir
///
/// Args: [node, vmid, disk, offset, size]
/// Returns: {:ok, chunks} where chunks = [{sha256, offset, size, data}, ...]
async fn handle_read_blocks(
    node: String,
    vmid: u32,
    disk: String,
    offset: u64,
    size: u64,
) -> Result<()> {
    debug!("read_blocks: node={}, vmid={}, disk={}, offset={}, size={}",
        node, vmid, disk, offset, size);

    // TODO: Implement NBD reading
    // 1. Connect to Proxmox NBD server (via SSH tunnel if needed)
    // 2. Read blocks
    // 3. Compute SHA256 chunks
    // 4. Return via EDP

    Ok(())
}

/// Handle query_bitmap RPC call from Elixir
///
/// Args: [node, vmid, disk]
/// Returns: {:ok, bitmap} or {:error, reason}
async fn handle_query_bitmap(
    node: String,
    vmid: u32,
    disk: String,
) -> Result<()> {
    debug!("query_bitmap: node={}, vmid={}, disk={}", node, vmid, disk);

    // TODO: Query dirty bitmap via QMP over SSH

    Ok(())
}
