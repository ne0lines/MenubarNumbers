import XCTest
@testable import MenubarNumbersCore

final class SecureValueStoreTests: XCTestCase {
    func testInMemoryStoreRoundTripsAndDeletesAValue() throws {
        let store = InMemorySecureValueStore()
        let reference = UUID()

        try store.set("private-token", for: reference)

        XCTAssertEqual(try store.value(for: reference), "private-token")
        try store.deleteValue(for: reference)
        XCTAssertThrowsError(try store.value(for: reference)) { error in
            XCTAssertEqual(error as? SecureValueStoreError, .notFound)
        }
    }

    func testInMemoryStoreDistinguishesMissingValues() {
        let store = InMemorySecureValueStore()

        XCTAssertThrowsError(try store.deleteValue(for: UUID())) { error in
            XCTAssertEqual(error as? SecureValueStoreError, .notFound)
        }
    }
}
