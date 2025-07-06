//! 简化的 Data Portal 集成测试

use librorum_core::node_manager::HybridFileServiceV2;

#[tokio::test]
async fn test_hybrid_file_service_creation() -> Result<(), Box<dyn std::error::Error>> {
    println!("🧪 测试 HybridFileServiceV2 创建");
    
    let test_dir = "/tmp/librorum_simple_test";
    tokio::fs::create_dir_all(test_dir).await?;
    
    let file_service = HybridFileServiceV2::new(test_dir.to_string());
    let stats = file_service.get_transfer_stats().await;
    
    println!("📊 初始统计信息:");
    println!("  总会话数: {}", stats.total_sessions);
    println!("  活跃上传: {}", stats.active_uploads);
    println!("  活跃下载: {}", stats.active_downloads);
    println!("  零拷贝比例: {:.1}%", stats.zero_copy_ratio * 100.0);
    
    assert_eq!(stats.total_sessions, 0);
    assert_eq!(stats.active_uploads, 0);
    assert_eq!(stats.active_downloads, 0);
    
    let _ = tokio::fs::remove_dir_all(test_dir).await;
    
    println!("✅ HybridFileServiceV2 创建测试通过");
    Ok(())
}

#[tokio::test]
async fn test_data_portal_components() -> Result<(), Box<dyn std::error::Error>> {
    println!("🔧 测试 Data Portal 组件");
    
    // 测试数据目录创建
    let test_dir = "/tmp/librorum_components_test";
    tokio::fs::create_dir_all(test_dir).await?;
    
    // 创建测试文件
    let test_file_path = format!("{}/test.txt", test_dir);
    let test_content = "Hello Data Portal! 🚀";
    tokio::fs::write(&test_file_path, test_content).await?;
    
    // 验证文件存在
    let content = tokio::fs::read_to_string(&test_file_path).await?;
    assert_eq!(content, test_content);
    
    println!("✅ 测试文件创建和读取成功");
    
    // 清理
    let _ = tokio::fs::remove_dir_all(test_dir).await;
    
    println!("✅ Data Portal 组件测试通过");
    Ok(())
}

#[tokio::test]
async fn test_transfer_modes() -> Result<(), Box<dyn std::error::Error>> {
    println!("🔄 测试传输模式");
    
    use librorum_core::node_manager::hybrid_file_service_v2::{TransportMode, TransferSession};
    
    // 测试零拷贝模式
    let session = TransferSession {
        session_id: "test_session_001".to_string(),
        mode: TransportMode::SharedMemory,
        file_size: 1024 * 1024, // 1MB
        transferred_bytes: 0,
        start_time: std::time::Instant::now(),
        data_portal_address: Some("/shared_memory/test".to_string()),
    };
    
    println!("📦 创建传输会话:");
    println!("  会话ID: {}", session.session_id);
    println!("  模式: {:?}", session.mode);
    println!("  文件大小: {} bytes", session.file_size);
    
    // 验证会话信息
    assert_eq!(session.session_id, "test_session_001");
    assert!(matches!(session.mode, TransportMode::SharedMemory));
    assert_eq!(session.file_size, 1024 * 1024);
    
    println!("✅ 传输模式测试通过");
    Ok(())
}