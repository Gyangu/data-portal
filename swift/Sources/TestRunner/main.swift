//
//  main.swift
//  Universal Transport Protocol Test Runner
//
//  Swift端性能测试运行器
//

import Foundation
import UniversalTransport

@main
struct TestRunner {
    static func main() async {
        await SwiftCrossLanguageTest.runAllSwiftTests()
    }
}