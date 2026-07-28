import Foundation

enum VDFValue: Equatable, Sendable {
    case string(String)
    case object([String: VDFValue])

    subscript(key: String) -> VDFValue? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var objectValue: [String: VDFValue]? {
        if case .object(let value) = self { return value }
        return nil
    }
}

enum VDFParserError: Error, Equatable {
    case unexpectedEnd
    case expectedString
    case expectedOpenBrace
    case expectedCloseBrace
}

struct VDFParser {
    private enum Token: Equatable {
        case string(String)
        case openBrace
        case closeBrace
    }

    func parse(_ text: String) throws -> [String: VDFValue] {
        var tokens = try tokenize(text)
        return try parseObject(tokens: &tokens, isRoot: true)
    }

    private func parseObject(tokens: inout [Token], isRoot: Bool = false) throws -> [String: VDFValue] {
        var object: [String: VDFValue] = [:]

        while !tokens.isEmpty {
            if tokens.first == .closeBrace {
                if isRoot { throw VDFParserError.expectedString }
                tokens.removeFirst()
                return object
            }

            guard case .string(let key)? = tokens.first else {
                throw VDFParserError.expectedString
            }
            tokens.removeFirst()

            guard let next = tokens.first else {
                throw VDFParserError.unexpectedEnd
            }

            switch next {
            case .string(let value):
                tokens.removeFirst()
                object[key] = .string(value)
            case .openBrace:
                tokens.removeFirst()
                object[key] = .object(try parseObject(tokens: &tokens))
            case .closeBrace:
                throw VDFParserError.expectedString
            }
        }

        if isRoot {
            return object
        }
        throw VDFParserError.expectedCloseBrace
    }

    private func tokenize(_ text: String) throws -> [Token] {
        var tokens: [Token] = []
        var index = text.startIndex

        func advance() {
            index = text.index(after: index)
        }

        while index < text.endIndex {
            let character = text[index]
            if character.isWhitespace {
                advance()
                continue
            }
            if character == "/" {
                let next = text.index(after: index)
                if next < text.endIndex, text[next] == "/" {
                    while index < text.endIndex, text[index] != "\n" {
                        advance()
                    }
                    continue
                }
            }
            if character == "{" {
                tokens.append(.openBrace)
                advance()
                continue
            }
            if character == "}" {
                tokens.append(.closeBrace)
                advance()
                continue
            }
            if character == "\"" {
                advance()
                var value = ""
                var didCloseString = false
                while index < text.endIndex {
                    let current = text[index]
                    if current == "\"" {
                        advance()
                        didCloseString = true
                        break
                    }
                    if current == "\\" {
                        guard text.index(after: index) < text.endIndex else {
                            throw VDFParserError.unexpectedEnd
                        }
                        advance()
                        switch text[index] {
                        case "n":
                            value.append("\n")
                        case "r":
                            value.append("\r")
                        case "t":
                            value.append("\t")
                        default:
                            value.append(text[index])
                        }
                        advance()
                    } else {
                        value.append(current)
                        advance()
                    }
                }
                guard didCloseString else {
                    throw VDFParserError.unexpectedEnd
                }
                tokens.append(.string(value))
                continue
            }

            var value = ""
            while index < text.endIndex,
                  !text[index].isWhitespace,
                  text[index] != "{",
                  text[index] != "}" {
                value.append(text[index])
                advance()
            }
            if !value.isEmpty {
                tokens.append(.string(value))
            }
        }
        return tokens
    }
}

struct VDFSerializer {
    func serialize(_ object: [String: VDFValue]) -> String {
        var lines: [String] = []
        append(object, indentationLevel: 0, to: &lines)
        return lines.joined(separator: "\n") + "\n"
    }

    private func append(
        _ object: [String: VDFValue],
        indentationLevel: Int,
        to lines: inout [String]
    ) {
        let indentation = String(repeating: "\t", count: indentationLevel)
        for key in object.keys.sorted(by: keyPrecedes) {
            guard let value = object[key] else { continue }
            switch value {
            case .string(let string):
                lines.append("\(indentation)\"\(escaped(key))\"\t\t\"\(escaped(string))\"")
            case .object(let child):
                lines.append("\(indentation)\"\(escaped(key))\"")
                lines.append("\(indentation){")
                append(child, indentationLevel: indentationLevel + 1, to: &lines)
                lines.append("\(indentation)}")
            }
        }
    }

    private func keyPrecedes(_ lhs: String, _ rhs: String) -> Bool {
        switch (Int(lhs), Int(rhs)) {
        case let (left?, right?):
            return left < right
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            return lhs < rhs
        }
    }

    private func escaped(_ value: String) -> String {
        var output = ""
        for character in value {
            switch character {
            case "\\":
                output.append("\\\\")
            case "\"":
                output.append("\\\"")
            case "\n":
                output.append("\\n")
            case "\r":
                output.append("\\r")
            case "\t":
                output.append("\\t")
            default:
                output.append(character)
            }
        }
        return output
    }
}
