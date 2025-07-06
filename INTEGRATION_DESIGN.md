# Data Portal 与 Librorum 集成设计

## 🎯 目标

将 Data Portal 的高性能零拷贝传输集成到 librorum 分布式文件系统中，实现：
- **同机零拷贝**: 69.4 GB/s 共享内存传输
- **网络优化**: TCP 减少拷贝，最高 7.7 GB/s
- **混合架构**: gRPC 控制 + Data Portal 数据

## 📋 接口适配分析

### 现有 Librorum 接口
```rust
// core/src/node_manager/file_service.rs
async fn upload_file(
    &self,
    request: Request<Streaming<UploadFileRequest>>
) -> Result<Response<UploadFileResponse>, Status>

async fn download_file(
    &self,
    request: Request<DownloadFileRequest>
) -> Result<Response<Self::DownloadFileStream>, Status>
```

**问题**:
- gRPC Streaming 有序列化开销
- 8MB 块大小可能不是最优
- 多次内存拷贝：客户端 → gRPC → VDFS → 存储

### Data Portal 接口
```rust
// universal-transport/src/lib.rs
pub struct SharedMemoryTransport {
    pub unsafe fn write_zero_copy(&self, data: &[u8], offset: usize) -> Result<()>
    pub unsafe fn read_zero_copy(&self, offset: usize, len: usize) -> Result<&[u8]>
}
```

**优势**:
- 真正零拷贝操作
- 69.4 GB/s 峰值性能
- 跨语言二进制兼容

## 🏗️ 混合架构设计

### 1. 双层协议架构

```
┌─────────────────────────────────────────────┐
│              gRPC 控制层                      │
│  • 文件元数据传输                              │
│  • 认证与授权                                 │  
│  • 传输协调                                   │
│  • 错误处理                                   │
└─────────────────────────────────────────────┘
                    ↕️
┌─────────────────────────────────────────────┐
│            Data Portal 数据层                │
│  • 文件数据零拷贝传输                          │
│  • 自动模式选择 (共享内存 vs TCP)              │
│  • 高性能块传输                               │
│  • 跨语言兼容                                 │
└─────────────────────────────────────────────┘
```

### 2. 传输流程设计

#### 上传流程
```
1. 客户端 → gRPC → 服务端: 文件元数据
2. 服务端响应: Data Portal 连接信息
3. 客户端 → Data Portal → 服务端: 零拷贝文件数据
4. 服务端 → gRPC → 客户端: 传输完成确认
```

#### 下载流程  
```
1. 客户端 → gRPC → 服务端: 文件请求
2. 服务端响应: 文件元数据 + Data Portal 连接信息
3. 客户端 ← Data Portal ← 服务端: 零拷贝文件数据
4. 客户端 → gRPC → 服务端: 接收完成确认
```

### 3. 自动传输模式选择

```rust
fn select_transport_mode(target_addr: &str) -> TransportMode {
    if is_local_address(target_addr) {
        TransportMode::SharedMemory  // 同机零拷贝
    } else {
        TransportMode::Network       // 跨机TCP优化
    }
}
```

## 🔧 实现策略

### Phase 1: 核心集成
1. **在 librorum 中添加 data-portal 依赖**
2. **创建 HybridFileService 替换现有 FileService**
3. **实现自动传输模式选择**

### Phase 2: 接口适配
1. **保持现有 gRPC 接口兼容性**
2. **添加新的高性能传输端点**
3. **优化块大小和传输参数**

### Phase 3: 零拷贝优化
1. **同机通信使用共享内存**
2. **TCP 传输减少拷贝次数**
3. **与 VDFS 存储层直接集成**

### Phase 4: Swift 客户端集成
1. **在 Swift 客户端中集成 Data Portal**
2. **实现跨语言零拷贝传输**
3. **性能监控和统计**

## 📊 性能预期

### 传输性能提升
- **同机传输**: 69.4 GB/s (vs 当前 ~100 MB/s gRPC)
- **跨机传输**: 7.7 GB/s (vs 当前 ~50 MB/s gRPC)
- **延迟**: 77 ns - 1.6 ms (vs 当前 ~100 ms gRPC)

### 整体系统提升
- **文件同步速度**: 138-1735x 提升
- **大文件传输**: 接近存储 I/O 极限
- **系统响应性**: 实时级别的文件操作

## 🎯 集成点识别

### 需要修改的文件
1. **`core/src/node_manager/file_service.rs`** - 添加 Data Portal 传输
2. **`shared/src/transport/hybrid.rs`** - 混合传输实现
3. **`client/librorum/Services/`** - Swift 客户端集成
4. **`core/Cargo.toml`** - 添加 data-portal 依赖

### 保持兼容性
- 现有 gRPC 接口保持不变
- 添加可选的高性能传输模式
- 向后兼容旧客户端

## ✅ 实现检查清单

- [ ] 添加 data-portal 依赖到 librorum
- [ ] 实现 HybridFileService
- [ ] 自动传输模式选择逻辑
- [ ] 与 VDFS 存储层集成
- [ ] Swift 客户端 Data Portal 集成
- [ ] 性能测试和优化
- [ ] 文档更新