//! NBD Client - Read blocks from Proxmox VMs
//!
//! Supports three transports:
//! - Direct: Local file I/O (same node)
//! - LAN: NBD over TCP (untrusted cluster)
//! - WAN: NBD over SSH tunnel (remote)

use anyhow::{anyhow, Result};
use std::path::PathBuf;
use tracing::{debug, info};

#[derive(Clone, Debug)]
pub enum Transport {
    Direct,
    Lan,
    Wan,
}

pub struct NBDClient {
    pub node: String,
    pub vmid: u32,
    pub disk: String,
    pub transport: Transport,
    pub nbd_port: u16,
}

impl NBDClient {
    pub fn new(node: String, vmid: u32, disk: String, transport: Transport) -> Self {
        Self {
            node,
            vmid,
            disk,
            transport,
            nbd_port: 10809,
        }
    }

    /// Connect to the NBD server
    pub async fn connect(&self) -> Result<()> {
        match self.transport {
            Transport::Direct => self.connect_direct().await,
            Transport::Lan => self.connect_lan().await,
            Transport::Wan => self.connect_wan().await,
        }
    }

    /// Read a block range from the disk
    pub async fn read_block(&self, offset: u64, size: u64) -> Result<Vec<u8>> {
        match self.transport {
            Transport::Direct => self.read_block_direct(offset, size).await,
            Transport::Lan => self.read_block_lan(offset, size).await,
            Transport::Wan => self.read_block_wan(offset, size).await,
        }
    }

    /// Query dirty bitmap (qcow2 only, requires WAN/SSH)
    pub async fn query_dirty_bitmap(&self) -> Result<Vec<(u64, u64)>> {
        match self.transport {
            Transport::Direct | Transport::Lan => {
                Err(anyhow!(
                    "Dirty bitmap requires qcow2 and WAN transport (QMP over SSH)"
                ))
            }
            Transport::Wan => self.query_bitmap_via_ssh().await,
        }
    }

    // Private methods

    async fn connect_direct(&self) -> Result<()> {
        let disk_path = self.disk_file_path();
        if !disk_path.exists() {
            return Err(anyhow!("Disk file not found: {}", disk_path.display()));
        }
        info!("NBD: using direct I/O for disk {}", disk_path.display());
        Ok(())
    }

    async fn connect_lan(&self) -> Result<()> {
        info!(
            "NBD: connecting to LAN NBD server on port {} (not yet implemented)",
            self.nbd_port
        );
        // TODO: Implement NBD TCP connection
        Ok(())
    }

    async fn connect_wan(&self) -> Result<()> {
        info!(
            "NBD: establishing WAN SSH tunnel to {} (not yet implemented)",
            self.node
        );
        // TODO: Establish SSH tunnel for QMP + data plane
        Ok(())
    }

    async fn read_block_direct(&self, offset: u64, size: u64) -> Result<Vec<u8>> {
        use std::io::{Read, Seek, SeekFrom};

        let disk_path = self.disk_file_path();
        let mut file = std::fs::File::open(&disk_path)?;
        file.seek(SeekFrom::Start(offset))?;

        let mut buffer = vec![0u8; size as usize];
        file.read_exact(&mut buffer)?;

        debug!(
            "NBD: read {} bytes from {} at offset {}",
            size,
            disk_path.display(),
            offset
        );

        Ok(buffer)
    }

    async fn read_block_lan(&self, _offset: u64, _size: u64) -> Result<Vec<u8>> {
        // TODO: Implement NBD protocol over TCP
        Err(anyhow!("LAN NBD not yet implemented"))
    }

    async fn read_block_wan(&self, _offset: u64, _size: u64) -> Result<Vec<u8>> {
        // TODO: Implement NBD protocol over SSH tunnel
        Err(anyhow!("WAN NBD not yet implemented"))
    }

    async fn query_bitmap_via_ssh(&self) -> Result<Vec<(u64, u64)>> {
        // TODO: Query dirty bitmap via QMP over SSH tunnel
        Err(anyhow!("SSH bitmap query not yet implemented"))
    }

    fn disk_file_path(&self) -> PathBuf {
        // Proxmox disk path: /var/lib/vz/images/{vmid}/vm-{vmid}-disk-{disk}.qcow2
        PathBuf::from(format!(
            "/var/lib/vz/images/{}/vm-{}-{}.qcow2",
            self.vmid, self.vmid, self.disk
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_disk_file_path() {
        let client = NBDClient::new(
            "virt-2".to_string(),
            100,
            "0".to_string(),
            Transport::Direct,
        );
        let path = client.disk_file_path();
        assert_eq!(
            path,
            PathBuf::from("/var/lib/vz/images/100/vm-100-0.qcow2")
        );
    }
}
