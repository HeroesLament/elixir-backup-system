//! RPC Handler - GenServer-like interface via Erlang Distribution Protocol
//!
//! Exposes methods that can be called from Elixir via:
//!   :rpc.call(:'ebs-nbd@127.0.0.1', EbsNBD, :read_blocks, [node, vmid, disk, offset, size])

use crate::nbd::{NBDClient, Transport};
use crate::chunk::ChunkComputer;
use anyhow::Result;
use tracing::{debug, info};

pub struct RpcHandler;

#[derive(Debug, Clone)]
pub struct Chunk {
    pub sha256: String,
    pub offset: u64,
    pub size: u64,
    pub data: Vec<u8>,
}

impl RpcHandler {
    /// Read blocks from a VM disk
    ///
    /// Equivalent to:
    ///   {:ok, chunks} = :rpc.call(:"ebs-nbd@127.0.0.1", EbsNBD, :read_blocks,
    ///     ["virt-2", 100, "0", 0, 65536])
    pub async fn read_blocks(
        node: String,
        vmid: u32,
        disk: String,
        offset: u64,
        size: u64,
    ) -> Result<Vec<Chunk>> {
        info!(
            "RPC: read_blocks node={} vmid={} disk={} offset={} size={}",
            node, vmid, disk, offset, size
        );

        // Detect transport based on context
        let transport = Transport::Direct; // TODO: Auto-detect or parameterize

        let client = NBDClient::new(node, vmid, disk, transport);
        client.connect().await?;

        // Read the block
        let data = client.read_block(offset, size).await?;

        // Compute SHA256
        let (sha256, actual_size) = ChunkComputer::compute_chunk(&data);

        let chunk = Chunk {
            sha256,
            offset,
            size: actual_size as u64,
            data,
        };

        debug!("RPC: returning {} chunks", 1);

        Ok(vec![chunk])
    }

    /// Query dirty bitmap for a VM disk
    ///
    /// Returns list of (offset, size) ranges that have changed since last backup
    pub async fn query_bitmap(
        node: String,
        vmid: u32,
        disk: String,
    ) -> Result<Vec<(u64, u64)>> {
        info!(
            "RPC: query_bitmap node={} vmid={} disk={}",
            node, vmid, disk
        );

        // Dirty bitmap requires WAN (SSH/QMP)
        let client = NBDClient::new(node, vmid, disk, Transport::Wan);
        client.connect().await?;

        let dirty_ranges = client.query_dirty_bitmap().await?;

        debug!("RPC: found {} dirty ranges", dirty_ranges.len());

        Ok(dirty_ranges)
    }

    /// Health check - simple ping
    pub async fn ping() -> Result<String> {
        Ok("pong".to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_ping() {
        let result = RpcHandler::ping().await;
        assert!(result.is_ok());
        assert_eq!(result.unwrap(), "pong");
    }
}
