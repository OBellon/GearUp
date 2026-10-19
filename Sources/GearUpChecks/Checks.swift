import Foundation

/// A deliberately tiny assertion helper.
///
/// GearUp is built with the Command Line Tools only, which do not ship XCTest
/// or swift-testing. Rather than add a dependency, the checks are plain
/// functions that report through this type.
final class Checks {
    static let shared = Checks()

    private(set) var passed = 0
    private(set) var failures: [String] = []

    private var group = ""

    private init() {}

    func group(_ name: String, _ body: () -> Void) {
        self.group = name
        print("")
        print(name)
        body()
    }

    /// Records the outcome of one assertion.
    func expect(_ condition: Bool, _ label: String, line: UInt = #line) {
        if condition {
            passed += 1
            print("  ✓ \(label)")
        } else {
            failures.append("[\(group)] \(label) — line \(line)")
            print("  ✗ \(label)")
        }
    }

    func equal<T: Equatable>(_ actual: T, _ expected: T, _ label: String, line: UInt = #line) {
        expect(actual == expected, "\(label): expected \(expected), got \(actual)", line: line)
    }

    func isNil<T>(_ value: T?, _ label: String, line: UInt = #line) {
        expect(value == nil, "\(label): expected nil, got \(String(describing: value))", line: line)
    }

    func report() -> Int32 {
        print("")
        print(String(repeating: "─", count: 56))
        if failures.isEmpty {
            print("All \(passed) checks passed.")
            return 0
        }
        print("\(failures.count) of \(passed + failures.count) checks failed:")
        for failure in failures {
            print("  • \(failure)")
        }
        return 1
    }
}
