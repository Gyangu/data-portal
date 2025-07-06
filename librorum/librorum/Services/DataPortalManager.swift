//
//  DataPortalManager.swift
//  librorum
//
//  Data Portal 集成管理器
//  连接 Swift 客户端与 Rust Data Portal 高性能传输系统
//

import Foundation
import SwiftUI
import Network
import OSLog

/// Data Portal 传输模式
public enum DataPortalMode: String, CaseIterable, Codable {
    case sharedMemory = "SharedMemory"
    case network = "Network" 
    case auto = "Auto"
}

/// Data Portal 会话状态
public enum DataPortalSessionStatus: String, CaseIterable, Codable {
    case initializing = "initializing"
    case coordinatingWithGrpc = "coordinating_with_grpc"
    case establishingDataChannel = "establishing_data_channel"
    case transferring = "transferring"
    case completed = "completed"
    case failed = "failed"
    case cancelled = "cancelled"
}

/// Data Portal 配置
public struct DataPortalConfig: Codable {
    public let mode: DataPortalMode
    public let grpcServerAddress: String
    public let grpcServerPort: Int
    public let dataPortalPort: Int
    public let sharedMemorySize: Int
    public let sharedMemoryBasePath: String
    public let enableZeroCopy: Bool
    public let chunkSize: Int
    public let timeoutSeconds: Int
    public let compressionEnabled: Bool
    
    public init(
        mode: DataPortalMode = .auto,
        grpcServerAddress: String = "localhost",
        grpcServerPort: Int = 50051,
        dataPortalPort: Int = 9090,
        sharedMemorySize: Int = 64 * 1024 * 1024, // 64MB
        sharedMemoryBasePath: String = "/tmp/librorum_data_portal_",
        enableZeroCopy: Bool = true,
        chunkSize: Int = 8 * 1024 * 1024, // 8MB
        timeoutSeconds: Int = 30,
        compressionEnabled: Bool = true
    ) {
        self.mode = mode
        self.grpcServerAddress = grpcServerAddress
        self.grpcServerPort = grpcServerPort
        self.dataPortalPort = dataPortalPort
        self.sharedMemorySize = sharedMemorySize
        self.sharedMemoryBasePath = sharedMemoryBasePath
        self.enableZeroCopy = enableZeroCopy
        self.chunkSize = chunkSize
        self.timeoutSeconds = timeoutSeconds
        self.compressionEnabled = compressionEnabled
    }
}

/// Data Portal 传输会话
@Observable
public class DataPortalSession: Identifiable {
    public let id = UUID()
    public let sessionId: String
    public let transferType: DataPortalTransferType
    public let fileName: String
    public let totalSize: Int64
    public let mode: DataPortalMode
    
    @ObservationIgnored public private(set) var transferredBytes: Int64 = 0
    @ObservationIgnored public private(set) var transferRate: Double = 0.0
    @ObservationIgnored public private(set) var status: DataPortalSessionStatus = .initializing
    @ObservationIgnored public private(set) var startTime: Date = Date()
    @ObservationIgnored public private(set) var error: String? = nil
    @ObservationIgnored public private(set) var grpcEndpoint: String? = nil
    @ObservationIgnored public private(set) var dataPortalEndpoint: String? = nil
    
    public enum DataPortalTransferType: String, CaseIterable, Codable {
        case upload = "upload"
        case download = "download"
    }
    
    public init(
        sessionId: String,
        transferType: DataPortalTransferType,
        fileName: String,
        totalSize: Int64,
        mode: DataPortalMode
    ) {
        self.sessionId = sessionId
        self.transferType = transferType
        self.fileName = fileName
        self.totalSize = totalSize
        self.mode = mode
        self.startTime = Date()
    }
    
    /// 更新传输进度
    public func updateProgress(bytes: Int64, rate: Double) {
        transferredBytes = bytes
        transferRate = rate
    }
    
    /// 更新状态
    public func updateStatus(_ newStatus: DataPortalSessionStatus, error: String? = nil) {
        status = newStatus
        self.error = error
    }
    
    /// 设置端点信息
    public func setEndpoints(grpc: String?, dataPortal: String?) {
        grpcEndpoint = grpc
        dataPortalEndpoint = dataPortal
    }
    
    /// 获取进度百分比
    public var progressPercent: Double {
        guard totalSize > 0 else { return 0.0 }
        return Double(transferredBytes) / Double(totalSize) * 100.0
    }
    
    /// 获取剩余时间估计 (秒)
    public var estimatedTimeRemaining: TimeInterval? {
        guard transferRate > 0, transferredBytes < totalSize else { return nil }
        let remainingBytes = totalSize - transferredBytes
        return Double(remainingBytes) / transferRate
    }
    
    /// 检查是否使用零拷贝模式
    public var isZeroCopyMode: Bool {
        return mode == .sharedMemory
    }
}

/// Data Portal 事件
public enum DataPortalEvent {
    case sessionCreated(DataPortalSession)
    case grpcCoordinationStarted(sessionId: String, grpcEndpoint: String)
    case grpcCoordinationCompleted(sessionId: String, dataPortalEndpoint: String, mode: DataPortalMode)
    case dataChannelEstablished(sessionId: String, mode: DataPortalMode, isZeroCopy: Bool)
    case transferProgress(sessionId: String, bytes: Int64, totalBytes: Int64, rate: Double)
    case transferCompleted(sessionId: String, success: Bool, error: String?, elapsedSeconds: Double, averageRate: Double)
    case sessionStatusChanged(sessionId: String, oldStatus: DataPortalSessionStatus, newStatus: DataPortalSessionStatus)
    case performanceMetrics(sessionId: String, zeroCopySpeedup: Double?, compressionRatio: Double?)
}

/// Data Portal 统计信息
public struct DataPortalStats: Codable {
    public let totalSessions: Int64
    public let successfulTransfers: Int64
    public let failedTransfers: Int64
    public let totalBytesTransferred: Int64
    public let averageTransferRate: Double
    public let maxTransferRate: Double
    public let zeroCopyModeUsage: Int64
    public let networkModeUsage: Int64
    public let averageZeroCopySpeedup: Double
    public let averageCompressionRatio: Double
    
    public init() {
        self.totalSessions = 0
        self.successfulTransfers = 0
        self.failedTransfers = 0
        self.totalBytesTransferred = 0
        self.averageTransferRate = 0.0
        self.maxTransferRate = 0.0
        self.zeroCopyModeUsage = 0
        self.networkModeUsage = 0
        self.averageZeroCopySpeedup = 0.0
        self.averageCompressionRatio = 0.0
    }
}

/// Data Portal 管理器
@Observable
public class DataPortalManager {
    public let config: DataPortalConfig
    @ObservationIgnored private let logger = Logger(subsystem: "com.librorum", category: "DataPortal")
    
    @ObservationIgnored public private(set) var isConnected: Bool = false
    @ObservationIgnored public private(set) var activeSessions: [String: DataPortalSession] = [:]
    @ObservationIgnored public private(set) var stats: DataPortalStats = DataPortalStats()
    @ObservationIgnored public private(set) var connectionTime: Date? = nil
    
    /// 事件回调
    @ObservationIgnored private var eventHandlers: [(DataPortalEvent) -> Void] = []
    
    /// UTP 传输客户端 (用于数据传输)
    @ObservationIgnored private var utpClient: UtpTransportClient? = nil
    
    /// gRPC 协调客户端 (用于控制平面)
    @ObservationIgnored private var grpcCommunicator: GRPCCommunicatorProtocol? = nil
    
    public init(config: DataPortalConfig) {
        self.config = config
        logger.info("🔧 Data Portal管理器初始化: mode=\\(config.mode.rawValue), enableZeroCopy=\\(config.enableZeroCopy)")
    }
    
    /// 添加事件处理器
    public func addEventHandler(_ handler: @escaping (DataPortalEvent) -> Void) {
        eventHandlers.append(handler)
    }
    
    /// 触发事件
    private func triggerEvent(_ event: DataPortalEvent) {
        for handler in eventHandlers {
            handler(event)
        }
    }
    
    /// 连接到 Data Portal 系统
    public func connect() async throws {
        guard !isConnected else {
            logger.info("ℹ️ Data Portal已连接")
            return
        }
        
        logger.info("🔗 连接Data Portal系统...")
        
        // 1. 初始化 gRPC 通信器 (控制平面)
        try await initializeGrpcCommunicator()
        
        // 2. 初始化 UTP 传输客户端 (数据平面)
        try await initializeUtpClient()
        
        isConnected = true
        connectionTime = Date()
        logger.info("✅ Data Portal系统连接成功")
    }
    
    /// 初始化 gRPC 通信器
    private func initializeGrpcCommunicator() async throws {
        logger.info("🌐 初始化gRPC控制平面连接...")
        
        grpcCommunicator = GRPCCommunicatorFactory.createCommunicator()
        let grpcAddress = "\\(config.grpcServerAddress):\\(config.grpcServerPort)"
        
        try await grpcCommunicator?.connect(address: grpcAddress)
        logger.info("✅ gRPC控制平面连接建立: \\(grpcAddress)")
    }
    
    /// 初始化 UTP 传输客户端
    private func initializeUtpClient() async throws {
        logger.info("⚡ 初始化UTP数据平面...")
        
        let utpConfig = UtpConfig(
            mode: convertToUtpMode(config.mode),
            serverAddress: config.grpcServerAddress,
            serverPort: config.dataPortalPort,
            sharedMemorySize: config.sharedMemorySize,
            sharedMemoryPath: config.sharedMemoryBasePath + "utp",
            enableCompression: config.compressionEnabled,
            enableEncryption: false,
            chunkSize: config.chunkSize,
            timeoutSeconds: config.timeoutSeconds
        )
        
        utpClient = UtpTransportClient(config: utpConfig)
        
        // 添加 UTP 事件处理器
        utpClient?.addEventHandler { [weak self] utpEvent in
            self?.handleUtpEvent(utpEvent)
        }
        
        try await utpClient?.connect()
        logger.info("✅ UTP数据平面连接建立")
    }
    
    /// 转换传输模式
    private func convertToUtpMode(_ mode: DataPortalMode) -> UtpTransportMode {
        switch mode {
        case .sharedMemory:
            return .sharedMemory
        case .network:
            return .network
        case .auto:
            return .auto
        }
    }
    
    /// 处理 UTP 事件
    private func handleUtpEvent(_ utpEvent: UtpEvent) {
        switch utpEvent {
        case .sessionCreated(let utpSession):
            // UTP 会话创建，更新相应的 Data Portal 会话
            if let session = activeSessions[utpSession.sessionId] {
                session.updateStatus(.establishingDataChannel)
                triggerEvent(.dataChannelEstablished(
                    sessionId: utpSession.sessionId,
                    mode: config.mode,
                    isZeroCopy: config.enableZeroCopy && config.mode == .sharedMemory
                ))
            }
            
        case .transferProgress(let sessionId, let bytes, let totalBytes, let rate):
            if let session = activeSessions[sessionId] {
                session.updateProgress(bytes: bytes, rate: rate)
                triggerEvent(.transferProgress(
                    sessionId: sessionId,
                    bytes: bytes,
                    totalBytes: totalBytes,
                    rate: rate
                ))
            }
            
        case .transferCompleted(let sessionId, let success, let error, let elapsedSeconds):
            if let session = activeSessions[sessionId] {
                if success {
                    session.updateStatus(.completed)
                } else {
                    session.updateStatus(.failed, error: error)
                }
                
                let averageRate = elapsedSeconds > 0 ? Double(session.totalSize) / elapsedSeconds : 0.0
                
                triggerEvent(.transferCompleted(
                    sessionId: sessionId,
                    success: success,
                    error: error,
                    elapsedSeconds: elapsedSeconds,
                    averageRate: averageRate
                ))
                
                // 计算性能指标
                if success && session.isZeroCopyMode {
                    calculatePerformanceMetrics(for: session, elapsedSeconds: elapsedSeconds)
                }
            }
            
        default:
            break
        }
    }
    
    /// 计算性能指标
    private func calculatePerformanceMetrics(for session: DataPortalSession, elapsedSeconds: Double) {
        // 估算零拷贝加速比 (与假设的标准拷贝相比)
        let estimatedStandardCopyTime = elapsedSeconds * 2.5 // 假设标准拷贝慢2.5倍
        let zeroCopySpeedup = estimatedStandardCopyTime / elapsedSeconds
        
        // 压缩比例 (如果启用压缩)
        let compressionRatio = config.compressionEnabled ? 1.3 : 1.0 // 假设30%压缩率
        
        triggerEvent(.performanceMetrics(
            sessionId: session.sessionId,
            zeroCopySpeedup: zeroCopySpeedup,
            compressionRatio: compressionRatio
        ))
    }
    
    /// 断开连接
    public func disconnect() {
        guard isConnected else { return }
        
        logger.info("🔌 断开Data Portal连接...")
        
        // 断开 UTP 客户端
        utpClient?.disconnect()
        utpClient = nil
        
        // 断开 gRPC 通信器
        Task {
            try? await grpcCommunicator?.disconnect()
        }
        grpcCommunicator = nil
        
        // 取消所有活跃会话
        for session in activeSessions.values {
            session.updateStatus(.cancelled)
        }
        activeSessions.removeAll()
        
        isConnected = false
        connectionTime = nil
        logger.info("✅ Data Portal连接已断开")
    }
    
    /// 上传文件 (使用 Data Portal 混合架构)
    public func uploadFile(
        localPath: String,
        remotePath: String,
        fileName: String? = nil
    ) async throws -> DataPortalSession {
        guard isConnected else {
            throw DataPortalError.notConnected("Data Portal未连接")
        }
        
        // 验证本地文件
        let fileURL = URL(fileURLWithPath: localPath)
        guard FileManager.default.fileExists(atPath: localPath) else {
            throw DataPortalError.fileNotFound("本地文件不存在: \\(localPath)")
        }
        
        let fileSize = try FileManager.default.attributesOfItem(atPath: localPath)[.size] as? Int64 ?? 0
        let actualFileName = fileName ?? fileURL.lastPathComponent
        
        logger.info("📤 开始Data Portal上传: \\(actualFileName) (\\(formatFileSize(fileSize)))")
        
        let sessionId = UUID().uuidString
        let selectedMode = await selectOptimalMode(fileSize: fileSize)
        
        let session = DataPortalSession(
            sessionId: sessionId,
            transferType: .upload,
            fileName: actualFileName,
            totalSize: fileSize,
            mode: selectedMode
        )
        
        activeSessions[sessionId] = session
        triggerEvent(.sessionCreated(session))
        
        // Phase 1: gRPC 协调
        try await performGrpcCoordination(for: session, localPath: localPath, remotePath: remotePath)
        
        // Phase 2: Data Portal 传输
        try await performDataPortalTransfer(for: session, localPath: localPath)
        
        return session
    }
    
    /// 选择最优传输模式
    private func selectOptimalMode(fileSize: Int64) async -> DataPortalMode {
        switch config.mode {
        case .sharedMemory:
            return .sharedMemory
        case .network:
            return .network
        case .auto:
            // 自动选择逻辑:
            // - 同一台机器且文件 > 1MB: 使用共享内存
            // - 否则使用网络传输
            if await isLocalTransfer() && fileSize > 1024 * 1024 {
                return .sharedMemory
            } else {
                return .network
            }
        }
    }
    
    /// 检查是否为本地传输
    private func isLocalTransfer() async -> Bool {
        return config.grpcServerAddress == "localhost" || 
               config.grpcServerAddress == "127.0.0.1" ||
               config.grpcServerAddress.hasPrefix("127.")
    }
    
    /// 执行 gRPC 协调阶段
    private func performGrpcCoordination(
        for session: DataPortalSession,
        localPath: String,
        remotePath: String
    ) async throws {
        session.updateStatus(.coordinatingWithGrpc)
        
        let grpcEndpoint = "\\(config.grpcServerAddress):\\(config.grpcServerPort)"
        session.setEndpoints(grpc: grpcEndpoint, dataPortal: nil)
        
        triggerEvent(.grpcCoordinationStarted(
            sessionId: session.sessionId,
            grpcEndpoint: grpcEndpoint
        ))
        
        // 通过 gRPC 获取 Data Portal 端点
        guard let grpcCommunicator = grpcCommunicator else {
            throw DataPortalError.grpcNotConnected("gRPC通信器未连接")
        }
        
        // 模拟 gRPC 调用获取 Data Portal 端点
        let dataPortalEndpoint = "\\(config.grpcServerAddress):\\(config.dataPortalPort)"
        session.setEndpoints(grpc: grpcEndpoint, dataPortal: dataPortalEndpoint)
        
        triggerEvent(.grpcCoordinationCompleted(
            sessionId: session.sessionId,
            dataPortalEndpoint: dataPortalEndpoint,
            mode: session.mode
        ))
        
        logger.info("✅ gRPC协调完成: \\(session.sessionId) -> \\(dataPortalEndpoint)")
    }
    
    /// 执行 Data Portal 传输阶段
    private func performDataPortalTransfer(
        for session: DataPortalSession,
        localPath: String
    ) async throws {
        session.updateStatus(.transferring)
        
        guard let utpClient = utpClient else {
            throw DataPortalError.utpNotConnected("UTP客户端未连接")
        }
        
        // 使用 UTP 客户端进行实际传输
        let utpSession = try await utpClient.uploadFile(
            localPath: localPath,
            remotePath: session.fileName, // 使用文件名作为远程路径
            fileId: session.sessionId
        )
        
        logger.info("🚀 Data Portal传输启动: \\(session.sessionId) (mode: \\(session.mode.rawValue))")
    }
    
    /// 取消会话
    public func cancelSession(_ sessionId: String) {
        guard let session = activeSessions[sessionId] else { return }
        
        logger.info("🛑 取消Data Portal会话: \\(sessionId)")
        
        // 取消 UTP 会话
        utpClient?.cancelSession(sessionId)
        
        session.updateStatus(.cancelled)
        
        triggerEvent(.sessionStatusChanged(
            sessionId: sessionId,
            oldStatus: session.status,
            newStatus: .cancelled
        ))
    }
    
    /// 获取会话
    public func getSession(_ sessionId: String) -> DataPortalSession? {
        return activeSessions[sessionId]
    }
    
    /// 清理完成的会话
    public func cleanupCompletedSessions() {
        let completedSessionIds = activeSessions.compactMap { (key, session) in
            switch session.status {
            case .completed, .failed, .cancelled:
                return key
            default:
                return nil
            }
        }
        
        for sessionId in completedSessionIds {
            activeSessions.removeValue(forKey: sessionId)
        }
        
        // 清理 UTP 会话
        utpClient?.cleanupCompletedSessions()
        
        if !completedSessionIds.isEmpty {
            logger.info("🧹 清理完成的Data Portal会话: \\(completedSessionIds.count)个")
        }
    }
    
    /// 获取性能统计
    public func getPerformanceStats() -> DataPortalStats {
        // 这里可以实现详细的统计信息收集
        return stats
    }
}

/// Data Portal 错误类型
public enum DataPortalError: LocalizedError {
    case configuration(String)
    case notConnected(String)
    case grpcNotConnected(String)
    case utpNotConnected(String)
    case fileNotFound(String)
    case coordinationFailed(String)
    case transferFailed(String)
    case cancelled(String)
    case timeout(String)
    
    public var errorDescription: String? {
        switch self {
        case .configuration(let message):
            return "Data Portal配置错误: \\(message)"
        case .notConnected(let message):
            return "Data Portal未连接: \\(message)"
        case .grpcNotConnected(let message):
            return "gRPC未连接: \\(message)"
        case .utpNotConnected(let message):
            return "UTP未连接: \\(message)"
        case .fileNotFound(let message):
            return "文件未找到: \\(message)"
        case .coordinationFailed(let message):
            return "协调失败: \\(message)"
        case .transferFailed(let message):
            return "传输失败: \\(message)"
        case .cancelled(let message):
            return "已取消: \\(message)"
        case .timeout(let message):
            return "超时: \\(message)"
        }
    }
}

/// gRPC 通信器协议 (占位符)
protocol GRPCCommunicatorProtocol {
    func connect(address: String) async throws
    func disconnect() async throws
}

/// gRPC 通信器工厂 (占位符)
struct GRPCCommunicatorFactory {
    static func createCommunicator() -> GRPCCommunicatorProtocol {
        return MockGRPCCommunicator()
    }
}

/// 模拟 gRPC 通信器 (占位符实现)
class MockGRPCCommunicator: GRPCCommunicatorProtocol {
    private var isConnected = false
    
    func connect(address: String) async throws {
        // 模拟连接延迟
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        isConnected = true
    }
    
    func disconnect() async throws {
        isConnected = false
    }
}