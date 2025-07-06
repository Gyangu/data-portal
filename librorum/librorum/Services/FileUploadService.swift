//
//  FileUploadService.swift
//  librorum
//
//  集成 Data Portal 的文件上传服务
//  展示如何在现有文件操作中使用高性能传输
//

import Foundation
import SwiftUI
import OSLog

/// 文件上传结果
public struct FileUploadResult {
    public let success: Bool
    public let fileId: String?
    public let uploadTime: TimeInterval
    public let transferRate: Double
    public let usedDataPortal: Bool
    public let transferMode: String
    public let error: String?
    
    public init(
        success: Bool,
        fileId: String? = nil,
        uploadTime: TimeInterval = 0,
        transferRate: Double = 0,
        usedDataPortal: Bool = false,
        transferMode: String = "unknown",
        error: String? = nil
    ) {
        self.success = success
        self.fileId = fileId
        self.uploadTime = uploadTime
        self.transferRate = transferRate
        self.usedDataPortal = usedDataPortal
        self.transferMode = transferMode
        self.error = error
    }
}

/// 上传进度信息
public struct UploadProgress {
    public let fileName: String
    public let bytesUploaded: Int64
    public let totalBytes: Int64
    public let transferRate: Double
    public let estimatedTimeRemaining: TimeInterval?
    public let useDataPortal: Bool
    
    public var percentComplete: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(bytesUploaded) / Double(totalBytes) * 100.0
    }
}

/// 文件上传服务
@Observable
public class FileUploadService {
    private let logger = Logger(subsystem: "com.librorum", category: "FileUpload")
    
    // Data Portal 管理器 (唯一的传输方式)
    @ObservationIgnored private var dataPortalManager: DataPortalManager?
    
    // 上传配置
    public struct UploadConfig {
        public let enableZeroCopy: Bool
        public let compressionEnabled: Bool
        public let chunkSize: Int64 // 分块大小
        
        public init(
            enableZeroCopy: Bool = true,
            compressionEnabled: Bool = true,
            chunkSize: Int64 = 8 * 1024 * 1024 // 8MB 默认分块大小
        ) {
            self.enableZeroCopy = enableZeroCopy
            self.compressionEnabled = compressionEnabled
            self.chunkSize = chunkSize
        }
    }
    
    public let config: UploadConfig
    @ObservationIgnored public private(set) var isInitialized: Bool = false
    
    public init(config: UploadConfig = UploadConfig()) {
        self.config = config
    }
    
    /// 初始化上传服务 (仅使用 Data Portal)
    public func initialize() async throws {
        guard !isInitialized else { return }
        
        logger.info("🔧 初始化 Data Portal 文件上传服务...")
        
        // 初始化 Data Portal (唯一的传输方式)
        let dataPortalConfig = DataPortalConfig(
            mode: .auto,
            enableZeroCopy: config.enableZeroCopy,
            compressionEnabled: config.compressionEnabled
        )
        
        dataPortalManager = DataPortalManager(config: dataPortalConfig)
        try await dataPortalManager?.connect()
        
        isInitialized = true
        logger.info("✅ Data Portal 文件上传服务初始化完成")
    }
    
    /// 上传文件 (使用 Data Portal)
    public func uploadFile(
        localPath: String,
        remotePath: String,
        onProgress: @escaping (UploadProgress) -> Void = { _ in }
    ) async -> FileUploadResult {
        guard isInitialized else {
            return FileUploadResult(
                success: false,
                error: "Data Portal 上传服务未初始化"
            )
        }
        
        guard let dataPortalManager = dataPortalManager, dataPortalManager.isConnected else {
            return FileUploadResult(
                success: false,
                error: "Data Portal 未连接"
            )
        }
        
        guard FileManager.default.fileExists(atPath: localPath) else {
            return FileUploadResult(
                success: false,
                error: "本地文件不存在: \(localPath)"
            )
        }
        
        // 获取文件信息
        let fileURL = URL(fileURLWithPath: localPath)
        let fileName = fileURL.lastPathComponent
        let fileSize = getFileSize(at: localPath)
        
        logger.info("🚀 开始 Data Portal 上传: \(fileName) (\(formatFileSize(fileSize)))")
        
        return await uploadViaDataPortal(
            localPath: localPath,
            remotePath: remotePath,
            fileName: fileName,
            fileSize: fileSize,
            onProgress: onProgress
        )
    }
    
    /// 通过 Data Portal 上传
    private func uploadViaDataPortal(
        localPath: String,
        remotePath: String,
        fileName: String,
        fileSize: Int64,
        onProgress: @escaping (UploadProgress) -> Void
    ) async -> FileUploadResult {
        logger.info("🚀 使用 Data Portal 上传: \(fileName)")
        
        guard let dataPortalManager = dataPortalManager else {
            return FileUploadResult(
                success: false,
                error: "Data Portal 管理器不可用"
            )
        }
        
        let startTime = Date()
        
        do {
            // 创建上传会话
            let session = try await dataPortalManager.uploadFile(
                localPath: localPath,
                remotePath: remotePath,
                fileName: fileName
            )
            
            // 监控进度
            var lastProgress: Double = 0
            
            while session.status != .completed && 
                  session.status != .failed && 
                  session.status != .cancelled {
                
                let progress = UploadProgress(
                    fileName: fileName,
                    bytesUploaded: session.transferredBytes,
                    totalBytes: session.totalSize,
                    transferRate: session.transferRate,
                    estimatedTimeRemaining: session.estimatedTimeRemaining,
                    useDataPortal: true
                )
                
                onProgress(progress)
                
                // 避免过于频繁的更新
                if progress.percentComplete - lastProgress >= 1.0 {
                    lastProgress = progress.percentComplete
                    logger.debug("📊 Data Portal 上传进度: \(Int(progress.percentComplete))%")
                }
                
                try await Task.sleep(nanoseconds: 100_000_000) // 0.1秒
            }
            
            let uploadTime = Date().timeIntervalSince(startTime)
            let transferRate = uploadTime > 0 ? Double(fileSize) / uploadTime : 0
            
            if session.status == .completed {
                logger.info("✅ Data Portal 上传成功: \(fileName) (\(String(format: "%.2f", uploadTime))s, \(formatTransferRate(transferRate)))")
                
                return FileUploadResult(
                    success: true,
                    fileId: session.sessionId,
                    uploadTime: uploadTime,
                    transferRate: transferRate,
                    usedDataPortal: true,
                    transferMode: session.mode.rawValue
                )
            } else {
                return FileUploadResult(
                    success: false,
                    error: session.error ?? "Data Portal 上传失败",
                    usedDataPortal: true,
                    transferMode: session.mode.rawValue
                )
            }
            
        } catch {
            logger.error("❌ Data Portal 上传失败: \(error)")
            return FileUploadResult(
                success: false,
                error: "Data Portal 上传失败: \(error.localizedDescription)",
                usedDataPortal: true,
                transferMode: "failed"
            )
        }
    }
    
    
    /// 批量上传文件
    public func uploadMultipleFiles(
        files: [(localPath: String, remotePath: String)],
        onFileComplete: @escaping (String, FileUploadResult) -> Void = { _, _ in },
        onProgress: @escaping (String, UploadProgress) -> Void = { _, _ in }
    ) async -> [FileUploadResult] {
        var results: [FileUploadResult] = []
        
        for (localPath, remotePath) in files {
            let fileName = URL(fileURLWithPath: localPath).lastPathComponent
            
            let result = await uploadFile(
                localPath: localPath,
                remotePath: remotePath
            ) { progress in
                onProgress(fileName, progress)
            }
            
            results.append(result)
            onFileComplete(fileName, result)
            
            logger.info("📁 文件上传完成: \(fileName) (成功: \(result.success))")
        }
        
        return results
    }
    
    /// 断开连接
    public func disconnect() async {
        dataPortalManager?.disconnect()
        dataPortalManager = nil
        isInitialized = false
        
        logger.info("🔌 Data Portal 文件上传服务已断开连接")
    }
    
    // MARK: - Helper Methods
    
    private func getFileSize(at path: String) -> Int64 {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            return attributes[.size] as? Int64 ?? 0
        } catch {
            return 0
        }
    }
}

// MARK: - Performance Metrics Helper

/// Data Portal 性能指标
public struct DataPortalPerformanceMetrics {
    public let transferTime: TimeInterval
    public let transferRate: Double
    public let fileSize: Int64
    public let usedZeroCopy: Bool
    public let compressionRatio: Double?
    
    public var performanceTier: PerformanceTier {
        let rateMBps = transferRate / (1024 * 1024)
        
        if usedZeroCopy && rateMBps > 50000 { // > 50 GB/s
            return .extreme
        } else if rateMBps > 5000 { // > 5 GB/s
            return .high
        } else if rateMBps > 500 { // > 500 MB/s
            return .medium
        } else {
            return .standard
        }
    }
    
    public var summary: String {
        let compressionNote = compressionRatio.map { 
            "\n压缩比例: \(String(format: "%.1f", $0))x" 
        } ?? ""
        
        return """
        Data Portal 性能报告:
        文件大小: \(formatFileSize(fileSize))
        传输时间: \(String(format: "%.2f", transferTime))秒
        传输速率: \(formatTransferRate(transferRate))
        零拷贝模式: \(usedZeroCopy ? "✅" : "❌")
        性能等级: \(performanceTier.displayName)\(compressionNote)
        """
    }
}

public enum PerformanceTier {
    case extreme    // > 50 GB/s
    case high       // > 5 GB/s  
    case medium     // > 500 MB/s
    case standard   // < 500 MB/s
    
    public var displayName: String {
        switch self {
        case .extreme: return "🚀 极致性能"
        case .high: return "⚡ 高性能"
        case .medium: return "🔥 中等性能"
        case .standard: return "📊 标准性能"
        }
    }
}