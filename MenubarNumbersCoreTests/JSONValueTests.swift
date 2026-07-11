import XCTest
@testable import MenubarNumbersCore

final class JSONValueTests: XCTestCase {
    func testParsesAndSelectsRFC6901PointersIncludingEscapedObjectKeysAndArrays() throws {
        let json = try JSONValue.parse(Data(#"{"weather":{"current":[{"temp":21.5}]},"a/b":{"~key":"ok"}}"#.utf8))

        XCTAssertEqual(try json.value(at: "/weather/current/0/temp"), .number(21.5))
        XCTAssertEqual(try json.value(at: "/a~1b/~0key"), .string("ok"))
        XCTAssertEqual(try json.value(at: ""), json)
    }

    func testPointerRejectsMalformedEscapesAndDescribesMissingValues() throws {
        let json = try JSONValue.parse(Data(#"{"items":[1]}"#.utf8))

        XCTAssertThrowsError(try json.value(at: "items")) { error in
            XCTAssertEqual(error as? JSONPointerError, .invalidPointer("items"))
        }
        XCTAssertThrowsError(try json.value(at: "/items/01")) { error in
            XCTAssertEqual(error as? JSONPointerError, .invalidPointer("/items/01"))
        }
        XCTAssertThrowsError(try json.value(at: "/missing")) { error in
            XCTAssertEqual(error as? JSONPointerError, .missingValue("/missing"))
        }
    }

    func testPointerSlashSelectsAnEmptyStringObjectKey() throws {
        let json = try JSONValue.parse(Data(#"{"":"empty key"}"#.utf8))

        XCTAssertEqual(try json.value(at: "/"), .string("empty key"))
    }

    func testTreeRepresentationOrdersObjectChildrenByKey() throws {
        let json = try JSONValue.parse(Data(#"{"z":1,"a":true}"#.utf8))

        XCTAssertEqual(json.tree.children.map(\.label), ["a", "z"])
        XCTAssertEqual(json.tree.children.map(\.pointer), ["/a", "/z"])
    }
}
