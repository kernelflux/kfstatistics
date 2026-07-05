// ──────────────────────────────────────────────
//  TrackableMacro — Implementation
//
//  The @Trackable macro expands a user's struct
//  to add conformance to EventProtocol, including
//  eventName, schemaVersion, fields, and the
//  required var properties.
//
//  Input:
//    @Trackable
//    struct ButtonClick {
//        let buttonId: String
//        let durationMs: Int64
//    }
//
//  Output:
//    struct ButtonClick: EventProtocol, Codable, Sendable {
//        let buttonId: String
//        let durationMs: Int64
//
//        var eventName: String { "ButtonClick" }
//        static let schemaVersion: UInt32 = 1
//        var fields: [FieldDescriptor] { [
//            .init(name: "buttonId",   type: .string),
//            .init(name: "durationMs", type: .int64),
//        ] }
//
//        var eventID: UUID = .init()
//        var timestampMs: UInt64 = .now()
//        var sessionID: String = ""
//    }
// ──────────────────────────────────────────────

import SwiftSyntax
import SwiftSyntaxMacros
import SwiftDiagnostics

public enum TrackableMacro: MemberMacro, ExtensionMacro {

    // ════════════════════════════════════════════
    //  MemberMacro — add stored properties
    // ════════════════════════════════════════════

    public static func expansion(
        of attribute: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {

        guard let structDecl = declaration.as(StructDeclSyntax.self) else {
            throw MacroError.message("@Trackable can only be applied to structs")
        }

        let structName = structDecl.name.text

        // ── Extract field descriptors from stored properties ──
        let members = structDecl.memberBlock.members
        var fieldDeclarations: [String] = []
        var skippedFields: [String] = []

        for member in members {
            guard let varDecl = member.decl.as(VariableDeclSyntax.self),
                  let binding = varDecl.bindings.first,
                  let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                  let type = binding.typeAnnotation?.type
            else { continue }

            let typeName = type.description.trimmingCharacters(in: .whitespaces)

            // 检查可选类型
            if typeName.hasSuffix("?") {
                skippedFields.append("\(name): \(typeName) (Optional types are not supported; use a non-optional with a default value)")
                continue
            }

            let fieldType: String?
            switch typeName {
            case "String":           fieldType = ".string"
            case "Int64":            fieldType = ".int64"
            case "UInt64":           fieldType = ".uint64"
            case "Double":           fieldType = ".double"
            case "Float":            fieldType = ".double"  // Float → .double
            case "Bool":             fieldType = ".bool"
            case "Data":             fieldType = ".data"
            default:
                skippedFields.append("\(name): \(typeName) (unsupported type; supported types: String, Int64, UInt64, Double, Float, Bool, Data)")
                fieldType = nil
            }

            guard let ft = fieldType else { continue }
            fieldDeclarations.append(#"        .init(name: "\#(name)", type: \#(ft))"#)
        }

        let fieldsArray: String
        if fieldDeclarations.isEmpty {
            fieldsArray = "[FieldDescriptor]()"
        } else {
            fieldsArray = "[\n" + fieldDeclarations.joined(separator: ",\n") + "\n        ]"
        }

        // ── 如果有跳过的字段，发出诊断 ──
        if !skippedFields.isEmpty {
            let message = "@Trackable: \(skippedFields.joined(separator: "; "))"
            let diagnostic = Diagnostic(
                node: attribute,
                message: MacroWarningMessage(message: message)
            )
            context.diagnose(diagnostic)
        }

        return [
            DeclSyntax(stringLiteral: "var eventName: String { \"\(structName)\" }"),
            DeclSyntax(stringLiteral: "static let schemaVersion: UInt32 = 1"),
            DeclSyntax(stringLiteral: "var fields: [FieldDescriptor] { \(fieldsArray) }"),
            DeclSyntax(stringLiteral: "var eventID: UUID = .init()"),
            DeclSyntax(stringLiteral: "var timestampMs: UInt64 = .now()"),
            DeclSyntax(stringLiteral: "var sessionID: String = \"\""),
        ]
    }

    // ════════════════════════════════════════════
    //  ExtensionMacro — add protocol conformance
    // ════════════════════════════════════════════

    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        let ext: DeclSyntax = "extension \(type.trimmed): EventProtocol, Codable, Sendable {}"
        guard let extensionDecl = ext.as(ExtensionDeclSyntax.self) else {
            throw MacroError.message("Failed to create extension declaration")
        }
        return [extensionDecl]
    }
}

// ═══════════════════════════════════════════════
//  MARK: - #eventID macro
// ═══════════════════════════════════════════════

public enum EventIDMacro: ExpressionMacro {
    /// Generates a time-ordered UUID v7–compatible identifier.
    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> ExprSyntax {
        // 生成时间有序 UUID：前 48 位为时间戳
        // UUID v7 格式: tttttttt-tttt-Veee-xxxx-xxxxxxxxxxxx
        // V=7 表示版本 7, e=变体, x=随机
        ExprSyntax(stringLiteral: """
        { () -> UUID in
            let now = UInt64(Date().timeIntervalSince1970 * 1000)
            var bytes = (
                UInt8(now >> 40), UInt8(now >> 32),
                UInt8(now >> 24), UInt8(now >> 16),
                UInt8(now >> 8),  UInt8(now & 0xFF),
                UInt8(0x70 | (UInt8.random(in: 0...0x0F))),  // version 7
                UInt8(0x80 | (UInt8.random(in: 0...0x3F))),  // variant
                UInt8.random(in: 0...0xFF), UInt8.random(in: 0...0xFF),
                UInt8.random(in: 0...0xFF), UInt8.random(in: 0...0xFF),
                UInt8.random(in: 0...0xFF), UInt8.random(in: 0...0xFF),
                UInt8.random(in: 0...0xFF), UInt8.random(in: 0...0xFF)
            )
            return withUnsafePointer(to: &bytes) {
                NSUUID(uuidBytes: $0) as UUID
            }
        }()
        """)
    }
}

// ═══════════════════════════════════════════════
//  MARK: - Error type
// ═══════════════════════════════════════════════

enum MacroError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let msg): return msg
        }
    }
}

// ═══════════════════════════════════════════════
//  MARK: - MacroExpansionErrorMessage
// ═══════════════════════════════════════════════

/// Warning message for macro diagnostics.
struct MacroWarningMessage: DiagnosticMessage {
    let message: String
    let diagnosticID: MessageID
    let severity: DiagnosticSeverity = .warning

    init(message: String) {
        self.message = message
        self.diagnosticID = MessageID(domain: "KFStatisticsMacros", id: "TrackableMacro.skippedFields")
    }
}
