//! Chunk computation and SHA256 hashing

use sha2::{Digest, Sha256};
use tracing::debug;

pub struct ChunkComputer;

impl ChunkComputer {
    /// Compute SHA256 hash of data
    pub fn hash(data: &[u8]) -> String {
        let mut hasher = Sha256::new();
        hasher.update(data);
        format!("{:x}", hasher.finalize())
    }

    /// Compute SHA256 and return (sha256, size)
    pub fn compute_chunk(data: &[u8]) -> (String, usize) {
        let sha256 = Self::hash(data);
        let size = data.len();

        debug!("Chunk: computed SHA256={} size={}", &sha256[..8], size);

        (sha256, size)
    }

    /// Verify chunk integrity
    pub fn verify(data: &[u8], expected_sha256: &str) -> bool {
        let computed = Self::hash(data);
        computed == expected_sha256
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_hash() {
        let data = b"hello world";
        let hash = ChunkComputer::hash(data);
        assert_eq!(
            hash,
            "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"
        );
    }

    #[test]
    fn test_verify() {
        let data = b"hello world";
        let hash = ChunkComputer::hash(data);
        assert!(ChunkComputer::verify(data, &hash));
        assert!(!ChunkComputer::verify(b"hello world!", &hash));
    }
}
