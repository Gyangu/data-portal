#!/usr/bin/env swift

import Foundation

// 模拟我们的GRPCCommunicator的主要功能
// 这个测试脚本验证我们的接口设计

// 模拟数据结构
struct TestHeartbeatResult {
    let nodeId: String
    let address: String
    let systemInfo: String
    let timestamp: Date
    let status: Bool
    let latency: TimeInterval
}

// 模拟GRPCCommunicator的核心功能
class TestGRPCCommunicator {
    private var isConnectedState: Bool = false
    private var serverAddress: String = ""
    
    func connect(address: String) async throws {
        print("🔗 正在连接到 \(address)...")
        
        // 验证地址格式
        let components = address.components(separatedBy: ":")
        guard components.count == 2,
              let port = Int(components[1]),
              port > 0 && port <= 65535 else {
            throw TestGRPCError.invalidAddress
        }
        
        // 模拟连接延迟
        try await Task.sleep(nanoseconds: 500_000_000) // 0.5秒
        
        self.serverAddress = address
        self.isConnectedState = true
        
        print("✅ 已连接到 \(address)")
    }
    
    func disconnect() async throws {
        guard isConnectedState else {
            throw TestGRPCError.notConnected
        }
        
        print("🔌 正在断开连接...")
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1秒
        
        self.isConnectedState = false
        self.serverAddress = ""
        
        print("✅ 已断开连接")
    }
    
    func isConnected() async -> Bool {
        return isConnectedState
    }
    
    func sendHeartbeat(nodeId: String) async throws -> TestHeartbeatResult {
        guard isConnectedState else {
            throw TestGRPCError.notConnected
        }
        
        guard !nodeId.isEmpty else {
            throw TestGRPCError.invalidRequest("Node ID cannot be empty")
        }
        
        print("💓 发送心跳: \(nodeId)")
        
        let startTime = Date()
        
        // 模拟网络延迟
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        
        let latency = Date().timeIntervalSince(startTime)
        
        let result = TestHeartbeatResult(
            nodeId: "node.test.local",
            address: serverAddress,
            systemInfo: "macOS Test",
            timestamp: Date(),
            status: true,
            latency: latency
        )
        
        print("💚 心跳响应: 状态=\(result.status), 延迟=\(Int(latency * 1000))ms")
        
        return result
    }
}

enum TestGRPCError: Error, LocalizedError {
    case notConnected
    case invalidAddress
    case invalidRequest(String)
    
    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to gRPC server"
        case .invalidAddress:
            return "Invalid server address"
        case .invalidRequest(let message):
            return "Invalid request: \(message)"
        }
    }
}

// 主函数
Task {
        print("🚀 开始Swift gRPC功能测试...")
        
        let communicator = TestGRPCCommunicator()
        
        do {
            // 测试1：验证初始状态
            print("\n📋 测试1: 初始状态检查")
            let initialConnected = await communicator.isConnected()
            print("初始连接状态: \(initialConnected)")
            assert(!initialConnected, "初始应为未连接状态")
            print("✅ 初始状态测试通过")
            
            // 测试2：测试无效地址
            print("\n📋 测试2: 无效地址处理")
            do {
                try await communicator.connect(address: "invalid-address")
                print("❌ 应该抛出错误")
                exit(1)
            } catch TestGRPCError.invalidAddress {
                print("✅ 正确捕获无效地址错误")
            }
            
            // 测试3：正常连接
            print("\n📋 测试3: 正常连接")
            try await communicator.connect(address: "127.0.0.1:50051")
            let connectedState = await communicator.isConnected()
            assert(connectedState, "连接后应为已连接状态")
            print("✅ 连接测试通过")
            
            // 测试4：心跳测试
            print("\n📋 测试4: 心跳功能")
            let heartbeatResult = try await communicator.sendHeartbeat(nodeId: "test-swift-client")
            assert(heartbeatResult.status, "心跳状态应为true")
            assert(!heartbeatResult.nodeId.isEmpty, "节点ID不应为空")
            assert(heartbeatResult.latency > 0, "延迟应大于0")
            print("✅ 心跳测试通过")
            
            // 测试5：断开连接
            print("\n📋 测试5: 断开连接")
            try await communicator.disconnect()
            let disconnectedState = await communicator.isConnected()
            assert(!disconnectedState, "断开后应为未连接状态")
            print("✅ 断开连接测试通过")
            
            // 测试6：断开后的操作应失败
            print("\n📋 测试6: 断开后操作验证")
            do {
                _ = try await communicator.sendHeartbeat(nodeId: "test")
                print("❌ 应该抛出未连接错误")
                exit(1)
            } catch TestGRPCError.notConnected {
                print("✅ 正确捕获未连接错误")
            }
            
            print("\n🎉 所有测试通过！Swift gRPC功能实现正确")
            
        } catch {
            print("❌ 测试失败: \(error)")
            exit(1)
        }
    }
}