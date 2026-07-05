// ──────────────────────────────────────────────
//  KFStatisticsMacroTests — Macro unit tests
// ──────────────────────────────────────────────

import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import Testing

import KFStatisticsMacros

let trackableMacro: [String: Macro.Type] = [
    "Trackable": TrackableMacro.self,
]

@Suite("@Trackable macro")
struct TrackableMacroTests {

    @Test("expands stored properties and conformance for a simple struct")
    func expansion() {
        assertMacroExpansion(
            """
            @Trackable
            struct ButtonClick {
                let buttonId: String
                let durationMs: Int64
            }
            """,
            expandedSource: """
            struct ButtonClick: EventProtocol, Codable, Sendable {
                let buttonId: String
                let durationMs: Int64
                var eventName: String { "ButtonClick" }
                static let schemaVersion: UInt32 = 1
                var fields: [FieldDescriptor] { [
                    .init(name: "buttonId", type: .string),
                    .init(name: "durationMs", type: .int64),
                ] }
                var eventID: UUID = .init()
                var timestampMs: UInt64 = .now()
                var sessionID: String = ""
            }
            """,
            macros: trackableMacro
        )
    }

    @Test("handles struct with zero fields")
    func emptyStruct() {
        assertMacroExpansion(
            """
            @Trackable
            struct EmptyEvent {}
            """,
            expandedSource: """
            struct EmptyEvent: EventProtocol, Codable, Sendable {
                var eventName: String { "EmptyEvent" }
                static let schemaVersion: UInt32 = 1
                var fields: [FieldDescriptor] { [FieldDescriptor]() }
                var eventID: UUID = .init()
                var timestampMs: UInt64 = .now()
                var sessionID: String = ""
            }
            """,
            macros: trackableMacro
        )
    }

    @Test("handles all supported field types")
    func mixedFields() {
        assertMacroExpansion(
            """
            @Trackable
            struct Purchase {
                let itemID: String
                let price: Double
                let quantity: Int64
                let taxExempt: Bool
                let metadata: Data
            }
            """,
            expandedSource: """
            struct Purchase: EventProtocol, Codable, Sendable {
                let itemID: String
                let price: Double
                let quantity: Int64
                let taxExempt: Bool
                let metadata: Data
                var eventName: String { "Purchase" }
                static let schemaVersion: UInt32 = 1
                var fields: [FieldDescriptor] { [
                    .init(name: "itemID", type: .string),
                    .init(name: "price", type: .double),
                    .init(name: "quantity", type: .int64),
                    .init(name: "taxExempt", type: .bool),
                    .init(name: "metadata", type: .data),
                ] }
                var eventID: UUID = .init()
                var timestampMs: UInt64 = .now()
                var sessionID: String = ""
            }
            """,
            macros: trackableMacro
        )
    }
}
