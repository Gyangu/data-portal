//
//  DataPortalTests.swift
//  Data Portal Tests
//
//  Unit tests for Data Portal Protocol
//

import XCTest
@testable import DataPortal
@testable import DataPortalSharedMemory
@testable import DataPortalNetwork

final class DataPortalTests: XCTestCase {
    
    func testBasicFunctionality() {
        // Basic test to ensure the module compiles and loads
        XCTAssertNotNil(DataPortalSharedMemoryVersion.string)
        XCTAssertEqual(DataPortalSharedMemoryVersion.major, 0)
    }
    
    func testNodeInfoCreation() {
        let node = NodeInfo.local(id: "test-node", language: .swift)
        XCTAssertEqual(node.id, "test-node")
        XCTAssertEqual(node.language, .swift)
        XCTAssertTrue(node.isLocalMachine)
    }
    
    func testSharedMemoryProtocol() {
        // Test message creation
        let testData = Data("Hello, World!".utf8)
        XCTAssertNoThrow(try SharedMemoryMessage.data(testData))
        
        let message = try! SharedMemoryMessage.data(testData)
        XCTAssertEqual(message.payload, testData)
        XCTAssertEqual(message.header.magic, SHARED_MEMORY_MAGIC)
        XCTAssertEqual(message.header.version, SHARED_MEMORY_VERSION)
    }
    
    func testTransportConfiguration() {
        let config = TransportConfiguration.default
        XCTAssertTrue(config.enableSharedMemory)
        XCTAssertEqual(config.maxMessageSize, 64 * 1024 * 1024)
    }
    
    // Note: More comprehensive tests would require actual shared memory regions
    // which may not be available in all test environments
}