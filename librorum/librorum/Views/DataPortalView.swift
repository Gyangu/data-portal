//
//  DataPortalView.swift
//  librorum
//
//  Data Portal 高性能传输界面
//  展示零拷贝传输性能和状态
//

import SwiftUI

struct DataPortalView: View {
    @StateObject private var dataPortalManager = DataPortalManager(config: DataPortalConfig())
    @State private var selectedFile: URL?
    @State private var uploadProgress: Double = 0.0
    @State private var isUploading = false
    @State private var showFileImporter = false
    @State private var performanceMetrics: PerformanceMetrics = PerformanceMetrics()
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                headerSection
                
                connectionStatusSection
                
                if dataPortalManager.isConnected {
                    transferControlsSection
                    
                    activeSessionsSection
                    
                    performanceSection
                } else {
                    connectButtonSection
                }
                
                Spacer()
            }
            .padding()
            .navigationTitle("Data Portal")
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.data],
                allowsMultipleSelection: false
            ) { result in
                handleFileSelection(result)
            }
            .onAppear {
                setupDataPortal()
            }
        }
    }
    
    // MARK: - UI Sections
    
    private var headerSection: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "bolt.circle.fill")
                    .foregroundColor(.blue)
                    .font(.title)
                
                VStack(alignment: .leading) {
                    Text("Data Portal")
                        .font(.title2)
                        .fontWeight(.bold)
                    
                    Text("唯一文件传输引擎 - 零拷贝优先")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                VStack(alignment: .trailing) {
                    Label(dataPortalManager.config.mode.rawValue, systemImage: "speedometer")
                        .font(.caption)
                        .foregroundColor(.blue)
                    
                    if dataPortalManager.config.enableZeroCopy {
                        Label("零拷贝", systemImage: "memorychip")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                }
            }
            
            Divider()
        }
    }
    
    private var connectionStatusSection: some View {
        HStack {
            Circle()
                .fill(dataPortalManager.isConnected ? Color.green : Color.red)
                .frame(width: 12, height: 12)
            
            Text(dataPortalManager.isConnected ? "已连接" : "未连接")
                .font(.subheadline)
                .fontWeight(.medium)
            
            Spacer()
            
            if let connectionTime = dataPortalManager.connectionTime {
                Text("连接时间: \\(formatConnectionTime(connectionTime))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(10)
    }
    
    private var connectButtonSection: some View {
        VStack(spacing: 16) {
            Button(action: connectToDataPortal) {
                HStack {
                    Image(systemName: "power")
                    Text("连接 Data Portal")
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(10)
            }
            
            Text("连接到 Data Portal 以开始高性能文件传输")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
    }
    
    private var transferControlsSection: some View {
        VStack(spacing: 16) {
            HStack {
                Text("文件传输")
                    .font(.headline)
                
                Spacer()
                
                Button(action: { showFileImporter = true }) {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                        Text("选择文件")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.blue.opacity(0.1))
                    .foregroundColor(.blue)
                    .cornerRadius(8)
                }
                .disabled(isUploading)
            }
            
            if let selectedFile = selectedFile {
                selectedFileCard(file: selectedFile)
            }
        }
    }
    
    private func selectedFileCard(file: URL) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "doc.fill")
                    .foregroundColor(.blue)
                
                VStack(alignment: .leading) {
                    Text(file.lastPathComponent)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    
                    if let fileSize = getFileSize(file) {
                        Text(formatFileSize(fileSize))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                if isUploading {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    Button("上传") {
                        uploadSelectedFile()
                    }
                    .buttonStyle(.bordered)
                }
            }
            
            if isUploading {
                VStack(spacing: 8) {
                    ProgressView(value: uploadProgress)
                        .progressViewStyle(LinearProgressViewStyle())
                    
                    HStack {
                        Text("\\(Int(uploadProgress * 100))%")
                            .font(.caption)
                        
                        Spacer()
                        
                        if performanceMetrics.transferRate > 0 {
                            Text(formatTransferRate(performanceMetrics.transferRate))
                                .font(.caption)
                                .foregroundColor(.blue)
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(10)
    }
    
    private var activeSessionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("活跃会话")
                    .font(.headline)
                
                Spacer()
                
                Text("\\(dataPortalManager.activeSessions.count)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            if dataPortalManager.activeSessions.isEmpty {
                Text("没有活跃的传输会话")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding()
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(Array(dataPortalManager.activeSessions.values), id: \\.id) { session in
                        sessionRow(session: session)
                    }
                }
            }
        }
    }
    
    private func sessionRow(session: DataPortalSession) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.fileName)
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                HStack {
                    Text(session.status.rawValue)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(statusColor(session.status).opacity(0.2))
                        .foregroundColor(statusColor(session.status))
                        .cornerRadius(4)
                    
                    if session.isZeroCopyMode {
                        Text("零拷贝")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.2))
                            .foregroundColor(.green)
                            .cornerRadius(4)
                    }
                }
            }
            
            Spacer()
            
            VStack(alignment: .trailing, spacing: 4) {
                Text("\\(Int(session.progressPercent))%")
                    .font(.caption)
                    .fontWeight(.medium)
                
                if session.transferRate > 0 {
                    Text(formatTransferRate(session.transferRate))
                        .font(.caption)
                        .foregroundColor(.blue)
                }
            }
            
            Button(action: {
                dataPortalManager.cancelSession(session.sessionId)
            }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(8)
    }
    
    private var performanceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("性能指标")
                .font(.headline)
            
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 12) {
                performanceCard(
                    title: "平均传输速率",
                    value: formatTransferRate(performanceMetrics.averageRate),
                    icon: "speedometer",
                    color: .blue
                )
                
                performanceCard(
                    title: "零拷贝加速比",
                    value: String(format: "%.1fx", performanceMetrics.zeroCopySpeedup),
                    icon: "bolt.fill",
                    color: .green
                )
                
                performanceCard(
                    title: "成功传输",
                    value: "\\(performanceMetrics.successCount)",
                    icon: "checkmark.circle.fill",
                    color: .green
                )
                
                performanceCard(
                    title: "失败传输",
                    value: "\\(performanceMetrics.failureCount)",
                    icon: "xmark.circle.fill",
                    color: .red
                )
            }
        }
    }
    
    private func performanceCard(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(color)
                Spacer()
            }
            
            VStack(alignment: .leading) {
                Text(value)
                    .font(.title2)
                    .fontWeight(.bold)
                
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(10)
    }
    
    // MARK: - Helper Functions
    
    private func setupDataPortal() {
        dataPortalManager.addEventHandler { event in
            DispatchQueue.main.async {
                handleDataPortalEvent(event)
            }
        }
    }
    
    private func connectToDataPortal() {
        Task {
            do {
                try await dataPortalManager.connect()
            } catch {
                print("连接 Data Portal 失败: \\(error)")
            }
        }
    }
    
    private func handleFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            if let url = urls.first {
                selectedFile = url
            }
        case .failure(let error):
            print("文件选择失败: \\(error)")
        }
    }
    
    private func uploadSelectedFile() {
        guard let file = selectedFile else { return }
        
        isUploading = true
        uploadProgress = 0.0
        
        Task {
            do {
                let session = try await dataPortalManager.uploadFile(
                    localPath: file.path,
                    remotePath: "/uploads/\\(file.lastPathComponent)"
                )
                
                print("上传开始: \\(session.sessionId)")
                
            } catch {
                DispatchQueue.main.async {
                    isUploading = false
                    print("上传失败: \\(error)")
                }
            }
        }
    }
    
    private func handleDataPortalEvent(_ event: DataPortalEvent) {
        switch event {
        case .transferProgress(_, let bytes, let totalBytes, let rate):
            uploadProgress = Double(bytes) / Double(totalBytes)
            performanceMetrics.transferRate = rate
            
        case .transferCompleted(_, let success, _, _, let averageRate):
            isUploading = false
            uploadProgress = success ? 1.0 : 0.0
            performanceMetrics.averageRate = averageRate
            
            if success {
                performanceMetrics.successCount += 1
            } else {
                performanceMetrics.failureCount += 1
            }
            
        case .performanceMetrics(_, let zeroCopySpeedup, _):
            if let speedup = zeroCopySpeedup {
                performanceMetrics.zeroCopySpeedup = speedup
            }
            
        default:
            break
        }
    }
    
    private func getFileSize(_ url: URL) -> Int64? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return attributes[.size] as? Int64
        } catch {
            return nil
        }
    }
    
    private func statusColor(_ status: DataPortalSessionStatus) -> Color {
        switch status {
        case .completed:
            return .green
        case .failed, .cancelled:
            return .red
        case .transferring:
            return .blue
        default:
            return .orange
        }
    }
    
    private func formatConnectionTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
}

// MARK: - Performance Metrics

private struct PerformanceMetrics {
    var transferRate: Double = 0.0
    var averageRate: Double = 0.0
    var zeroCopySpeedup: Double = 1.0
    var successCount: Int = 0
    var failureCount: Int = 0
}

// MARK: - Preview

struct DataPortalView_Previews: PreviewProvider {
    static var previews: some View {
        DataPortalView()
    }
}