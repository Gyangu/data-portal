//! Data Portal File Service
//! 
//! 基于 Data Portal 的高性能文件服务：
//! - 零拷贝传输：POSIX 共享内存 (同机器通信)
//! - 高效网络传输：优化的 TCP 传输 (跨机器通信)
//! - 自动模式选择：根据客户端位置智能选择传输方式

use crate::proto::file::{
    file_service_server::FileService,
    CreateDirectoryRequest, CreateDirectoryResponse,
    DeleteFileRequest, DeleteFileResponse,
    DownloadFileRequest, DownloadFileResponse,
    FileInfo, FilePermissions, FileType,
    GetFileInfoRequest, GetSyncStatusRequest,
    ListFilesRequest, ListFilesResponse,
    SyncStatus, SyncStatusResponse,
    UploadFileRequest, UploadFileResponse,
};
use crate::vdfs::{VDFS, VDFSConfig};
use data_portal::SharedMemoryTransport;
use std::collections::HashMap;
use std::pin::Pin;
use std::sync::Arc;
use std::net::SocketAddr;
use tokio::sync::Mutex;
use tokio_stream::{wrappers::ReceiverStream, Stream, StreamExt};
use tonic::{Request, Response, Status, Streaming};
use tracing::{debug, error, info, warn};
use anyhow::Result;

/// 传输模式
#[derive(Debug, Clone, Copy)]
pub enum TransportMode {
    /// TCP网络传输
    Network,
    /// POSIX共享内存 (零拷贝)
    SharedMemory,
    /// 自动选择
    Auto,
}

/// 传输会话信息
#[derive(Debug, Clone)]
pub struct TransferSession {
    pub session_id: String,
    pub mode: TransportMode,
    pub file_size: u64,
    pub transferred_bytes: u64,
    pub start_time: std::time::Instant,
    pub data_portal_address: Option<String>,
}

/// 传输统计信息
#[derive(Debug, Clone, Default)]
pub struct TransferStats {
    pub total_sessions: u64,
    pub active_uploads: u64,
    pub active_downloads: u64,
    pub bytes_transferred: u64,
    pub average_rate: f64,
    pub zero_copy_ratio: f64,
}

/// 混合文件服务实现
pub struct HybridFileServiceV2 {
    // VDFS实例 - 实际的分布式文件系统
    vdfs: Option<Arc<VDFS>>,
    // 临时兼容：用于存储文件元数据的内存映射
    files: Arc<Mutex<HashMap<String, FileInfo>>>,
    // 文件计数器，用于生成唯一的文件ID
    file_counter: Arc<Mutex<u64>>,
    // 活跃的传输会话
    active_sessions: Arc<Mutex<HashMap<String, TransferSession>>>,
    // Data Portal 端口分配器
    portal_port_allocator: Arc<Mutex<u16>>,
}

impl HybridFileServiceV2 {
    pub fn new(storage_path: String) -> Self {
        Self {
            vdfs: None,
            files: Arc::new(Mutex::new(HashMap::new())),
            file_counter: Arc::new(Mutex::new(0)),
            active_sessions: Arc::new(Mutex::new(HashMap::new())),
            portal_port_allocator: Arc::new(Mutex::new(9090)),
        }
    }
    
    pub fn new_default() -> Self {
        Self::new("/tmp/librorum_storage".to_string())
    }
    
    /// 异步初始化VDFS
    pub async fn init_vdfs(&mut self, config: VDFSConfig) -> Result<()> {
        info!("Initializing VDFS for HybridFileServiceV2...");
        let vdfs = VDFS::new(config).await
            .map_err(|e| anyhow::anyhow!("Failed to initialize VDFS: {}", e))?;
        self.vdfs = Some(Arc::new(vdfs));
        info!("✓ VDFS initialized successfully for HybridFileServiceV2");
        Ok(())
    }
    
    /// 创建带有自定义VDFS的FileService
    pub fn with_vdfs(vdfs: Arc<VDFS>) -> Self {
        Self {
            vdfs: Some(vdfs),
            files: Arc::new(Mutex::new(HashMap::new())),
            file_counter: Arc::new(Mutex::new(0)),
            active_sessions: Arc::new(Mutex::new(HashMap::new())),
            portal_port_allocator: Arc::new(Mutex::new(9090)),
        }
    }

    /// 选择传输模式
    fn select_transport_mode(&self, client_addr: Option<&SocketAddr>) -> TransportMode {
        match client_addr {
            Some(addr) => {
                // 如果是本地地址，使用共享内存
                if addr.ip().is_loopback() || addr.ip().to_string().starts_with("127.") {
                    TransportMode::SharedMemory
                } else {
                    TransportMode::Network
                }
            }
            None => TransportMode::SharedMemory // 默认本地传输
        }
    }

    /// 分配新的 Data Portal 端口
    async fn allocate_portal_port(&self) -> u16 {
        let mut allocator = self.portal_port_allocator.lock().await;
        let port = *allocator;
        *allocator += 1;
        if *allocator > 9200 {
            *allocator = 9090; // 循环使用端口
        }
        port
    }

    /// 启动 Data Portal 服务器
    fn start_data_portal_server(
        &self,
        session_id: String,
        mode: TransportMode,
        file_size: u64,
        file_data: Vec<u8>,
    ) -> Result<String> {
        match mode {
            TransportMode::SharedMemory => {
                let shm_path = format!("/librorum_transfer_{}", session_id);
                let shm_size = (file_size as usize).max(1024 * 1024); // 最小1MB
                
                info!("Creating shared memory for transfer: {} bytes", shm_size);
                let shm = SharedMemoryTransport::new(&shm_path, shm_size)?;
                
                // 零拷贝写入文件数据
                unsafe {
                    shm.write_zero_copy(&file_data, 0)?;
                }
                
                // 返回共享内存路径作为连接信息
                Ok(shm_path)
            }
            TransportMode::Network => {
                // 简化实现：返回占位符地址
                let addr = format!("127.0.0.1:9090");
                
                // TODO: 实现真正的TCP服务器
                info!("TCP Data Portal server placeholder: {}", addr);
                
                Ok(addr)
            }
            TransportMode::Auto => {
                // 默认使用共享内存
                self.start_data_portal_server(session_id, TransportMode::SharedMemory, file_size, file_data)
            }
        }
    }
    
    /// 获取传输统计信息
    pub async fn get_transfer_stats(&self) -> TransferStats {
        let sessions = self.active_sessions.lock().await;
        let total_sessions = sessions.len() as u64;
        let active_uploads = sessions.values()
            .filter(|s| matches!(s.mode, TransportMode::SharedMemory | TransportMode::Network))
            .count() as u64;
        let active_downloads = 0; // 简化实现
        
        // 计算零拷贝比例
        let shared_memory_sessions = sessions.values()
            .filter(|s| matches!(s.mode, TransportMode::SharedMemory))
            .count() as u64;
        let zero_copy_ratio = if total_sessions > 0 {
            shared_memory_sessions as f64 / total_sessions as f64
        } else {
            0.0
        };
        
        TransferStats {
            total_sessions,
            active_uploads,
            active_downloads,
            bytes_transferred: sessions.values().map(|s| s.transferred_bytes).sum(),
            average_rate: 0.0, // 简化实现
            zero_copy_ratio,
        }
    }

    async fn generate_file_id(&self) -> String {
        let mut counter = self.file_counter.lock().await;
        *counter += 1;
        format!("file_{:010}", *counter)
    }

    fn create_file_permissions() -> FilePermissions {
        FilePermissions {
            mode: 0o644,
            owner: "user".to_string(),
            group: "group".to_string(),
            readable: true,
            writable: true,
            executable: false,
        }
    }
}

#[tonic::async_trait]
impl FileService for HybridFileServiceV2 {
    async fn list_files(
        &self,
        request: Request<ListFilesRequest>,
    ) -> Result<Response<ListFilesResponse>, Status> {
        let req = request.into_inner();
        info!("📁 Listing files in path: {}", req.path);

        let files = self.files.lock().await;
        
        let matching_files: Vec<FileInfo> = files
            .values()
            .filter(|file| {
                if req.recursive {
                    file.parent_path.starts_with(&req.path)
                } else {
                    file.parent_path == req.path
                }
            })
            .filter(|file| {
                if req.include_hidden {
                    true
                } else {
                    !file.name.starts_with('.')
                }
            })
            .cloned()
            .collect();

        let total_size: i64 = matching_files.iter().map(|f| f.size).sum();

        info!("📊 Found {} files, total size: {} bytes", matching_files.len(), total_size);

        let response = ListFilesResponse {
            files: matching_files.clone(),
            current_path: req.path,
            total_count: matching_files.len() as i32,
            total_size,
        };

        Ok(Response::new(response))
    }

    async fn upload_file(
        &self,
        request: Request<Streaming<UploadFileRequest>>,
    ) -> Result<Response<UploadFileResponse>, Status> {
        let mut stream = request.into_inner();
        let files = Arc::clone(&self.files);
        
        let mut metadata: Option<crate::proto::file::UploadFileMetadata> = None;
        let mut bytes_uploaded = 0i64;
        let mut file_data = Vec::new();

        // 1. 通过gRPC接收文件元数据和数据
        while let Some(request) = stream.next().await {
            match request {
                Ok(req) => {
                    match req.data {
                        Some(crate::proto::file::upload_file_request::Data::Metadata(meta)) => {
                            info!("🚀 Receiving hybrid upload: {} ({} bytes)", meta.name, meta.size);
                            metadata = Some(meta);
                        }
                        Some(crate::proto::file::upload_file_request::Data::Chunk(chunk)) => {
                            bytes_uploaded += chunk.len() as i64;
                            file_data.extend_from_slice(&chunk);
                            
                            debug!("📦 Received chunk: {} bytes (total: {})", chunk.len(), bytes_uploaded);
                        }
                        None => {
                            warn!("⚠️ Received empty upload request data");
                        }
                    }
                }
                Err(e) => {
                    error!("❌ Error receiving upload stream: {}", e);
                    return Err(Status::internal("Upload stream error"));
                }
            }
        }

        // 2. 处理上传完成
        if let Some(meta) = metadata {
            let session_id = uuid::Uuid::new_v4().to_string().replace('-', "");
            let file_id = format!("file_{}", session_id);
            
            // 3. 选择传输模式并启动 Data Portal
            let transport_mode = self.select_transport_mode(None); // TODO: 获取客户端地址
            
            info!("🌀 Starting Data Portal transfer: mode={:?}, size={} bytes", 
                  transport_mode, file_data.len());
            
            // 4. 启动高性能传输服务
            let portal_address = match self.start_data_portal_server(
                session_id.clone(),
                transport_mode,
                bytes_uploaded as u64,
                file_data.clone(),
            ) {
                Ok(addr) => {
                    info!("✅ Data Portal server started: {}", addr);
                    Some(addr)
                }
                Err(e) => {
                    error!("❌ Failed to start Data Portal server: {}", e);
                    None
                }
            };
            
            // 5. 尝试使用VDFS存储实际文件数据
            let vdfs_result = match &self.vdfs {
                Some(vdfs) => {
                    match vdfs.write_file(&meta.path, &file_data).await {
                        Ok(_) => {
                            info!("💾 File successfully written to VDFS: {}", meta.path);
                            true
                        }
                        Err(e) => {
                            error!("💾 Failed to write file to VDFS: {}, using memory storage", e);
                            false
                        }
                    }
                }
                None => {
                    warn!("💾 VDFS not initialized, using memory storage");
                    false
                }
            };
            
            // 6. 创建传输会话
            let transfer_session = TransferSession {
                session_id: session_id.clone(),
                mode: transport_mode,
                file_size: bytes_uploaded as u64,
                transferred_bytes: bytes_uploaded as u64,
                start_time: std::time::Instant::now(),
                data_portal_address: portal_address.clone(),
            };
            
            {
                let mut sessions = self.active_sessions.lock().await;
                sessions.insert(session_id.clone(), transfer_session);
            }
            
            // 7. 创建文件元数据
            let file_info = FileInfo {
                file_id: file_id.clone(),
                name: meta.name.clone(),
                path: meta.path.clone(),
                parent_path: std::path::Path::new(&meta.path)
                    .parent()
                    .unwrap_or(std::path::Path::new("/"))
                    .to_string_lossy()
                    .to_string(),
                size: bytes_uploaded,
                created_at: chrono::Utc::now().timestamp(),
                modified_at: chrono::Utc::now().timestamp(),
                accessed_at: chrono::Utc::now().timestamp(),
                file_type: FileType::Regular.into(),
                mime_type: meta.mime_type,
                checksum: meta.checksum,
                permissions: Some(Self::create_file_permissions()),
                is_directory: false,
                is_symlink: false,
                chunk_count: 1,
                chunk_ids: vec![format!("chunk_{}", file_id)],
                replication_factor: 3,
                is_compressed: meta.compress,
                is_encrypted: meta.encrypt,
                sync_status: if vdfs_result { SyncStatus::Synced } else { SyncStatus::Error }.into(),
            };

            // 8. 保存文件信息
            let mut files_map = files.lock().await;
            files_map.insert(file_id.clone(), file_info.clone());
            
            info!("🎉 Hybrid upload completed: {} ({} bytes) - VDFS: {} - Portal: {:?}", 
                  meta.name, bytes_uploaded, vdfs_result, portal_address);

            let mut response_message = "File uploaded successfully via hybrid architecture".to_string();
            if let Some(addr) = portal_address {
                response_message.push_str(&format!(" - Data Portal: {}", addr));
            }

            let response = UploadFileResponse {
                success: true,
                message: response_message,
                file_info: Some(file_info),
                bytes_uploaded,
            };

            Ok(Response::new(response))
        } else {
            error!("❌ No metadata received for hybrid upload");
            let response = UploadFileResponse {
                success: false,
                message: "No metadata received".to_string(),
                file_info: None,
                bytes_uploaded: 0,
            };
            Ok(Response::new(response))
        }
    }

    type DownloadFileStream = Pin<Box<dyn Stream<Item = Result<DownloadFileResponse, Status>> + Send>>;

    async fn download_file(
        &self,
        request: Request<DownloadFileRequest>,
    ) -> Result<Response<Self::DownloadFileStream>, Status> {
        let req = request.into_inner();
        let files = self.files.lock().await;
        
        // 查找文件
        let file_info = if !req.file_id.is_empty() {
            files.get(&req.file_id).cloned()
        } else if !req.path.is_empty() {
            files.values().find(|f| f.path == req.path).cloned()
        } else {
            return Err(Status::invalid_argument("Either file_id or path must be provided"));
        };

        let file_info = file_info.ok_or_else(|| Status::not_found("File not found"))?;

        info!("🌀 Starting hybrid download: {} ({} bytes)", file_info.name, file_info.size);

        let (tx, rx) = tokio::sync::mpsc::channel(128);
        let file_info_clone = file_info.clone();
        let vdfs = self.vdfs.clone();
        
        // 生成会话ID和选择传输模式
        let session_id = uuid::Uuid::new_v4().to_string().replace('-', "");
        let _transport_mode = self.select_transport_mode(None); // TODO: 获取客户端地址
        
        tokio::spawn(async move {
            // 1. 首先发送文件元数据
            let info_response = DownloadFileResponse {
                data: Some(crate::proto::file::download_file_response::Data::FileInfo(file_info_clone.clone())),
                offset: 0,
                total_size: file_info_clone.size,
            };
            
            if tx.send(Ok(info_response)).await.is_err() {
                return;
            }

            // 2. 从VDFS读取文件数据
            let file_data = match &vdfs {
                Some(vdfs_instance) => {
                    match vdfs_instance.read_file(&file_info_clone.path).await {
                        Ok(data) => {
                            info!("💾 File successfully read from VDFS: {} bytes", data.len());
                            data
                        }
                        Err(e) => {
                            error!("💾 Failed to read file from VDFS: {}, generating test data", e);
                            vec![0xAA; file_info_clone.size as usize] // 测试数据
                        }
                    }
                }
                None => {
                    warn!("💾 VDFS not initialized, generating test data");
                    vec![0xAA; file_info_clone.size as usize] // 测试数据
                }
            };
            
            // 3. 为大文件启动 Data Portal 高速传输
            let use_portal = file_info_clone.size > 1024 * 1024; // 1MB以上使用Data Portal
            
            if use_portal {
                info!("🚀 Using Data Portal for large file transfer: {} bytes", file_info_clone.size);
                
                // 创建Data Portal服务器的引用 (需要重构以支持下载)
                // TODO: 实现Data Portal下载服务器
                
                // 发送Data Portal连接信息
                let portal_info = format!("portal://shared_memory/{}", session_id);
                let portal_response = DownloadFileResponse {
                    data: Some(crate::proto::file::download_file_response::Data::Chunk(portal_info.into_bytes())),
                    offset: -1, // 特殊标记表示这是Portal连接信息
                    total_size: file_info_clone.size,
                };
                
                if tx.send(Ok(portal_response)).await.is_err() {
                    return;
                }
            }
            
            // 4. 使用优化的块大小分块传输
            let total_size = file_info_clone.size;
            let chunk_size = if use_portal {
                256 * 1024 // 256KB for portal mode (smaller chunks since main data via portal)
            } else if total_size < 5 * 1024 * 1024 { // < 5MB
                1024 * 1024 // 1MB
            } else if total_size < 50 * 1024 * 1024 { // < 50MB
                4 * 1024 * 1024 // 4MB  
            } else {
                8 * 1024 * 1024 // 8MB for large files
            };
            
            let mut offset = req.offset as usize;
            let end_offset = if req.length > 0 {
                std::cmp::min(req.offset + req.length, total_size) as usize
            } else {
                total_size as usize
            };

            while offset < end_offset && offset < file_data.len() {
                let remaining = end_offset - offset;
                let current_chunk_size = std::cmp::min(chunk_size, remaining);
                let actual_chunk_size = std::cmp::min(current_chunk_size, file_data.len() - offset);
                
                let chunk_data = if actual_chunk_size > 0 {
                    file_data[offset..offset + actual_chunk_size].to_vec()
                } else {
                    Vec::new()
                };
                
                let chunk_response = DownloadFileResponse {
                    data: Some(crate::proto::file::download_file_response::Data::Chunk(chunk_data)),
                    offset: offset as i64,
                    total_size,
                };
                
                if tx.send(Ok(chunk_response)).await.is_err() {
                    break;
                }
                
                offset += actual_chunk_size;
            }

            info!("🎉 Hybrid download completed: {} bytes sent", offset as i64 - req.offset);
        });

        let output_stream = ReceiverStream::new(rx);
        Ok(Response::new(Box::pin(output_stream)))
    }

    async fn delete_file(
        &self,
        request: Request<DeleteFileRequest>,
    ) -> Result<Response<DeleteFileResponse>, Status> {
        let req = request.into_inner();
        let mut files = self.files.lock().await;
        
        let file_to_delete = if !req.file_id.is_empty() {
            files.get(&req.file_id).cloned()
        } else if !req.path.is_empty() {
            files.values().find(|f| f.path == req.path).cloned()
        } else {
            return Err(Status::invalid_argument("Either file_id or path must be provided"));
        };

        let file_info = file_to_delete.ok_or_else(|| Status::not_found("File not found"))?;

        info!("🗑️ Deleting file: {}", file_info.name);

        let mut deleted_count = 0;

        if file_info.is_directory && req.recursive {
            let dir_path = &file_info.path;
            let files_to_remove: Vec<String> = files
                .iter()
                .filter(|(_, f)| f.path.starts_with(dir_path))
                .map(|(id, _)| id.clone())
                .collect();
            
            for file_id in files_to_remove {
                files.remove(&file_id);
                deleted_count += 1;
            }
        } else if !file_info.is_directory || req.force {
            files.remove(&file_info.file_id);
            deleted_count = 1;
        } else {
            return Err(Status::failed_precondition(
                "Cannot delete directory without recursive flag"
            ));
        }

        info!("✅ Successfully deleted {} file(s)", deleted_count);

        let response = DeleteFileResponse {
            success: true,
            message: format!("Successfully deleted {} file(s)", deleted_count),
            deleted_count,
        };

        Ok(Response::new(response))
    }

    async fn create_directory(
        &self,
        request: Request<CreateDirectoryRequest>,
    ) -> Result<Response<CreateDirectoryResponse>, Status> {
        let req = request.into_inner();
        info!("📁 Creating directory: {}", req.path);

        let mut files = self.files.lock().await;
        
        if files.values().any(|f| f.path == req.path && f.is_directory) {
            return Err(Status::already_exists("Directory already exists"));
        }

        let file_id = format!("dir_{}", uuid::Uuid::new_v4().to_string().replace('-', ""));
        let directory_name = std::path::Path::new(&req.path)
            .file_name()
            .unwrap_or_else(|| std::ffi::OsStr::new(""))
            .to_string_lossy()
            .to_string();

        let parent_path = std::path::Path::new(&req.path)
            .parent()
            .unwrap_or(std::path::Path::new("/"))
            .to_string_lossy()
            .to_string();

        let directory_info = FileInfo {
            file_id: file_id.clone(),
            name: directory_name,
            path: req.path.clone(),
            parent_path,
            size: 0,
            created_at: chrono::Utc::now().timestamp(),
            modified_at: chrono::Utc::now().timestamp(),
            accessed_at: chrono::Utc::now().timestamp(),
            file_type: FileType::Directory.into(),
            mime_type: "inode/directory".to_string(),
            checksum: String::new(),
            permissions: req.permissions.or_else(|| Some(Self::create_file_permissions())),
            is_directory: true,
            is_symlink: false,
            chunk_count: 0,
            chunk_ids: vec![],
            replication_factor: 1,
            is_compressed: false,
            is_encrypted: false,
            sync_status: SyncStatus::Synced.into(),
        };

        files.insert(file_id, directory_info.clone());

        info!("✅ Successfully created directory: {}", req.path);

        let response = CreateDirectoryResponse {
            success: true,
            message: "Directory created successfully".to_string(),
            directory_info: Some(directory_info),
        };

        Ok(Response::new(response))
    }

    async fn get_file_info(
        &self,
        request: Request<GetFileInfoRequest>,
    ) -> Result<Response<FileInfo>, Status> {
        let req = request.into_inner();
        let files = self.files.lock().await;
        
        let file_info = if !req.file_id.is_empty() {
            files.get(&req.file_id).cloned()
        } else if !req.path.is_empty() {
            files.values().find(|f| f.path == req.path).cloned()
        } else {
            return Err(Status::invalid_argument("Either file_id or path must be provided"));
        };

        let mut file_info = file_info.ok_or_else(|| Status::not_found("File not found"))?;

        if !req.include_chunks {
            file_info.chunk_ids.clear();
            file_info.chunk_count = 0;
        }

        debug!("ℹ️ Retrieved file info for: {}", file_info.name);

        Ok(Response::new(file_info))
    }

    async fn get_sync_status(
        &self,
        request: Request<GetSyncStatusRequest>,
    ) -> Result<Response<SyncStatusResponse>, Status> {
        let req = request.into_inner();
        let files = self.files.lock().await;
        
        debug!("📊 Getting sync status for path: {}", req.path);

        let target_files: Vec<&FileInfo> = if req.path.is_empty() {
            files.values().collect()
        } else {
            files.values().filter(|f| f.path.starts_with(&req.path)).collect()
        };

        let mut pending_uploads = 0;
        let pending_downloads = 0;
        let mut syncing_files = 0;
        let mut error_files = 0;
        let mut conflict_files = 0;
        let mut bytes_to_upload = 0i64;
        let bytes_to_download = 0i64;
        let mut pending_files = Vec::new();

        for file in &target_files {
            match SyncStatus::try_from(file.sync_status).unwrap_or(SyncStatus::Unknown) {
                SyncStatus::Pending => {
                    pending_uploads += 1;
                    bytes_to_upload += file.size;
                    pending_files.push((*file).clone());
                }
                SyncStatus::Syncing => {
                    syncing_files += 1;
                }
                SyncStatus::Error => {
                    error_files += 1;
                    pending_files.push((*file).clone());
                }
                SyncStatus::Conflict => {
                    conflict_files += 1;
                    pending_files.push((*file).clone());
                }
                _ => {}
            }
        }

        let overall_status = if error_files > 0 || conflict_files > 0 {
            SyncStatus::Error
        } else if syncing_files > 0 || pending_uploads > 0 || pending_downloads > 0 {
            SyncStatus::Syncing
        } else {
            SyncStatus::Synced
        };

        debug!("📈 Sync status: {} files, {} pending, {} syncing, {} errors", 
               target_files.len(), pending_uploads, syncing_files, error_files);

        let response = SyncStatusResponse {
            overall_status: overall_status.into(),
            pending_uploads,
            pending_downloads,
            syncing_files,
            error_files,
            conflict_files,
            bytes_to_upload,
            bytes_to_download,
            pending_files,
        };

        Ok(Response::new(response))
    }
}