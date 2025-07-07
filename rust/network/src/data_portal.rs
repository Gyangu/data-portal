//! Data Portal compatibility network transport

use crate::protocol::{NetworkMessageHeader, MessageType, DATA_PORTAL_PROTOCOL_MAGIC, PROTOCOL_VERSION};
use async_trait::async_trait;
use bytes::Bytes;
// TODO: Import from core once circular dependency is resolved

/// Data Portal compatibility network transport
pub struct DataPortalNetworkTransport {
    // TODO: Implement actual network transport
}

impl DataPortalNetworkTransport {
    /// Create a new data portal network transport
    pub fn new() -> Self {
        Self {}
    }
}

impl Default for DataPortalNetworkTransport {
    fn default() -> Self {
        Self::new()
    }
}

// TODO: Implement Transport trait once core types are stabilized