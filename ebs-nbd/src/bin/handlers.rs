/// RPC Handlers - Business logic for NBD operations

use anyhow::Result;
use ebs_nbd::{NBDClient, Transport, ChunkComputer};
use tracing::{info, debug};

pub async fn read_blocks(
    node: String,
    vmid: u32,
    disk: String,
    offset: u64,
    size: u64,
) -> Result<String> {
    info!(
        "read_blocks: node={}, vmid={}, disk={}, offset={}, size={}",
        node, vmid, disk, offset, size
    );

    // Create NBD client (direct transport for local reads)
    let client = NBDClient::new(node, vmid, disk, Transport::Direct);
    client.connect().await?;

    // Read the block
    let data = client.read_block(offset, size).await?;

    // Compute SHA256
    let (sha256, actual_size) = ChunkComputer::compute_chunk(&data);

    // Encode as base64 for JSON response
    let data_b64 = base64::engine::general_purpose::STANDARD.encode(&data);

    debug!(
        "read_blocks response: sha256={}, size={}",
        &sha256[..8],
        actual_size
    );

    Ok(format!(
        r#"{{
            "sha256": "{}",
            "offset": {},
            "size": {},
            "data": "{}"
        }}"#,
        sha256, offset, actual_size, data_b64
    ))
}

pub async fn query_bitmap(
    node: String,
    vmid: u32,
    disk: String,
) -> Result<String> {
    info!("query_bitmap: node={}, vmid={}, disk={}", node, vmid, disk);

    // Create NBD client (WAN transport for SSH + QMP)
    let client = NBDClient::new(node, vmid, disk, Transport::Wan);

    let dirty_ranges = client.query_dirty_bitmap().await?;

    debug!("query_bitmap response: {} ranges", dirty_ranges.len());

    // Format ranges as JSON array
    let ranges_json = dirty_ranges
        .iter()
        .map(|(offset, size)| format!(r#"{{"offset": {}, "size": {}}}"#, offset, size))
        .collect::<Vec<_>>()
        .join(",");

    Ok(format!("[{}]", ranges_json))
}
