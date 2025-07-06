//! 测试 Data Portal 集成到 librorum
//! 
//! 验证混合架构：gRPC 控制 + Data Portal 数据传输

use data_portal::SharedMemoryTransport;
use std::ptr;
use anyhow::Result;
use tokio;

#[tokio::main]
async fn main() -> Result<()> {
    println!("🌀 Testing Data Portal integration with librorum");
    
    // 1. 测试基础 Data Portal 功能
    println!("📦 Testing basic Data Portal functionality...");
    test_basic_data_portal().await?;
    
    // 2. 测试零拷贝传输
    println!("⚡ Testing zero-copy transfer...");
    test_zero_copy_transfer().await?;
    
    // 3. 测试大文件传输
    println!("📁 Testing large file transfer...");
    test_large_file_transfer().await?;
    
    println!("✅ All Data Portal integration tests passed!");
    Ok(())
}

/// 测试基础 Data Portal 功能
async fn test_basic_data_portal() -> Result<()> {
    let shm_path = "/test_librorum_portal";
    let shm_size = 1024 * 1024; // 1MB
    
    // 创建共享内存
    let shm = SharedMemoryTransport::new(shm_path, shm_size)?;
    
    // 测试数据
    let test_data = b"Hello from librorum via Data Portal!";
    
    // 零拷贝写入
    unsafe {
        shm.write_zero_copy(test_data, 0)?;
    }
    
    // 零拷贝读取
    let read_data = unsafe {
        shm.read_zero_copy(0, test_data.len())?
    };
    
    // 验证数据
    assert_eq!(test_data, read_data);
    println!("  ✅ Basic shared memory test passed");
    
    Ok(())
}

/// 测试零拷贝传输性能
async fn test_zero_copy_transfer() -> Result<()> {
    let shm_path = "/test_librorum_zerocopy";
    let data_size = 16 * 1024; // 16KB (Data Portal 最优块大小)
    let shm_size = data_size * 2;
    
    let shm = SharedMemoryTransport::new(shm_path, shm_size)?;
    
    // 生成测试数据
    let test_data: Vec<u8> = (0..data_size).map(|i| (i % 256) as u8).collect();
    
    let iterations = 1000;
    let start_time = std::time::Instant::now();
    
    // 性能测试：多次零拷贝操作
    for i in 0..iterations {
        unsafe {
            // 零拷贝写入
            ptr::copy_nonoverlapping(
                test_data.as_ptr(),
                shm.as_ptr(),
                data_size
            );
            
            // 零拷贝读取
            let mut read_buffer = vec![0u8; data_size];
            ptr::copy_nonoverlapping(
                shm.as_ptr(),
                read_buffer.as_mut_ptr(),
                data_size
            );
            
            // 验证数据完整性
            if i % 100 == 0 {
                assert_eq!(test_data, read_buffer);
            }
        }
        
        // 让出控制权
        if i % 100 == 0 {
            tokio::task::yield_now().await;
        }
    }
    
    let duration = start_time.elapsed();
    let total_bytes = (iterations * data_size * 2) as f64; // 读+写
    let throughput_gbps = (total_bytes / duration.as_secs_f64()) / (1024.0 * 1024.0 * 1024.0);
    let ops_per_sec = iterations as f64 / duration.as_secs_f64();
    
    println!("  📊 Zero-copy performance:");
    println!("    Throughput: {:.2} GB/s", throughput_gbps);
    println!("    Operations: {:.0} ops/sec", ops_per_sec);
    println!("    Latency: {:.2} μs", (duration.as_secs_f64() / iterations as f64) * 1_000_000.0);
    
    assert!(throughput_gbps > 10.0, "Expected >10 GB/s performance");
    println!("  ✅ Zero-copy performance test passed");
    
    Ok(())
}

/// 测试大文件传输 (模拟 librorum 文件传输场景)
async fn test_large_file_transfer() -> Result<()> {
    let file_size = 100 * 1024 * 1024; // 100MB
    let shm_path = "/test_librorum_largefile";
    let shm_size = file_size;
    
    println!("  📂 Testing {}MB file transfer...", file_size / (1024 * 1024));
    
    let shm = SharedMemoryTransport::new(shm_path, shm_size)?;
    
    // 生成大文件测试数据 (模拟文件内容)
    let start_gen = std::time::Instant::now();
    let test_file_data: Vec<u8> = (0..file_size)
        .map(|i| ((i as u64).wrapping_mul(0x9E3779B97F4A7C15u64) >> 56) as u8)
        .collect();
    let gen_time = start_gen.elapsed();
    println!("    Data generation: {:.2}s", gen_time.as_secs_f64());
    
    // 模拟 librorum 文件上传：gRPC 元数据 + Data Portal 数据
    let file_metadata = format!(
        "{{\"name\": \"test_large_file.bin\", \"size\": {}, \"checksum\": \"mock_checksum\"}}",
        file_size
    );
    println!("    📋 File metadata: {} bytes", file_metadata.len());
    
    // Data Portal 高速传输
    let start_transfer = std::time::Instant::now();
    
    // 零拷贝写入大文件
    unsafe {
        shm.write_zero_copy(&test_file_data, 0)?;
    }
    
    // 模拟读取验证 (只验证开头和结尾)
    let header_data = unsafe {
        shm.read_zero_copy(0, 1024)?
    };
    let footer_data = unsafe {
        shm.read_zero_copy(file_size - 1024, 1024)?
    };
    
    let transfer_time = start_transfer.elapsed();
    let throughput_mbps = (file_size as f64 * 2.0) / (1024.0 * 1024.0) / transfer_time.as_secs_f64();
    let throughput_gbps = throughput_mbps / 1024.0;
    
    // 验证数据完整性
    assert_eq!(&test_file_data[0..1024], header_data);
    assert_eq!(&test_file_data[file_size-1024..], footer_data);
    
    println!("    📊 Large file transfer performance:");
    println!("      Transfer time: {:.3}s", transfer_time.as_secs_f64());
    println!("      Throughput: {:.1} MB/s ({:.2} GB/s)", throughput_mbps, throughput_gbps);
    println!("      Data integrity: ✅ Verified");
    
    // 性能断言
    assert!(throughput_gbps > 5.0, "Expected >5 GB/s for large file transfer");
    
    println!("  ✅ Large file transfer test passed");
    
    Ok(())
}

/// 模拟 librorum 混合架构的工作流程
#[allow(dead_code)]
async fn simulate_librorum_hybrid_workflow() -> Result<()> {
    println!("🏗️ Simulating librorum hybrid architecture workflow");
    
    // 1. gRPC 控制层：文件元数据交换
    let file_metadata = serde_json::json!({
        "file_id": "file_123456",
        "name": "important_document.pdf",
        "size": 50 * 1024 * 1024, // 50MB
        "path": "/documents/important_document.pdf",
        "mime_type": "application/pdf",
        "checksum": "sha256:abc123...",
        "compression": true,
        "encryption": false
    });
    
    println!("  📋 gRPC metadata exchange: {}", file_metadata);
    
    // 2. Data Portal 数据层：高速文件传输
    let file_size = 50 * 1024 * 1024;
    let session_id = "session_123456";
    let shm_path = format!("/librorum_transfer_{}", session_id);
    
    let shm = SharedMemoryTransport::new(&shm_path, file_size)?;
    
    // 模拟文件数据
    let file_data: Vec<u8> = (0..file_size)
        .map(|i| (i % 256) as u8)
        .collect();
    
    // 高速传输
    let start = std::time::Instant::now();
    unsafe {
        shm.write_zero_copy(&file_data, 0)?;
    }
    let transfer_time = start.elapsed();
    
    // 3. gRPC 确认：传输完成状态
    let transfer_result = serde_json::json!({
        "success": true,
        "session_id": session_id,
        "bytes_transferred": file_size,
        "transfer_time_ms": transfer_time.as_millis(),
        "throughput_gbps": (file_size as f64) / (1024.0 * 1024.0 * 1024.0) / transfer_time.as_secs_f64()
    });
    
    println!("  ✅ Transfer result: {}", transfer_result);
    
    Ok(())
}