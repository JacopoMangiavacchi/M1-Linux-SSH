import XCTest

#if !canImport(ObjectiveC)
public func allTests() -> [XCTestCaseEntry] {
    return [
        testCase(M1_Linux_SSHTests.allTests),
    ]
}
#endif
