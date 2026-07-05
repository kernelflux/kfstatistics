// ──────────────────────────────────────────────
//  EventMacros — public macro declarations
//  These are the user-facing macros.
//  Their implementation lives in the
//  KFStatisticsMacros target.
// ──────────────────────────────────────────────

import Foundation

// ═══════════════════════════════════════════════
//  @Trackable
//
//  Auto-conforms a struct to EventProtocol and
//  synthesises eventName, schemaVersion, fields,
//  Codable, and Sendable.
//
//  Usage:
//
//      @Trackable
//      struct ButtonClick: Sendable {
//          let buttonId: String
//          let pageName: String
//          let durationMs: Int64
//      }
//
//  Expands to:
//
//      struct ButtonClick: EventProtocol, Codable, Sendable {
//          let buttonId: String
//          let pageName: String
//          let durationMs: Int64
//
//          var eventName: String { "ButtonClick" }
//          static let schemaVersion: UInt32 = 1
//          var fields: [FieldDescriptor] { [...] }
//
//          var eventID: UUID = .init()
//          var timestampMs: UInt64 = .now()
//          var sessionID: String = ""
//      }
//
// ═══════════════════════════════════════════════

@attached(member, names: arbitrary)
@attached(extension, conformances: EventProtocol, Codable, Sendable)
public macro Trackable() =
    #externalMacro(module: "KFStatisticsMacros", type: "TrackableMacro")

// ═══════════════════════════════════════════════
//  #eventID
//
//  Generates a time-ordered UUID v7 for event
//  deduplication and efficient indexing.
//
//  Usage:
//      let id = #eventID
//
// ═══════════════════════════════════════════════

@freestanding(expression)
public macro eventID() -> UUID =
    #externalMacro(module: "KFStatisticsMacros", type: "EventIDMacro")
