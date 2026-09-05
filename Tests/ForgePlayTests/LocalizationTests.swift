import Darwin
import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import ForgePlay

private enum PrintfFormatArgumentTokenizer {
    struct ParseResult: Equatable {
        let canonicalArgumentSignatures: [String]
        let validityIssues: [ValidityIssue]
    }

    struct ValidityIssue: Equatable {
        enum Kind: String {
            case danglingPercent
            case invalidPositionalArgument
            case incompletePositionalArgument
            case incompleteWidth
            case incompletePrecision
            case incompleteLength
            case malformedDirective
            case unknownConversion
            case illegalPositionalPercent
            case malformedPercentDirective
            case mixedArgumentAddressing
            case incompatibleDuplicatePosition
        }

        let kind: Kind
        let characterOffset: Int
        let detail: String
    }

    private enum ArgumentRole: Int {
        case width
        case precision
        case value

        var label: String {
            switch self {
            case .width: "width"
            case .precision: "precision"
            case .value: "value"
            }
        }
    }

    private struct ArgumentSignature {
        let position: Int
        let role: ArgumentRole
        let descriptor: String
        let abiRequirement: String
        let addressingMode: ArgumentAddressingMode

        var canonicalValue: String {
            "\(position):\(role.label):\(descriptor)"
        }
    }

    private enum ArgumentAddressingMode {
        case implicit
        case positional
    }

    private enum PositionalArgumentParse {
        case absent
        case position(Int)
        case invalid(String)
    }

    private static let flagOrder = Array("-+ #0'")
    private static let flags = Set(flagOrder)
    private static let conversions = Set("@diuoxXfFeEgGaAcCsSpnDUO%")
    private static let lengthModifiers = [
        Array("I32"),
        Array("I64"),
        Array("hh"),
        Array("ll"),
        Array("h"),
        Array("l"),
        Array("j"),
        Array("z"),
        Array("t"),
        Array("L"),
        Array("q")
    ]

    static func parse(_ format: String) -> ParseResult {
        let characters = Array(format)
        var index = 0
        var nextImplicitPosition = 1
        var signatures: [ArgumentSignature] = []
        var validityIssues: [ValidityIssue] = []
        var addressingMode: ArgumentAddressingMode?
        var didReportMixedAddressing = false
        var positionalABIRequirements: [Int: String] = [:]

        func recordIssue(
            _ kind: ValidityIssue.Kind,
            at characterOffset: Int,
            detail: String = ""
        ) {
            validityIssues.append(
                ValidityIssue(
                    kind: kind,
                    characterOffset: characterOffset,
                    detail: detail
                )
            )
        }

        formatScan: while index < characters.count {
            guard characters[index] == "%" else {
                index += 1
                continue
            }

            let percentIndex = index
            index += 1
            guard index < characters.count else {
                recordIssue(.danglingPercent, at: percentIndex)
                break
            }
            if characters[index] == "%" {
                index += 1
                continue
            }

            var explicitValuePosition: Int?
            switch positionalArgument(in: characters, index: &index) {
            case .absent:
                if index < characters.count, characters[index] == "$" {
                    recordIssue(
                        .invalidPositionalArgument,
                        at: percentIndex,
                        detail: "missing-position"
                    )
                    index = percentIndex + 1
                    continue formatScan
                }
            case let .position(position):
                explicitValuePosition = position
            case let .invalid(rawPosition):
                recordIssue(
                    .invalidPositionalArgument,
                    at: percentIndex,
                    detail: rawPosition
                )
                index = percentIndex + 1
                continue formatScan
            }

            var candidateNextImplicitPosition = nextImplicitPosition
            func consumeImplicitPosition() -> Int {
                defer { candidateNextImplicitPosition += 1 }
                return candidateNextImplicitPosition
            }

            var pendingArguments: [ArgumentSignature] = []

            var parsedFlags = Set<Character>()
            while index < characters.count, flags.contains(characters[index]) {
                parsedFlags.insert(characters[index])
                index += 1
            }
            let canonicalFlags = String(flagOrder.filter(parsedFlags.contains))

            var width = "none"
            if index < characters.count, characters[index] == "*" {
                index += 1
                let widthPosition: Int
                let widthAddressingMode: ArgumentAddressingMode
                switch positionalArgument(in: characters, index: &index) {
                case .absent:
                    widthPosition = consumeImplicitPosition()
                    widthAddressingMode = .implicit
                case let .position(position):
                    widthPosition = position
                    widthAddressingMode = .positional
                case let .invalid(rawPosition):
                    recordIssue(
                        .invalidPositionalArgument,
                        at: percentIndex,
                        detail: rawPosition
                    )
                    index = percentIndex + 1
                    continue formatScan
                }
                width = "argument:\(widthPosition)"
                pendingArguments.append(
                    ArgumentSignature(
                        position: widthPosition,
                        role: .width,
                        descriptor: "signed-int",
                        abiRequirement: "signed-int",
                        addressingMode: widthAddressingMode
                    )
                )
            } else if let digits = decimalDigits(in: characters, index: &index) {
                width = "fixed:\(canonicalDecimal(digits))"
            }

            var precision = "none"
            if index < characters.count, characters[index] == "." {
                index += 1
                if index < characters.count, characters[index] == "*" {
                    index += 1
                    let precisionPosition: Int
                    let precisionAddressingMode: ArgumentAddressingMode
                    switch positionalArgument(in: characters, index: &index) {
                    case .absent:
                        precisionPosition = consumeImplicitPosition()
                        precisionAddressingMode = .implicit
                    case let .position(position):
                        precisionPosition = position
                        precisionAddressingMode = .positional
                    case let .invalid(rawPosition):
                        recordIssue(
                            .invalidPositionalArgument,
                            at: percentIndex,
                            detail: rawPosition
                        )
                        index = percentIndex + 1
                        continue formatScan
                    }
                    precision = "argument:\(precisionPosition)"
                    pendingArguments.append(
                        ArgumentSignature(
                            position: precisionPosition,
                            role: .precision,
                            descriptor: "signed-int",
                            abiRequirement: "signed-int",
                            addressingMode: precisionAddressingMode
                        )
                    )
                } else if let digits = decimalDigits(in: characters, index: &index) {
                    precision = "fixed:\(canonicalDecimal(digits))"
                } else {
                    precision = "fixed:0"
                }
            }

            let length = lengthModifier(in: characters, index: &index)
            guard index < characters.count else {
                let issueKind: ValidityIssue.Kind
                if !length.isEmpty {
                    issueKind = .incompleteLength
                } else if precision != "none" {
                    issueKind = .incompletePrecision
                } else if width != "none" {
                    issueKind = .incompleteWidth
                } else if explicitValuePosition != nil {
                    issueKind = .incompletePositionalArgument
                } else {
                    issueKind = .malformedDirective
                }
                recordIssue(issueKind, at: percentIndex)
                index = percentIndex + 1
                continue
            }
            guard conversions.contains(characters[index]) else {
                recordIssue(
                    .unknownConversion,
                    at: percentIndex,
                    detail: String(characters[index])
                )
                index = percentIndex + 1
                continue
            }

            let conversion = characters[index]
            index += 1
            if conversion == "%" {
                let hasPositionalReference = explicitValuePosition != nil
                    || pendingArguments.contains { $0.addressingMode == .positional }
                if hasPositionalReference {
                    recordIssue(.illegalPositionalPercent, at: percentIndex)
                } else if !parsedFlags.isEmpty
                            || width != "none"
                            || precision != "none"
                            || !length.isEmpty {
                    recordIssue(.malformedPercentDirective, at: percentIndex)
                }
                continue
            }
            guard isLengthModifier(length, validFor: conversion) else {
                recordIssue(
                    .malformedDirective,
                    at: percentIndex,
                    detail: "invalid-length:\(length):\(conversion)"
                )
                continue
            }
            if conversion == "n",
               !parsedFlags.isEmpty || width != "none" || precision != "none" {
                recordIssue(
                    .malformedDirective,
                    at: percentIndex,
                    detail: "decorated-count-conversion"
                )
                continue
            }

            let valuePosition: Int
            let valueAddressingMode: ArgumentAddressingMode
            if let explicitValuePosition {
                valuePosition = explicitValuePosition
                valueAddressingMode = .positional
            } else {
                valuePosition = consumeImplicitPosition()
                valueAddressingMode = .implicit
            }
            pendingArguments.append(
                ArgumentSignature(
                    position: valuePosition,
                    role: .value,
                    descriptor: [
                        "flags=\(canonicalFlags)",
                        "width=\(width)",
                        "precision=\(precision)",
                        "length=\(length)",
                        "conversion=\(conversion)"
                    ].joined(separator: ";"),
                    abiRequirement: valueABIRequirement(
                        length: length,
                        conversion: conversion
                    ),
                    addressingMode: valueAddressingMode
                )
            )

            for argument in pendingArguments {
                if let establishedAddressingMode = addressingMode {
                    if establishedAddressingMode != argument.addressingMode,
                       !didReportMixedAddressing {
                        recordIssue(.mixedArgumentAddressing, at: percentIndex)
                        didReportMixedAddressing = true
                    }
                } else {
                    addressingMode = argument.addressingMode
                }

                if argument.addressingMode == .positional {
                    if let existingRequirement = positionalABIRequirements[argument.position] {
                        if existingRequirement != argument.abiRequirement {
                            recordIssue(
                                .incompatibleDuplicatePosition,
                                at: percentIndex,
                                detail: "\(argument.position):\(existingRequirement)->\(argument.abiRequirement)"
                            )
                        }
                    } else {
                        positionalABIRequirements[argument.position] = argument.abiRequirement
                    }
                }
                signatures.append(argument)
            }
            nextImplicitPosition = candidateNextImplicitPosition
        }

        return ParseResult(
            canonicalArgumentSignatures: signatures.sorted { lhs, rhs in
                if lhs.position != rhs.position { return lhs.position < rhs.position }
                if lhs.role.rawValue != rhs.role.rawValue { return lhs.role.rawValue < rhs.role.rawValue }
                return lhs.descriptor < rhs.descriptor
            }.map(\.canonicalValue),
            validityIssues: validityIssues
        )
    }

    private static func positionalArgument(
        in characters: [Character],
        index: inout Int
    ) -> PositionalArgumentParse {
        let start = index
        guard let digits = decimalDigits(in: characters, index: &index),
              index < characters.count,
              characters[index] == "$" else {
            index = start
            return .absent
        }
        index += 1
        guard let position = Int(digits), position > 0 else {
            return .invalid(digits)
        }
        return .position(position)
    }

    private static func decimalDigits(
        in characters: [Character],
        index: inout Int
    ) -> String? {
        let start = index
        while index < characters.count, isASCIIDigit(characters[index]) {
            index += 1
        }
        guard index > start else { return nil }
        return String(characters[start..<index])
    }

    private static func canonicalDecimal(_ digits: String) -> String {
        let withoutLeadingZeroes = digits.drop { $0 == "0" }
        return withoutLeadingZeroes.isEmpty ? "0" : String(withoutLeadingZeroes)
    }

    private static func isASCIIDigit(_ character: Character) -> Bool {
        character >= "0" && character <= "9"
    }

    private static func lengthModifier(
        in characters: [Character],
        index: inout Int
    ) -> String {
        guard index < characters.count else { return "" }
        for modifier in lengthModifiers where characters[index...].starts(with: modifier) {
            index += modifier.count
            return String(modifier)
        }
        return ""
    }

    private static func valueABIRequirement(
        length: String,
        conversion: Character
    ) -> String {
        switch conversion {
        case "@":
            return "object"
        case "d", "i":
            let canonicalLength = canonicalIntegerLength(length)
            return canonicalLength == "default"
                ? "signed-int"
                : "signed-integer:\(canonicalLength)"
        case "D":
            return "signed-integer:l"
        case "u", "o", "x", "X":
            let canonicalLength = canonicalIntegerLength(length)
            return canonicalLength == "default"
                ? "unsigned-int"
                : "unsigned-integer:\(canonicalLength)"
        case "U", "O":
            return "unsigned-integer:l"
        case "f", "F", "e", "E", "g", "G", "a", "A":
            return length == "L" ? "long-double" : "double"
        case "c", "C":
            return length == "l" || conversion == "C" ? "wide-character" : "signed-int"
        case "s":
            return length == "l" ? "wide-character-pointer" : "character-pointer"
        case "S":
            return "wide-character-pointer"
        case "p":
            return "raw-pointer"
        case "n":
            return "count-pointer:\(canonicalCountPointerLength(length))"
        default:
            return "value:\(length):\(conversion)"
        }
    }

    private static func canonicalIntegerLength(_ length: String) -> String {
        switch length {
        case "hh", "h", "":
            return "default"
        case "q":
            return "ll"
        default:
            return length
        }
    }

    private static func canonicalCountPointerLength(_ length: String) -> String {
        length == "q" ? "ll" : (length.isEmpty ? "default" : length)
    }

    private static func isLengthModifier(
        _ length: String,
        validFor conversion: Character
    ) -> Bool {
        guard !length.isEmpty else { return true }
        switch conversion {
        case "d", "i", "u", "o", "x", "X", "n":
            return ["I32", "I64", "hh", "ll", "h", "l", "j", "z", "t", "q"]
                .contains(length)
        case "f", "F", "e", "E", "g", "G", "a", "A":
            return length == "l" || length == "L"
        case "c", "s":
            return length == "l"
        default:
            return false
        }
    }
}

final class LocalizationTests: XCTestCase {
    func testForgePlayLanguagesMapToOfficialSteamClientTokensAndWebHelperLocales() {
        let expected: [(
            forgePlayLanguage: ForgePlayLanguageMode,
            steamLanguage: SteamClientLanguage,
            webHelperLocale: String
        )] = [
            (.english, .english, "en_US"),
            (.korean, .koreana, "ko_KR"),
            (.spanish, .spanish, "es_ES"),
            (.german, .german, "de_DE"),
            (.japanese, .japanese, "ja_JP"),
            (.simplifiedChinese, .schinese, "zh_CN"),
            (.traditionalChinese, .tchinese, "zh_TW"),
            (.french, .french, "fr_FR")
        ]

        XCTAssertEqual(expected.count, SteamClientLanguage.allCases.count)
        for projection in expected {
            let steamLanguage = projection.forgePlayLanguage
                .resolvedSteamClientLanguage()
            XCTAssertEqual(steamLanguage, projection.steamLanguage)
            XCTAssertEqual(
                steamLanguage.webHelperLocaleIdentifier,
                projection.webHelperLocale
            )
        }
    }

    func testSystemLanguageResolvesBeforeSteamClientMapping() {
        XCTAssertEqual(
            ForgePlayLanguageMode.system.resolvedSteamClientLanguage(
                preferredLanguageIdentifiers: ["ko-KR"]
            ),
            .koreana
        )
        XCTAssertEqual(
            ForgePlayLanguageMode.system.resolvedSteamClientLanguage(
                preferredLanguageIdentifiers: ["zh-Hant-HK"]
            ),
            .tchinese
        )
        XCTAssertEqual(
            ForgePlayLanguageMode.system.resolvedSteamClientLanguage(
                preferredLanguageIdentifiers: ["pt-BR"]
            ),
            .english
        )
    }

    func testSupportedLanguageResourcesExist() throws {
        for language in ForgePlayLanguageMode.allCases where language != .system {
            let directory = try XCTUnwrap(language.localizationDirectory)

            XCTAssertTrue(
                Bundle.main.path(forResource: directory, ofType: "lproj") != nil,
                "Missing localization resource for \(directory)"
            )
        }
    }

    func testSystemLanguageResolvesFromMacOSGlobalLanguageOrder() {
        XCTAssertEqual(
            ForgePlaySystemLanguageResolver.resolvedLanguageMode(
                preferredLanguageIdentifiers: ["ko-KR", "de-DE", "en"]
            ),
            .korean
        )
        XCTAssertEqual(
            ForgePlaySystemLanguageResolver.resolvedLocaleIdentifier(
                preferredLanguageIdentifiers: ["ko-KR", "de-DE", "en"]
            ),
            "ko-kr"
        )
    }

    func testSystemPreferredLanguageOrderUsesMacOSDisplayLanguageBeforeLocaleFormat() {
        let identifiers = ForgePlaySystemLanguageResolver.systemPreferredLanguageIdentifiers(
            currentLocaleIdentifier: "de_DE",
            localePreferredLanguages: ["ko-KR", "en"],
            globalLanguageIdentifiers: ["fr-FR", "en"]
        )

        XCTAssertEqual(identifiers, ["ko-KR", "en", "fr-FR", "de_DE"])
        XCTAssertEqual(
            ForgePlaySystemLanguageResolver.resolvedLanguageMode(
                preferredLanguageIdentifiers: identifiers
            ),
            .korean
        )
    }

    func testSystemPreferredLanguageOrderFallsBackToGlobalDomainWhenLocaleOrderIsEmpty() {
        let identifiers = ForgePlaySystemLanguageResolver.systemPreferredLanguageIdentifiers(
            currentLocaleIdentifier: nil,
            localePreferredLanguages: [],
            globalLanguageIdentifiers: ["de-DE", "en"]
        )

        XCTAssertEqual(identifiers, ["de-DE", "en"])
    }

    func testSystemLanguageDoesNotFallThroughToGermanWhenKoreanIsPreferred() {
        let identifiers = ForgePlaySystemLanguageResolver.systemPreferredLanguageIdentifiers(
            currentLocaleIdentifier: "de_DE",
            localePreferredLanguages: ["ko-KR", "de-DE", "en"],
            globalLanguageIdentifiers: nil
        )
        let localized = ForgePlayLocalization.localized(
            "앱 언어",
            language: .system,
            systemLanguageIdentifiers: identifiers
        )

        XCTAssertEqual(
            ForgePlaySystemLanguageResolver.resolvedLanguageMode(
                preferredLanguageIdentifiers: identifiers
            ),
            .korean
        )
        XCTAssertEqual(localized, "앱 언어")
    }

    func testCurrentAppliedLanguageSummaryUsesResolvedSystemLanguage() {
        let koreanSystemLanguageName = ForgePlayLocalization.localized(
            ForgePlayLanguageMode.korean.labelKey,
            language: .system,
            systemLanguageIdentifiers: ["ko-KR", "de-DE", "en"]
        )
        let koreanSummary = ForgePlayLocalization.localizedFormat(
            "현재 적용 언어: %@",
            language: .system,
            arguments: [koreanSystemLanguageName],
            systemLanguageIdentifiers: ["ko-KR", "de-DE", "en"]
        )
        let germanSystemLanguageName = ForgePlayLocalization.localized(
            ForgePlayLanguageMode.german.labelKey,
            language: .system,
            systemLanguageIdentifiers: ["de-DE", "ko-KR", "en"]
        )
        let germanSummary = ForgePlayLocalization.localizedFormat(
            "현재 적용 언어: %@",
            language: .system,
            arguments: [germanSystemLanguageName],
            systemLanguageIdentifiers: ["de-DE", "ko-KR", "en"]
        )

        XCTAssertEqual(koreanSummary, "현재 적용 언어: 한국어")
        XCTAssertEqual(germanSummary, "Aktuell verwendete Sprache: Deutsch")
    }

    func testSystemLanguageMatchesRegionAndScriptIdentifiers() {
        XCTAssertEqual(
            ForgePlaySystemLanguageResolver.resolvedLanguageMode(
                preferredLanguageIdentifiers: ["de-DE", "ko-KR"]
            ),
            .german
        )
        XCTAssertEqual(
            ForgePlaySystemLanguageResolver.resolvedLanguageMode(
                preferredLanguageIdentifiers: ["zh-Hant-TW", "en-US"]
            ),
            .traditionalChinese
        )
        XCTAssertEqual(
            ForgePlaySystemLanguageResolver.resolvedLanguageMode(
                preferredLanguageIdentifiers: ["zh_Hans_CN", "en-US"]
            ),
            .simplifiedChinese
        )
    }

    func testUnsupportedSystemLanguageFallsBackToEnglish() {
        XCTAssertEqual(
            ForgePlaySystemLanguageResolver.resolvedLanguageMode(
                preferredLanguageIdentifiers: ["pt-BR", "it-IT"]
            ),
            .english
        )
    }

    func testSynchronizationSelectionExposesOnlyAutomaticMode() {
        XCTAssertEqual(WineSynchronizationSelection.allCases, [.automatic])
        XCTAssertEqual(WineSynchronizationSelection.automatic.labelKey, "자동")
    }

    func testSteamPrelaunchCompatibilityOptionsAreManualAndLocalized() throws {
        XCTAssertEqual(
            SteamRendererPolicySelection.allCases,
            [.d3dMetal, .d3dMetalNVIDIA, .dxmt, .d9vk, .vulkan]
        )
        XCTAssertEqual(
            SteamRendererPolicySelection.d3dMetalNVIDIA.labelKey,
            "D3DMetal - NVIDIA"
        )
        XCTAssertEqual(
            SteamNetworkCompatibilitySelection.allCases,
            [.standard, .wifiIdentity, .ethernetIdentity]
        )
        XCTAssertEqual(
            SteamAudioInputSelection.allCases,
            [.disabled, .enabled]
        )

        let keys =
            SteamRendererPolicySelection.allCases.flatMap {
                [$0.labelKey, $0.detailKey]
            } +
            SteamNetworkCompatibilitySelection.allCases.flatMap {
                [$0.labelKey, $0.detailKey]
            } +
            SteamAudioInputSelection.allCases.flatMap {
                [$0.labelKey, $0.detailKey]
            } + [
                "선택한 D3DMetal 공급자 경로에 실제로 적용된 레지스트리 또는 모듈 상태가 요청과 일치하지 않습니다.",
                "MetalFX 모듈 복원 정보 파일을 저장한 뒤 내용이 일치하는지 확인하지 못했습니다."
            ]
        for language in ForgePlayLanguageMode.allCases where language != .system {
            let directory = try XCTUnwrap(language.localizationDirectory)
            let table = try strings(for: directory)
            for key in keys {
                let localized = try XCTUnwrap(
                    table[key],
                    "Missing compatibility localization for \(key) in \(language.rawValue)"
                )
                XCTAssertFalse(
                    localized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "Empty compatibility localization for \(key) in \(language.rawValue)"
                )
            }

            XCTAssertEqual(
                table[SteamRendererPolicySelection.d3dMetalNVIDIA.labelKey],
                "D3DMetal - NVIDIA",
                "Incorrect D3DMetal NVIDIA label in \(language.rawValue)"
            )
        }
    }

    func testCoreBeginnerFlowKeysResolveInEverySupportedLanguage() {
        let keys = [
            "사용법",
            "전체 사용법 보기",
            "앱 언어",
            "시스템 언어 따르기",
            "현재 적용 언어: %@",
            "언어 미리보기 적용 중: %@",
            "설정",
            "문제 진단 (베타)",
            "Windows용 Steam",
            "1. 앱 데이터 준비",
            "ForgePlay 앱 데이터",
            "첫 실행에서는 Steam 프리픽스, 캐시, 로그를 Mac 내부 Application Support에 자동으로 준비합니다. 이후 설정에서 앱 데이터 위치를 변경할 수 있습니다.",
            "ForgePlay 앱 데이터 위치",
            "Steam launch path: not inspected",
            "2. ForgePlay Runtime 확인",
            "앱에 포함된 ForgePlay Runtime만 실행 엔진으로 사용",
            "Apple D3DMetal 보조 렌더러",
            "Steam UI와 게임 렌더러 분리",
            "Steam 실행 로그 세트 최대 %d개 보존",
            "Steam App ID: %@",
            "Steam App ID: %@ · %@",
            "%d개 Steam 참고 기록을 찾았습니다.",
            "Steam 참고 기록이 아직 없습니다.",
            "Steam 참고 기록이 비어 있습니다",
            "게임별 호환성 안내를 사용하려면 진단 대상을 선택하세요. 선택은 게임을 직접 실행하거나 Steam 실행 설정을 자동으로 바꾸지 않습니다.",
            "진단 대상으로 선택됨",
            "진단 대상 해제",
            "진단 대상으로 선택",
            "게임별 진단 대상 선택을 해제했습니다.",
            "%@을 게임별 진단 대상으로 선택했습니다. Steam은 기존처럼 별도로 실행됩니다.",
            "같은 Steam App ID에 여러 실행 규칙이 있어 임의로 선택하지 않았습니다: %@",
            "한 Steam App ID에 여러 실행 규칙을 적용할 수 없습니다: %@"
        ]

        for language in ForgePlayLanguageMode.allCases where language != .system {
            for key in keys {
                let localized = ForgePlayLocalization.localized(key, language: language)
                XCTAssertFalse(localized.isEmpty, "Empty localization for \(key) in \(language.rawValue)")
            }
        }
    }

    func testBetaFeatureNamesAreConsistentInEverySupportedLanguage() throws {
        let keys = [
            "Steam 호환성 실행 (베타)",
            "문제 진단 (베타)",
            "업데이트 확인 (베타)",
            "EXE 실행 (베타)",
            "문제 진단 (베타) 보기",
            "문제 진단 (베타) 열기",
            "문제 진단 (베타)으로 이동",
            "Steam 호환성 실행 (베타)으로 이동",
            "EXE 실행 (베타)으로 돌아가기"
        ]
        let retiredKeys = [
            "Steam 호환성 실행",
            "문제 진단",
            "업데이트 확인",
            "EXE 실행",
            "문제 진단 보기",
            "문제 진단 열기",
            "문제 진단으로 이동",
            "Steam 호환성 실행으로 이동",
            "EXE 실행으로 돌아가기"
        ]
        let english = try strings(for: "en")

        for language in ForgePlayLanguageMode.allCases where language != .system {
            let directory = try XCTUnwrap(language.localizationDirectory)
            let localized = try strings(for: directory)
            for key in keys {
                let value = try XCTUnwrap(
                    localized[key],
                    "Missing beta feature name for \(key) in \(directory)"
                )
                XCTAssertFalse(
                    value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "Empty beta feature name for \(key) in \(directory)"
                )
                if language == .korean {
                    XCTAssertEqual(value, key)
                } else if language != .english {
                    XCTAssertNotEqual(
                        value,
                        english[key],
                        "Beta feature name falls back to English for \(key) in \(directory)"
                    )
                }
            }
            for key in retiredKeys {
                XCTAssertNil(
                    localized[key],
                    "Retired non-beta feature name remains in \(directory): \(key)"
                )
            }
        }
    }

    func testContextualHelpIsWiredForEveryMainSection() throws {
        let root = try projectRoot()
        let appNavigation = try String(
            contentsOf: root.appending(path: "Sources/ForgePlay/App/AppNavigation.swift"),
            encoding: .utf8
        )
        let sheetHost = try String(
            contentsOf: root.appending(path: "Sources/ForgePlay/UI/SheetHostView.swift"),
            encoding: .utf8
        )
        let usageGuide = try String(
            contentsOf: root.appending(path: "Sources/ForgePlay/UI/UsageGuideView.swift"),
            encoding: .utf8
        )
        let dashboard = try String(
            contentsOf: root.appending(path: "Sources/ForgePlay/UI/DashboardView.swift"),
            encoding: .utf8
        )
        let setup = try String(
            contentsOf: root.appending(path: "Sources/ForgePlay/UI/SetupView.swift"),
            encoding: .utf8
        )
        let steamLaunch = try String(
            contentsOf: root.appending(path: "Sources/ForgePlay/UI/SteamLaunchView.swift"),
            encoding: .utf8
        )
        let diagnostics = try String(
            contentsOf: root.appending(path: "Sources/ForgePlay/UI/DiagnosticsView.swift"),
            encoding: .utf8
        )
        let developerApps = try String(
            contentsOf: root.appending(path: "Sources/ForgePlay/UI/DeveloperAppsView.swift"),
            encoding: .utf8
        )
        let hallOfSupporters = try String(
            contentsOf: root.appending(path: "Sources/ForgePlay/UI/HallOfSupportersView.swift"),
            encoding: .utf8
        )
        let settings = try String(
            contentsOf: root.appending(path: "Sources/ForgePlay/UI/SettingsView.swift"),
            encoding: .utf8
        )
        let advanced = try String(
            contentsOf: root.appending(path: "Sources/ForgePlay/UI/AdvancedView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(appNavigation.contains("case sectionHelp(AppSection)"))
        XCTAssertTrue(sheetHost.contains("ForgeSheetChrome(onClose: { dismiss() })"))
        XCTAssertNotNil(sheetHost.range(
            of: #"ContextualHelpView\(\s*section: section,\s*sheetPresenter: presentSheet\s*\)"#,
            options: .regularExpression
        ))
        XCTAssertTrue(sheetHost.contains("RuntimeInstallerCatalogSheet(sheetPresenter: presentSheet)"))
        XCTAssertNotNil(sheetHost.range(
            of: #"DiagnosticGuidanceSheet\(\s*payload: payload,\s*sheetPresenter: presentSheet,"#,
            options: .regularExpression
        ))
        XCTAssertTrue(usageGuide.contains("struct SectionHelpButton: View"))
        XCTAssertTrue(usageGuide.contains(
            "https://developer.apple.com/videos/play/wwdc2025/211/?time=133"
        ))
        XCTAssertFalse(usageGuide.contains("프레임 수준"))
        XCTAssertFalse(usageGuide.contains("실기기"))
        XCTAssertTrue(appNavigation.contains("case steamLaunch"))
        XCTAssertFalse(appNavigation.contains("case steamLaunch = \"games\""))
        XCTAssertFalse(appNavigation.contains("case games"))

        for section in AppSection.allCases {
            XCTAssertTrue(
                usageGuide.contains("case .\(section.rawValue):"),
                "Missing contextual help guide for \(section.rawValue)"
            )
        }

        XCTAssertTrue(dashboard.contains("SectionHelpButton(section: .dashboard)"))
        XCTAssertTrue(setup.contains("SectionHelpButton(section: .setup)"))
        XCTAssertTrue(steamLaunch.contains("SectionHelpButton(section: helpSection)"))
        XCTAssertTrue(diagnostics.contains("SectionHelpButton(section: .diagnostics)"))
        XCTAssertTrue(developerApps.contains("SectionHelpButton(section: .developerApps)"))
        XCTAssertFalse(hallOfSupporters.contains("SectionHelpButton"))
        XCTAssertTrue(settings.contains("SectionHelpButton(section: .settings)"))
        XCTAssertTrue(advanced.contains("SectionHelpButton(section: .advanced)"))
    }

    func testFormattedLocalizedStringUsesSelectedLanguage() {
        let output = ForgePlayLocalization.localizedFormat(
            "%d개 Steam 참고 기록을 찾았습니다.",
            language: .english,
            arguments: [3]
        )

        XCTAssertEqual(output, "Found 3 Steam reference records.")
    }

    func testLocalizedByteCountUsesSelectedLanguage() {
        let english = ForgePlayLocalization.localizedByteCount(1_234_567, language: .english)
        let french = ForgePlayLocalization.localizedByteCount(1_234_567, language: .french)
        let systemFrench = ForgePlayLocalization.localizedByteCount(
            1_234_567,
            language: .system,
            systemLanguageIdentifiers: ["fr-FR", "en-US"]
        )

        XCTAssertNotEqual(english, french)
        XCTAssertTrue(english.contains("MB"), english)
        XCTAssertTrue(french.contains("Mo"), french)
        XCTAssertTrue(french.contains(","), french)
        XCTAssertEqual(systemFrench, french)
    }

    @MainActor
    func testStorageMigrationInsufficientSpaceErrorUsesSelectedLanguageByteCounts() {
        let appState = AppState()
        appState.languageMode = .french

        let message = appState.localizedError(
            StorageMigrationError.insufficientSpace(required: 1_234_567, available: 12_345)
        )

        XCTAssertTrue(message.contains("Mo"), message)
        XCTAssertTrue(message.contains("ko"), message)
        XCTAssertFalse(message.contains("MB"), message)
        XCTAssertFalse(message.contains("KB"), message)
    }

    func testRuntimeInstallationStatusLabelsResolveInEverySupportedLanguage() {
        let keys = RuntimeInstallationStatus.allCases.map(\.label)
            + RuntimeId.allCases.map(\.beginnerName)
            + [
            "%@(%@)",
            "%@ 설치 파일 선택",
            "공식 출처에서 받은 파일만 사용하세요. ForgePlay에서 선택할 수 있는 최종 설치 파일: %@. 다운로드한 파일이 zip 또는 압축 해제용 exe라면 먼저 압축을 풀고 실제 설치 파일을 선택하세요.",
            "공식 출처에서 받은 파일만 사용하세요. 최종 설치 파일: %@. 압축 해제용 파일도 지원합니다: %@.",
            "알 수 없는 Runtime 상태: %@",
            "알 수 없는 Runtime: %@"
        ]

        for language in ForgePlayLanguageMode.allCases where language != .system {
            for key in keys {
                let localized = ForgePlayLocalization.localized(key, language: language)
                XCTAssertFalse(localized.isEmpty, "Empty runtime status localization for \(key) in \(language.rawValue)")
            }
        }

        XCTAssertEqual(
            ForgePlayLocalization.localized(RuntimeInstallationStatus.installed.label, language: .english),
            "Installed"
        )
        XCTAssertEqual(
            ForgePlayLocalization.localizedFormat(
                "%@(%@)",
                language: .english,
                arguments: [
                    ForgePlayLocalization.localized(RuntimeId.vcrun2022.beginnerName, language: .english),
                    RuntimeId.vcrun2022.technicalName
                ]
            ),
            "Microsoft Visual C++ Components(vcrun2022)"
        )
        XCTAssertEqual(
            ForgePlayLocalization.localizedFormat(
                "알 수 없는 Runtime 상태: %@",
                language: .english,
                arguments: ["queued"]
            ),
            "Unknown Runtime status: queued"
        )
    }

    func testRuntimeInstallerPanelUsesLocalizedRuntimeTitle() throws {
        let source = try String(
            contentsOf: projectRoot().appending(path: "Sources/ForgePlay/UI/SheetHostView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(
            source.contains(#"title: appState.localizedFormat("%@ 설치 파일 선택", runtime.localizedTitle(appState: appState))"#)
        )
        XCTAssertTrue(
            source.contains("message: definition.localizedSelectionPanelMessage(appState: appState)")
        )
        XCTAssertFalse(
            source.contains(#"title: appState.localizedFormat("%@ 설치 파일 선택", runtime.rawValue)"#)
        )
        XCTAssertFalse(
            source.contains("message: appState.localized(definition.selectionPanelMessage)")
        )
    }

    @MainActor
    func testRuntimeInstallerSelectionPanelMessageUsesLocalizedFormatKeys() {
        let appState = AppState()
        appState.languageMode = .german
        let plainDefinition = RuntimeDefinition(
            id: .openal,
            officialURL: URL(string: "https://example.com/openal"),
            officialSourceName: "OpenAL",
            beginnerDescription: "OpenAL 오디오 구성요소",
            downloadFileHints: ["oalinst.zip"],
            installerHints: ["oalinst.exe"]
        )
        let extractableDefinition = RuntimeDefinition(
            id: .d3dx9,
            officialURL: URL(string: "https://example.com/directx"),
            officialSourceName: "Microsoft",
            beginnerDescription: "DirectX 게임 구성요소",
            downloadFileHints: ["directx_Jun2010_redist.exe"],
            installerHints: ["DXSETUP.exe"],
            extractableArchiveHints: ["directx_Jun2010_redist.exe"]
        )

        let plainMessage = plainDefinition.localizedSelectionPanelMessage(appState: appState)
        let extractableMessage = extractableDefinition.localizedSelectionPanelMessage(appState: appState)

        XCTAssertTrue(plainMessage.contains("oalinst.exe"), plainMessage)
        XCTAssertTrue(extractableMessage.contains("DXSETUP.exe"), extractableMessage)
        XCTAssertTrue(extractableMessage.contains("directx_Jun2010_redist.exe"), extractableMessage)
        XCTAssertNil(plainMessage.range(of: "[가-힣]", options: .regularExpression), plainMessage)
        XCTAssertNil(extractableMessage.range(of: "[가-힣]", options: .regularExpression), extractableMessage)
        XCTAssertNotEqual(
            plainMessage,
            "공식 출처에서 받은 파일만 사용하세요. ForgePlay에서 선택할 수 있는 최종 설치 파일: oalinst.exe. 다운로드한 파일이 zip 또는 압축 해제용 exe라면 먼저 압축을 풀고 실제 설치 파일을 선택하세요."
        )
    }

    @MainActor
    func testDiagnosticRemediationStepsUseLocalizedPresentationLayer() throws {
        let domainSource = try String(
            contentsOf: projectRoot().appending(path: "Sources/ForgePlay/Models/DomainModels.swift"),
            encoding: .utf8
        )
        let presentationSource = try String(
            contentsOf: projectRoot().appending(path: "Sources/ForgePlay/UI/LocalizedActionPresentation.swift"),
            encoding: .utf8
        )
        let diagnosticsSource = try String(
            contentsOf: projectRoot().appending(path: "Sources/ForgePlay/UI/DiagnosticsView.swift"),
            encoding: .utf8
        )
        let sheetHostSource = try String(
            contentsOf: projectRoot().appending(path: "Sources/ForgePlay/UI/SheetHostView.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(domainSource.contains("var remediationSteps"))
        XCTAssertFalse(domainSource.contains("DiagnosticRemediationGuide"))
        XCTAssertFalse(domainSource.contains("remediationGuide("))
        XCTAssertTrue(presentationSource.contains("func localizedRemediationSteps("))
        XCTAssertTrue(diagnosticsSource.contains("action.localizedRemediationSteps("))
        XCTAssertTrue(sheetHostSource.contains("action.localizedRemediationSteps("))
        XCTAssertFalse(diagnosticsSource.contains("guide.steps"))
        XCTAssertFalse(sheetHostSource.contains("guide.steps"))

        let appState = AppState()
        appState.languageMode = .german
        let runtimeDefinition = RuntimeDefinition(
            id: .openal,
            officialURL: URL(string: "https://example.com/openal"),
            officialSourceName: "OpenAL",
            beginnerDescription: "OpenAL 오디오 구성요소",
            downloadFileHints: ["oalinst.zip"],
            installerHints: ["oalinst.exe"]
        )
        let actions: [(RecommendedAction, RuntimeDefinition?)] = [
            (
                RecommendedAction(
                    type: .installRuntime,
                    runtime: .openal,
                    windowsVersion: nil,
                    dll: nil,
                    override: nil,
                    launchOption: nil,
                    requiresUserConfirmation: true,
                    riskLevel: .low,
                    reason: "OpenAL"
                ),
                runtimeDefinition
            ),
            (
                RecommendedAction(
                    type: .setWindowsVersion,
                    runtime: nil,
                    windowsVersion: "win11",
                    dll: nil,
                    override: nil,
                    launchOption: nil,
                    requiresUserConfirmation: true,
                    riskLevel: .low,
                    reason: "Windows"
                ),
                nil
            ),
            (
                RecommendedAction(
                    type: .setDLLOverride,
                    runtime: nil,
                    windowsVersion: nil,
                    dll: "d3dcompiler_43.dll",
                    override: "native,builtin",
                    launchOption: nil,
                    requiresUserConfirmation: true,
                    riskLevel: .low,
                    reason: "DLL"
                ),
                nil
            ),
            (
                RecommendedAction(
                    type: .addLaunchOption,
                    runtime: nil,
                    windowsVersion: nil,
                    dll: nil,
                    override: nil,
                    launchOption: "-windowed",
                    requiresUserConfirmation: true,
                    riskLevel: .low,
                    reason: "Launch option"
                ),
                nil
            ),
            (
                RecommendedAction(
                    type: .askUserToUpdateRuntime,
                    runtime: nil,
                    windowsVersion: nil,
                    dll: nil,
                    override: nil,
                    launchOption: nil,
                    requiresUserConfirmation: true,
                    riskLevel: .medium,
                    reason: "Repair"
                ),
                nil
            ),
            (
                RecommendedAction(
                    type: .markUnsupported,
                    runtime: nil,
                    windowsVersion: nil,
                    dll: nil,
                    override: nil,
                    launchOption: nil,
                    requiresUserConfirmation: true,
                    riskLevel: .high,
                    reason: "Unsupported"
                ),
                nil
            ),
            (
                RecommendedAction(
                    type: .askUserToUpdateRuntime,
                    runtime: nil,
                    windowsVersion: nil,
                    dll: nil,
                    override: nil,
                    launchOption: nil,
                    requiresUserConfirmation: false,
                    riskLevel: .medium,
                    reason: "Update ForgePlay Runtime"
                ),
                nil
            ),
            (
                RecommendedAction(
                    type: .askUserToUpdateMacOS,
                    runtime: nil,
                    windowsVersion: nil,
                    dll: nil,
                    override: nil,
                    launchOption: nil,
                    requiresUserConfirmation: false,
                    riskLevel: .medium,
                    reason: "Update macOS"
                ),
                nil
            ),
            (
                RecommendedAction(
                    type: .noAction,
                    runtime: nil,
                    windowsVersion: nil,
                    dll: nil,
                    override: nil,
                    launchOption: nil,
                    requiresUserConfirmation: false,
                    riskLevel: .low,
                    reason: "No action"
                ),
                nil
            )
        ]

        for (action, definition) in actions {
            let steps = action.localizedRemediationSteps(
                appState: appState,
                runtimeDefinition: definition
            )
            let combined = steps.joined(separator: "\n")
            XCTAssertFalse(steps.isEmpty, "\(action.type) should provide remediation steps")
            XCTAssertNil(combined.range(of: "[가-힣]", options: .regularExpression), combined)
        }

        XCTAssertTrue(
            actions[1].0.localizedRemediationSteps(appState: appState).joined().contains("win11")
        )
        XCTAssertTrue(
            actions[2].0.localizedRemediationSteps(appState: appState).joined().contains("d3dcompiler_43.dll=native,builtin")
        )
        XCTAssertTrue(
            actions[3].0.localizedRemediationSteps(appState: appState).joined().contains("-windowed")
        )
    }

    func testCompatibilityDBUpdateButtonRequiresValidURLBeforeAction() throws {
        let source = try String(
            contentsOf: projectRoot().appending(path: "Sources/ForgePlay/UI/SettingsView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("private var compatibilityDBUpdateDisabledReason: String?"))
        XCTAssertTrue(source.contains("appState.localizedError(CompatibilityDBUpdateError.missingFeedURL)"))
        XCTAssertTrue(source.contains("services.compatibilityDBUpdateService.validateFeedURL(URL(string: trimmedURL))"))
        XCTAssertTrue(source.contains("isDisabled: compatibilityDBUpdateDisabledReason != nil"))
        XCTAssertTrue(source.contains("if let compatibilityDBUpdateDisabledReason"))
        XCTAssertTrue(source.contains("appState.localizedError(error)"))
    }

    func testSteamInstallDiagnosticGuideTitleIsLocalizedBeforePresentation() throws {
        let source = try String(
            contentsOf: projectRoot().appending(path: "Sources/ForgePlay/UI/SheetHostView.swift"),
            encoding: .utf8
        )

        XCTAssertNotNil(source.range(
            of: #"presentGuidance\s*\(\s*title:\s*appState\.localized\("Steam 설치"\)"#,
            options: .regularExpression
        ))
        XCTAssertNil(source.range(
            of: #"presentGuidance\s*\(\s*title:\s*"Steam 설치""#,
            options: .regularExpression
        ))
    }

    func testExternalActionPersistenceWarningsPreservePrimaryOutcome() throws {
        let root = try projectRoot()
        let steamLaunchView = try String(
            contentsOf: root.appending(path: "Sources/ForgePlay/UI/SteamLaunchView.swift"),
            encoding: .utf8
        )
        let setupView = try String(
            contentsOf: root.appending(path: "Sources/ForgePlay/UI/SetupView.swift"),
            encoding: .utf8
        )
        let settingsView = try String(
            contentsOf: root.appending(path: "Sources/ForgePlay/UI/SettingsView.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(steamLaunchView.contains("services.prepareSteamSharedPrefix(runtimeExecutable: gptk)"))
        XCTAssertNotNil(steamLaunchView.range(
            of: #"DiagnosticWarningText\.combined\(\s*message,[\s\S]*?launchPersistenceWarning"#,
            options: .regularExpression
        ))

        XCTAssertFalse(steamLaunchView.contains("importExistingGameFolderInBackground"))
        XCTAssertFalse(setupView.contains("importExistingGameFolderInBackground"))
        XCTAssertFalse(steamLaunchView.contains("discardImportedGameArtifacts"))
        XCTAssertFalse(setupView.contains("discardImportedGameArtifacts"))
        XCTAssertTrue(steamLaunchView.contains("private func chooseAndLinkLibrary()"))
        XCTAssertTrue(steamLaunchView.contains("appState.authorizeSteamStorageSelection(url)"))
        XCTAssertTrue(steamLaunchView.contains("try appState.connectSteamStorageMount("))
        XCTAssertTrue(steamLaunchView.contains("try appState.reconnectSteamStorageMount("))
        XCTAssertFalse(steamLaunchView.contains("releaseSteamStorageSecurityScopedAccess"))
        XCTAssertFalse(setupView.contains("private func chooseAndLinkExistingLibrary()"))
        XCTAssertNotNil(steamLaunchView.range(
            of: #"let shouldClearSelection = appState\.selectedSteamReference\?\.steamAppId == game\.steamAppId[\s\S]*?modelContext\.delete\(game\)[\s\S]*?try modelContext\.saveOrRollback\(\)[\s\S]*?if shouldClearSelection \{\s*appState\.selectedSteamReference = nil\s*\}"#,
            options: .regularExpression
        ))

        XCTAssertNotNil(settingsView.range(
            of: #"DiagnosticWarningText\.combined\(\s*updateMessage,\s*persistenceWarning\s*\)"#,
            options: .regularExpression
        ))
        XCTAssertTrue(settingsView.contains("appState.setNotice(compatibilityDBStatusMessage, kind: .failure)"))
    }

    func testSteamStorageOperationsReadPersistedRecordsAndOutliveViewNavigation() throws {
        let root = try projectRoot()
        let appState = try String(
            contentsOf: root.appending(path: "Sources/ForgePlay/App/AppState.swift"),
            encoding: .utf8
        )
        let steamLaunchView = try String(
            contentsOf: root.appending(path: "Sources/ForgePlay/UI/SteamLaunchView.swift"),
            encoding: .utf8
        )
        let dashboardView = try String(
            contentsOf: root.appending(path: "Sources/ForgePlay/UI/DashboardView.swift"),
            encoding: .utf8
        )
        let setupView = try String(
            contentsOf: root.appending(path: "Sources/ForgePlay/UI/SetupView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(appState.contains("func restorePersistedSteamStorageAccess("))
        XCTAssertTrue(appState.contains("FetchDescriptor<SteamStorageMountRecord>()"))
        XCTAssertTrue(appState.contains("FetchDescriptor<SteamGameRecord>()"))
        XCTAssertTrue(appState.contains("func beginSteamStorageConnectionOperation("))
        XCTAssertEqual(
            steamLaunchView.components(
                separatedBy: "restorePersistedSteamStorageAccess("
            ).count - 1,
            2
        )
        XCTAssertFalse(dashboardView.contains("appState.restorePersistedSteamStorageAccess("))
        XCTAssertTrue(setupView.contains("appState.restorePersistedSteamStorageAccess("))
        XCTAssertFalse(steamLaunchView.contains("steamStorageConnectionTask?.cancel()"))
        XCTAssertTrue(steamLaunchView.contains(
            "appState.steamStorageOperationMountID != nil"
        ))
    }

    func testUserPreferenceMutationsRollbackAppStateOnSaveFailure() throws {
        let root = try projectRoot()
        let appState = try String(
            contentsOf: root.appending(path: "Sources/ForgePlay/App/AppState.swift"),
            encoding: .utf8
        )
        let settingsView = try String(
            contentsOf: root.appending(path: "Sources/ForgePlay/UI/SettingsView.swift"),
            encoding: .utf8
        )
        let dashboardView = try String(
            contentsOf: root.appending(path: "Sources/ForgePlay/UI/DashboardView.swift"),
            encoding: .utf8
        )
        let debugLaunchOptions = try String(
            contentsOf: root.appending(path: "Sources/ForgePlay/App/DebugLaunchOptions.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(appState.contains("func saveUserPreferencesAfterMutation"))
        XCTAssertTrue(appState.contains("let snapshot = userPreferenceSnapshot()"))
        XCTAssertTrue(appState.contains("restoreUserPreferences(snapshot)"))

        let settingsPreferenceSaves = settingsView
            .components(separatedBy: "appState.saveUserPreferencesAfterMutation(to: modelContext)")
            .count - 1
        XCTAssertGreaterThanOrEqual(settingsPreferenceSaves, 5)
        XCTAssertFalse(settingsView.contains("appState.save(to: modelContext)"))
        XCTAssertFalse(dashboardView.contains("appState.save(to: modelContext)"))

        XCTAssertTrue(settingsView.contains("appState.isLLMDiagnosticsEnabled"))
        XCTAssertFalse(dashboardView.contains("appState.saveUserPreferencesAfterMutation(to: modelContext)"))
        XCTAssertTrue(debugLaunchOptions.contains("saveUserPreferencesAfterMutation(to: context)"))

        XCTAssertTrue(settingsView.contains("private func saveMaintenanceSettings() -> Bool"))
        XCTAssertTrue(settingsView.contains("guard !isCleaningLogs, saveMaintenanceSettings() else { return }"))
    }

    func testSetupResetPreservesManagedRootAndRestoresWorkflowStateOnSaveFailure() throws {
        let root = try projectRoot()
        let setupResetService = try String(
            contentsOf: root.appending(path: "Sources/ForgePlay/Services/SetupResetService.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(setupResetService.contains("private struct WorkflowStateSnapshot"))
        XCTAssertTrue(setupResetService.contains("var pathRoot: URL?"))
        XCTAssertTrue(setupResetService.contains("var selectedSteamReference: SteamGame?"))
        XCTAssertTrue(setupResetService.contains("var activeDiagnostics: [DiagnosticResult]"))
        XCTAssertTrue(setupResetService.contains("var latestChecks: [SystemCheckResult]"))
        XCTAssertTrue(setupResetService.contains("var setupStage: SetupStage"))
        XCTAssertTrue(setupResetService.contains("var selectedSection: AppSection"))
        XCTAssertTrue(setupResetService.contains("var presentedSheet: SheetDestination?"))
        XCTAssertTrue(setupResetService.contains("let snapshot = workflowStateSnapshot(appState)"))
        XCTAssertTrue(setupResetService.contains("context.rollback()"))
        XCTAssertTrue(setupResetService.contains("restoreWorkflowState(snapshot, appState: appState)"))
        XCTAssertTrue(setupResetService.contains("try pathManager.restoreWorkflowRoot(root)"))
        XCTAssertFalse(setupResetService.contains("pathManager.setRoot(root)"))
        XCTAssertTrue(setupResetService.contains("let managedRoot = try pathManager.rootURL ?? defaultManagedRootURL()"))
        XCTAssertTrue(setupResetService.contains("try pathManager.configureRoot(managedRoot)"))
        XCTAssertTrue(setupResetService.contains("appState.activateManagedRoot(managedRoot)"))
        XCTAssertTrue(setupResetService.contains("settings.selectedRootPath = managedRoot.path"))
        XCTAssertTrue(setupResetService.contains("settings.managedStorageLayoutVersion = ForgePlayManagedStorageLayout.currentVersion"))
        XCTAssertNotNil(setupResetService.range(
            of: #"appState\.setupStage = pathRootRestoreFailed \? \.chooseRoot : snapshot\.setupStage[\s\S]*appState\.selectedSection = pathRootRestoreFailed \? \.setup : snapshot\.selectedSection[\s\S]*appState\.presentedSheet = pathRootRestoreFailed \? nil : snapshot\.presentedSheet"#,
            options: .regularExpression
        ))
    }

    func testPrefixAndWindowsVersionLabelsResolveInEverySupportedLanguage() {
        let keys = PrefixMode.allCases.map(\.beginnerName)
            + WindowsCompatibilityVersion.allCases.map(\.label)
            + [
                "이전 프리픽스 기록",
                "알 수 없는 프리픽스 모드: %@",
                "알 수 없는 Windows 버전: %@"
            ]

        for language in ForgePlayLanguageMode.allCases where language != .system {
            for key in keys {
                let localized = ForgePlayLocalization.localized(key, language: language)
                XCTAssertFalse(localized.isEmpty, "Empty prefix detail localization for \(key) in \(language.rawValue)")
            }
        }

        XCTAssertEqual(
            ForgePlayLocalization.localized(PrefixMode.steamShared.beginnerName, language: .english),
            "Steam Prefix"
        )
        XCTAssertEqual(
            ForgePlayLocalization.localized(WindowsCompatibilityVersion.windows10.label, language: .english),
            "Windows 10 64-bit"
        )
        XCTAssertEqual(
            ForgePlayLocalization.localizedFormat(
                "알 수 없는 프리픽스 모드: %@",
                language: .english,
                arguments: ["legacy"]
            ),
            "Unknown Prefix mode: legacy"
        )
        XCTAssertEqual(
            ForgePlayLocalization.localizedFormat(
                "알 수 없는 Windows 버전: %@",
                language: .english,
                arguments: ["win11"]
            ),
            "Unknown Windows version: win11"
        )
    }

    @MainActor
    func testPrefixDisplayNamesLocalizeStoredDisplayNames() {
        let steamPrefix = PrefixRecord(
            id: PrefixIdentifier.steamShared,
            displayName: "Steam Prefix",
            path: "/tmp/SteamShared",
            mode: .steamShared
        )
        let legacyPrefix = PrefixRecord(
            id: "legacy-prefix-12345",
            displayName: "Hades 프리픽스",
            path: "/tmp/Hades",
            mode: .legacy("stored-game-prefix")
        )
        let appState = AppState()

        appState.languageMode = .english
        XCTAssertEqual(steamPrefix.localizedDisplayName(appState: appState), "Steam Prefix")
        XCTAssertEqual(legacyPrefix.localizedDisplayName(appState: appState), "Legacy Prefix Record")

        appState.languageMode = .french
        XCTAssertEqual(steamPrefix.localizedDisplayName(appState: appState), "préfixe Steam")
        XCTAssertEqual(legacyPrefix.localizedDisplayName(appState: appState), "Enregistrement de préfixe hérité")
    }

    func testDiagnosticRecordSourceLabelsResolveInEverySupportedLanguage() {
        let keys = DiagnosticRecordSource.allCases.map(\.label) + [
            "알 수 없는 진단 출처: %@"
        ]

        for language in ForgePlayLanguageMode.allCases where language != .system {
            for key in keys {
                let localized = ForgePlayLocalization.localized(key, language: language)
                XCTAssertFalse(localized.isEmpty, "Empty diagnostic source localization for \(key) in \(language.rawValue)")
            }
        }

        XCTAssertEqual(
            ForgePlayLocalization.localized(DiagnosticRecordSource.ruleEngine.label, language: .english),
            "Local Automatic Analysis (Rule Engine)"
        )
        XCTAssertEqual(
            ForgePlayLocalization.localized(DiagnosticRecordSource.appleFoundationModels.label, language: .english),
            "AI Diagnostics (Beta) · Apple Foundation Models"
        )
        XCTAssertEqual(
            ForgePlayLocalization.localizedFormat(
                "알 수 없는 진단 출처: %@",
                language: .english,
                arguments: ["legacy-provider"]
            ),
            "Unknown diagnostic source: legacy-provider"
        )
    }

    func testCompatibilitySupportStatusLabelsResolveInEverySupportedLanguage() {
        for language in ForgePlayLanguageMode.allCases where language != .system {
            for status in CompatibilitySupportStatus.allCases {
                let localized = ForgePlayLocalization.localized(status.label, language: language)
                XCTAssertFalse(localized.isEmpty, "Empty compatibility support status localization for \(status.rawValue) in \(language.rawValue)")
            }
        }

        XCTAssertEqual(
            ForgePlayLocalization.localized(CompatibilitySupportStatus.unknown.label, language: .english),
            "Unknown"
        )
    }

    func testDiagnosticLanguageNamesCoverExplicitLanguageModes() {
        XCTAssertEqual(ForgePlayLanguageMode.english.diagnosticResponseLanguageName, "English")
        XCTAssertEqual(ForgePlayLanguageMode.spanish.diagnosticResponseLanguageName, "Spanish")
        XCTAssertEqual(ForgePlayLanguageMode.traditionalChinese.diagnosticResponseLanguageName, "Traditional Chinese")
        XCTAssertFalse(ForgePlayLanguageMode.system.diagnosticResponseLanguageName.isEmpty)
    }

    func testEveryLocalizationHasSameKeySetAsEnglish() throws {
        let english = try strings(for: "en")
        let englishKeys = Set(english.keys)

        for language in ForgePlayLanguageMode.allCases where language != .system {
            let directory = try XCTUnwrap(language.localizationDirectory)
            let localized = try strings(for: directory)
            let localizedKeys = Set(localized.keys)
            let missing = englishKeys.subtracting(localizedKeys).sorted()
            let extra = localizedKeys.subtracting(englishKeys).sorted()

            XCTAssertTrue(
                missing.isEmpty && extra.isEmpty,
                "Mismatched localization keys in \(directory). Missing: \(missing.prefix(10)), extra: \(extra.prefix(10))"
            )
        }
    }

    func testSetupNavigationUsesNeutralTerminologyInEveryLanguage() throws {
        let forbiddenTermsByLocalization = [
            "ko": ["초기 설정"],
            "en": ["initial setup"],
            "de": ["ersteinrichtung"],
            "es": ["configuración inicial"],
            "fr": ["configuration initiale"],
            "ja": ["初期設定"],
            "zh-Hans": ["初始设置"],
            "zh-Hant": ["初始設定"]
        ]

        for (localization, forbiddenTerms) in forbiddenTermsByLocalization {
            let localized = try strings(for: localization)
            for (key, value) in localized where key.contains("설정") {
                let foldedValue = value.lowercased()
                for forbiddenTerm in forbiddenTerms {
                    XCTAssertFalse(
                        foldedValue.contains(forbiddenTerm.lowercased()),
                        "Stale initial-setup terminology for \(key) in \(localization): \(value)"
                    )
                }
            }
        }

        let restartGuideKey =
            "처음부터 다시 설정해야 할 때는 설정 다시 시작 기능을 사용하고, 원본 게임 파일 삭제 여부는 Finder에서 별도로 판단하세요."
        let englishRestartGuide = try XCTUnwrap(
            strings(for: "en")[restartGuideKey]
        )
        for language in ForgePlayLanguageMode.allCases
            where language != .system && language != .english {
            let localization = try XCTUnwrap(language.localizationDirectory)
            let localized = try XCTUnwrap(
                strings(for: localization)[restartGuideKey]
            )
            XCTAssertNotEqual(
                localized,
                englishRestartGuide,
                "Restart guidance falls back to English in \(localization)"
            )
        }
    }

    func testUsageGuideCriticalGuidanceHasNativeTranslations() throws {
        let keys = [
            "앱 시작 화면",
            "저장된 구성이 Windows용 Steam을 실행할 수 있으면 앱을 열 때 Steam 실행 화면으로 이동합니다. 준비가 막혀 있으면 설정 화면이 열리며, 로그나 알림이 있다는 이유만으로 대시보드가 자동으로 열리지는 않습니다.",
            "아래 순서는 현재 구현된 실행 경로와 기능을 기준으로 합니다.",
            "D3DMetal - NVIDIA는 지원되는 NVIDIA DLSS/NGX 요청을 Apple MetalFX 업스케일링으로 연결합니다.",
            "Apple WWDC25에서 MetalFX 업스케일링 보기",
            "사이드바의 업데이트 확인 (베타) 버튼은 ForgePlay 홈페이지의 공개 릴리스 정보를 확인합니다. 업데이트가 있으면 버튼을 다시 눌러 공식 릴리스 페이지를 엽니다.",
            "호환성 프로필의 필수 자동 정책은 일부 게임 보조 프로세스에 렌더러 설정이 전달되지 않도록 제한할 수 있습니다. 프로세스를 종료하거나 게임 파일·보안 모듈을 변경하거나 검증을 우회하지 않습니다.",
            "Steam 실행은 모든 게임에 공통으로 사용하는 표준 경로입니다. 그래픽 백엔드와 호환성 설정을 선택하고, 다음 실행에도 재사용하려면 저장하세요. Windows용 Steam이 열리면 라이브러리에서 게임을 실행합니다.",
            "AI 진단은 설정에서 켠 경우에만 Apple Foundation Models를 사용합니다. 외부 AI 서버로 로그를 보내는 구조가 아닙니다.",
            "지원되지 않음 또는 업데이트 권장은 현재 ForgePlay Runtime, macOS, 게임 상태에서 바로 실행하기 어렵다는 의미입니다. 로그를 보관하고 앱/런타임 업데이트를 확인하세요.",
            "호환성 DB 업데이트는 신뢰된 공개키와 HTTPS 피드가 있어야 동작합니다. 잘못된 URL이나 개인 네트워크 주소는 거부됩니다."
        ]
        let english = try strings(for: "en")

        for language in ForgePlayLanguageMode.allCases
            where language != .system && language != .english && language != .korean {
            let localization = try XCTUnwrap(language.localizationDirectory)
            let localized = try strings(for: localization)
            for key in keys {
                XCTAssertNotEqual(
                    try XCTUnwrap(localized[key]),
                    try XCTUnwrap(english[key]),
                    "Usage guidance falls back to English for \(key) in \(localization)"
                )
            }
        }
    }

    func testNonKoreanLocalizationsDoNotFallBackToKoreanText() throws {
        for language in ForgePlayLanguageMode.allCases where language != .system && language != .korean {
            let directory = try XCTUnwrap(language.localizationDirectory)
            let localized = try strings(for: directory)
            let hangulValues = localized.filter { _, value in
                value.range(of: "[가-힣]", options: .regularExpression) != nil
            }

            XCTAssertTrue(hangulValues.isEmpty, "Korean fallback text remains in \(directory): \(hangulValues.keys.sorted())")
        }
    }

    func testCommercialCriticalStringsDoNotFallBackToEnglishOutsideEnglishLocale() throws {
        let english = try strings(for: "en")
        let criticalKeys = [
            "설정 다시 검증",
            "저장 위치 선택부터 다시 진행할 수 있도록 앱의 설정 진행 상태만 초기화합니다.",
            "설정 다시 시작",
            "실제 ForgePlay 저장 폴더, 프리픽스 폴더, 게임 파일은 삭제하지 않습니다.",
            "설정 상태로 되돌릴까요?",
            "앱 상태만 초기화",
            "앱이 기억하는 Runtime, Steam 설치 파일, 프리픽스/게임/실행/진단 기록만 초기화합니다. 내부 앱 데이터 위치와 외장 Steam 저장공간 연결, 실제 파일은 그대로 둡니다.",
            "설정 상태로 되돌렸습니다. 앱 기록 %d개를 초기화했습니다.",
            "대시보드",
            "선택 사항",
            "정상",
            "문제 있음",
            "대안",
            "실행은 실패했지만 로컬 규칙으로는 원인을 특정하지 못했습니다.",
            "프로세스가 로컬 Rule Engine 매칭 없이 실패했습니다.",
            "로그를 열어 마지막 오류를 확인하고, 문제 진단 화면에서 지원 번들을 만들거나 AI 진단을 켤 수 있습니다.",
            "실행 준비 단계에서 실패했습니다. 로그를 열어 마지막 오류를 확인하고, ForgePlay Runtime 또는 Steam 프리픽스 상태를 다시 점검하세요.",
            "Steam 실행 단계에서 실패했습니다. 로그를 열어 마지막 오류를 확인하고, Steam 설치 상태와 ForgePlay Runtime 상태를 다시 점검하세요.",
            "Steam 설치 프로그램 실행 시간이 초과되었습니다. Windows 설치 창이 열려 있는지 확인하고, 로그의 마지막 오류를 확인하세요.",
            "앱 데이터를 열 수 없습니다.",
            "ForgePlay의 저장 데이터베이스를 준비하지 못했습니다. 앱을 강제 종료하지 않고 오류 정보를 표시했습니다.",
            "앱을 다시 열어도 같은 문제가 계속되면 아래 오류를 확인한 뒤 저장 위치 백업 또는 지원 번들을 준비하세요.",
            "오류 정보",
            "복구 작업을 완료하지 못했습니다.",
            "열 링크를 찾을 수 없습니다.",
            "링크를 열 수 없습니다: %@",
            "열 항목을 찾을 수 없습니다.",
            "항목을 열 수 없습니다: %@",
            "Finder에서 항목을 찾을 수 없습니다: %@",
            "Application Support 열기",
            "오류 복사",
            "앱 종료",
            "설정 저장소를 열 수 없어 설정 화면을 사용할 수 없습니다.",
            "저장된 %@ 접근 권한을 복원하지 못했습니다. 시스템 선택 창에서 다시 선택하세요.",
            "저장된 %@ 접근 권한이 만료되었습니다. 시스템 선택 창에서 다시 선택하세요.",
            "선택한 %@ 접근 권한을 저장하지 못했습니다. 시스템 선택 창에서 다시 선택해야 할 수 있습니다: %@",
            "진단 결과를 저장하지 못했습니다: %@",
            "실행 기록을 저장하지 못했습니다: %@",
            "실행 실패 기록을 저장하지 못했습니다: %@",
            "실행 결과는 저장했지만 오래된 실행 기록을 정리하지 못했습니다: %@",
            "Steam 프리픽스는 준비됐지만 기록을 저장하지 못했습니다: %@",
            "AI 문제 진단 설정을 로컬 전용 값으로 정리하지 못했습니다: %@",
            "ForgePlay Runtime 확인",
            "ForgePlay Runtime을 확인하지 못했습니다.",
            "앱에 포함된 ForgePlay Runtime만 실행 엔진으로 사용",
            "ForgePlay는 앱에 포함된 ForgePlay Runtime만 실행합니다. Apple 공식 D3DMetal 보조 렌더러를 가져와도 실행 엔진은 바뀌지 않습니다.",
            "번들 실행 엔진",
            "Steam UI와 게임 렌더러 분리",
            "Apple D3DMetal 보조 렌더러",
            "Apple 공식 DMG 또는 그 안의 redist 폴더를 선택합니다. ForgePlay는 D3DMetal 보조 파일만 관리형 앱 데이터에 복사합니다.",
            "중첩 DMG 읽기",
            "Finder에서 미리 열 필요 없이 읽기 전용으로 마운트하고 내부 Evaluation environment DMG까지 찾은 뒤 모두 해제합니다.",
            "Evaluation environment redist를 가져와도 실행 엔진은 앱에 포함된 ForgePlay Runtime으로 유지됩니다.",
            "ForgePlay Runtime은 그대로 유지하고, 사용자가 선택한 Apple D3DMetal 보조 렌더러만 게임 실행 경로에 연결합니다.",
            "ForgePlay Runtime 확인",
            "Steam 프리픽스를 만들까요?",
            "이 위치에 만들기",
            "ForgePlay 저장 위치 변경",
            "대상 위치:\n%@\n\n처음 생성은 Steam 프리픽스 초기화 때문에 몇 분 걸릴 수 있습니다. ForgePlay가 먼저 포함 Runtime 실행 여부를 확인한 뒤 진행합니다.",
            "Steam 프리픽스 생성 중",
            "생성 중",
            "ForgePlay 저장 위치를 먼저 선택하세요.",
            "ForgePlay Runtime을 확인한 뒤 Steam 프리픽스를 초기화합니다: %@",
            "Steam 프리픽스가 이미 준비되어 있습니다.",
            "Steam 프리픽스를 만드는 중입니다.",
            "Apple 공식 Evaluation environment for Windows games DMG 또는 redist 폴더를 선택하세요. ForgePlay는 D3DMetal 보조 렌더러만 앱 데이터 영역으로 가져오며, 실행에는 앱에 포함된 ForgePlay Runtime을 계속 사용합니다.",
            "Apple 페이지 열기",
            "앱에 포함된 ForgePlay Runtime은 앱 업데이트로만 복구하거나 교체할 수 있습니다.",
            "실행 문제 해결 안내",
            "%@ 실행 중 감지한 의존성/호환성 문제입니다.",
            "로컬 자동 문제 분석 결과입니다. 아래 조치를 먼저 확인하세요.",
            "감지된 문제",
            "설치 안내",
            "복구 실행",
            "문제 진단 (베타) 열기",
            "Steam 설치 프로그램 실행이 실패했습니다. SteamSetup.exe가 공식 설치 파일인지 확인하고, ForgePlay Runtime과 Steam 프리픽스 상태를 다시 점검하세요.",
            "Steam 설치 준비 단계에서 실패했습니다. ForgePlay Runtime과 Steam 프리픽스를 다시 확인하세요.",
            "Apple 공식 페이지에서 Game Porting Toolkit 또는 Evaluation environment를 받습니다. DMG는 ForgePlay가 자동 마운트해 검사합니다. Evaluation environment는 보조 라이브러리이며 단독 실행 엔진은 아닙니다.",
            "Steam 참고 목록이나 외장 라이브러리가 있어도 실행은 Windows용 Steam에서 시작합니다. SteamSetup.exe를 설치하세요.",
            "선택 사항: Steam을 새로 설치할 때만 필요합니다.",
            "필요할 때 설치",
            "%d개 설치 기록",
            "VC++, DirectX, .NET, OpenAL, XNA, PhysX 같은 Windows 필수 구성요소는 게임별로 필요할 때만 설치합니다.",
            "ForgePlay는 Microsoft/NVIDIA/OpenAL 설치 파일을 앱에 포함하거나 서버에서 내려받지 않습니다. 공식 페이지를 열어주고, 사용자가 받은 설치 파일을 선택하면 Steam 프리픽스에 설치합니다.",
            "아래 목록에서 필요한 구성요소를 고릅니다.",
            "Bundle ID: %@ · macOS 26.0+ · 배포 트랙 검토 중",
            "스캔: SteamLibrary, steamapps, steamapps/common, appmanifest_*.acf",
            "필수 구성요소(Runtime) 설치",
            "공식 다운로드 페이지에서 사용자가 받은 설치 파일만 선택합니다. ForgePlay는 설치 파일을 포함하거나 서버에서 내려받지 않습니다.",
            "설치 흐름",
            "공식 페이지를 열어 Microsoft, NVIDIA, OpenAL 등 원 출처에서 설치 파일을 받습니다.",
            "설치 안내를 열고 ForgePlay에서 요구하는 최종 설치 파일을 선택합니다.",
            "설치 대상은 Windows용 Steam이 들어 있는 Steam 프리픽스입니다.",
            "ForgePlay가 Steam 프리픽스의 스냅샷을 만든 뒤 포함 Runtime으로 설치 파일을 실행합니다.",
            "설치할 Steam 프리픽스가 없습니다. 설치 안내에서 먼저 만들 수 있습니다.",
            "설치 기록 있음",
            "필요 시 설치",
            "공식 출처: %@",
            "다운로드할 파일: %@",
            "ForgePlay에서 선택할 파일: %@",
            "설치 대상 Steam 프리픽스",
            "ForgePlay는 게임을 Windows용 Steam에서 실행하므로 필수 구성요소도 Steam 프리픽스에 설치합니다. 이전 게임별 프리픽스는 현재 실행 경로에 사용하지 않습니다.",
            "아직 기록된 Steam 프리픽스가 없습니다. 아래 버튼으로 먼저 만들거나 설정에서 Steam 프리픽스를 만드세요.",
            "Steam 프리픽스 만들기/확인",
            "설치 절차",
            "설치를 실행하려면 ForgePlay Runtime을 먼저 확인해야 합니다.",
            "설치할 Steam 프리픽스를 먼저 생성하세요.",
            "%@을 확인하는 중입니다.",
            "%@ 설치 파일 압축을 푸는 중입니다.",
            "%@을 %@에 설치하는 중입니다.",
            "%@(%@) 설치를 실행했습니다.",
            "Windows 설정을 %@로 기록했습니다.",
            "%@(%@) 누락 신호입니다. 공식 설치 파일을 받아 Steam 프리픽스에 설치해야 합니다.",
            "호환성 정보에 %@(%@) 설치 필요가 표시되어 있습니다. 공식 설치 파일을 Steam 프리픽스에 적용합니다.",
            "선택한 파일은 %@(%@) 설치 파일이 아닙니다: %@",
            "선택한 파일은 %@(%@) 압축 해제용 파일이 아닙니다: %@",
            "Runtime cache 설치 파일은 symlink나 hardlink가 아닌 일반 파일이어야 합니다: %@",
            "필수 구성요소 파일 정보를 읽지 못했습니다: %@. %@",
            "설치 파일 압축 해제에 실패했습니다. 로그를 확인하세요: %@",
            "압축을 푼 폴더를 읽을 수 없습니다: %@ (%@)",
            "압축을 풀었지만 실행할 설치 파일을 찾지 못했습니다: %@",
            "압축 해제용 파일을 받은 경우 ForgePlay에서 %@를 선택하면 RuntimeCache/ExtractedInstallers에 풀고 추출된 설치 파일을 이어서 실행합니다.",
            "ForgePlay는 Steam 프리픽스의 스냅샷을 먼저 만든 뒤, 포함 Runtime으로 설치 파일을 그 Steam 프리픽스 안에서 실행합니다.",
            "선택한 설치 파일은 ForgePlay 저장 위치의 RuntimeCache/Installers에 복사되어 같은 파일을 다시 찾을 수 있습니다.",
            "DLL 파일만 따로 내려받아 게임 폴더에 복사하지 마세요. 공식 설치 프로그램으로 Steam 프리픽스에 설치해야 등록 정보와 의존 DLL이 같이 들어갑니다.",
            "%@ 설치 준비 단계에서 실패했습니다. ForgePlay Runtime과 Steam 프리픽스를 다시 확인하세요.",
            "64-bit 게임은 vc_redist.x64.exe를 먼저 설치하고, 32-bit/Wow64 로그가 보이면 vc_redist.x86.exe도 같은 프리픽스에 설치합니다.",
            "msvcr120.dll 또는 msvcp120.dll 오류는 보통 Visual C++ 2013 재배포 패키지로 처리합니다.",
            "msvcr110.dll 또는 msvcp110.dll 오류는 보통 Visual C++ 2012 Update 4 재배포 패키지로 처리합니다.",
            "msvcr100.dll 또는 msvcp100.dll 오류는 보통 Visual C++ 2010 SP1 재배포 패키지로 처리합니다.",
            "DirectX June 2010 redist를 받은 경우 ForgePlay에서 그 파일을 선택해도 됩니다. ForgePlay가 압축을 풀고 추출된 DXSETUP.exe를 이어서 실행합니다.",
            "오프라인 설치 파일(ndp48-x86-x64-allos-enu.exe)을 우선 권장합니다. 웹 설치 파일은 ForgePlay Runtime의 네트워크 상태에 따라 실패할 수 있습니다.",
            ".NET 4.0 전용 런처가 아니면 먼저 .NET Framework 4.8을 설치해 보고, 계속 4.0을 요구할 때만 이 설치 파일을 선택합니다.",
            "OpenAL 페이지에서 zip을 받았다면 먼저 압축을 풀고 내부의 oalinst.exe를 ForgePlay에서 선택합니다.",
            "2007년 전후 AGEIA/legacy PhysX 게임이면 NVIDIA 페이지의 Legacy Installer 링크에서 받은 설치 파일을 같은 프리픽스에 추가로 설치합니다.",
            "저장된 호환성 정보가 있습니다: %@",
            "Steam 프리픽스를 확인하는 중입니다.",
            "Steam 프리픽스가 준비되었습니다.",
            "Steam 프리픽스 준비 단계에서 실패했습니다. ForgePlay Runtime과 저장 위치를 다시 확인하세요.",
            "선택한 설치 파일이 이 필수 구성요소와 맞지 않습니다.",
            "선택한 파일은 이 필수 구성요소의 압축 해제용 파일이 아닙니다.",
            "선택한 설치 파일이 이 필수 구성요소와 맞지 않습니다. 선택 가능한 파일: %@",
            "필수 구성요소 설치 도구",
            "AI 문제 진단(베타) · Apple Foundation Models",
            "사용자가 켠 경우에만 문제 기록을 로컬 온디바이스 AI로 보조 분석합니다.",
            "기본값은 꺼짐입니다. 켜면 로그를 외부 서버로 보내지 않고, 분석 전 가려진 내용을 확인한 뒤 이 Mac의 Apple Foundation Models로만 분석합니다.",
            "Apple Foundation Models를 사용할 수 있습니다.",
            "이 Mac은 Apple Intelligence 기반 로컬 AI 진단을 지원하지 않습니다.",
            "시스템 설정에서 Apple Intelligence를 켜야 로컬 AI 진단을 사용할 수 있습니다.",
            "Apple Intelligence 모델을 준비하는 중입니다. 다운로드가 끝난 뒤 다시 시도하세요.",
            "AI 문제 진단이 꺼져 있습니다.",
            "AI 진단 응답에 사용할 수 있는 기술 요약이 없습니다.",
            "AI 문제 진단을 켰습니다. Apple Foundation Models를 사용할 수 있을 때만 실행됩니다.",
            "AI 문제 진단을 껐습니다. 로컬 자동 문제 분석은 계속 사용할 수 있습니다.",
            "Apple Foundation Models는 로컬 보조 진단에만 사용합니다. 권장 조치는 앱의 허용 목록과 사용자 확인을 모두 거친 뒤에만 적용됩니다.",
            "AI 로컬 분석(베타) 전 미리보기",
            "이 내용으로 로컬 AI 진단(베타) 실행",
            "이 빌드에는 원격 호환성 DB 서명 검증 키가 없어 업데이트를 적용하지 않습니다.",
            "먼저 로컬 자동 문제 분석(Rule Engine)을 사용하고, 사용자가 켠 경우에만 Apple Foundation Models로 로컬 AI 보조 진단을 실행합니다.",
            "Apple Foundation Models로 AI 문제 진단을 실행하는 중입니다.",
            "AI 문제 진단 결과를 저장했습니다.",
            "켜짐. 분석 전 가려진 내용을 확인한 뒤 로컬 AI로만 진단합니다.",
            "이 Mac의 Apple Intelligence 온디바이스 모델",
            "먼저 로컬 자동 문제 분석을 사용합니다. AI 문제 진단은 설정에서 켠 경우에만 분석 전 미리보기를 거쳐 이 Mac의 Apple Foundation Models로 실행합니다.",
            "%@ 설치는 끝났지만 Steam 프리픽스 기록을 저장하지 못했습니다: %@",
            "미확인",
            "Steam 라이브러리 참고 목록을 찾는 중입니다.",
            "대상 위치:\n%@\n\n처음 생성은 Steam 프리픽스 초기화 때문에 몇 분 걸릴 수 있습니다. ForgePlay가 먼저 포함 Runtime 실행 여부를 확인한 뒤 진행합니다.",
            "선택했던 파일을 찾을 수 없습니다: %@",
            "설치 파일은 선택됨: %@. Steam 실행 파일은 아직 찾지 못했습니다.",
            "ForgePlay 저장 위치를 먼저 선택해야 합니다.",
            "저장 위치를 적용하는 중입니다.",
            "현재 위치: %@\n새 위치: %@",
            "선택한 Steam 프리픽스를 사용할 수 없습니다.",
            "선택한 Steam 프리픽스를 사용할 수 없습니다: %@",
            "Steam 프리픽스 폴더는 symlink가 아닌 일반 폴더여야 합니다: %@",
            "Steam 프리픽스 메타데이터는 symlink가 아닌 일반 파일이어야 합니다: %@",
            "Steam 프리픽스 파일 정보를 읽지 못했습니다: %@. %@",
            "Steam 프리픽스 메타데이터가 너무 큽니다: %@ %d bytes / limit %d bytes",
            "Steam 프리픽스 메타데이터가 올바르지 않습니다: %@",
            "Steam 프리픽스에 필요한 항목을 찾을 수 없습니다: %@",
            "Steam 프리픽스에 필요한 항목이 안전한 일반 파일/폴더가 아닙니다: %@",
            "Steam 프리픽스에 필요한 항목을 읽지 못했습니다: %@. %@",
            "Steam 프리픽스 메타데이터를 사용할 수 없습니다: %@. %@",
            "Steam 프리픽스 아키텍처가 일치하지 않습니다: %@. 예상: %@, 실제: %@",
            "ForgePlay Runtime을 확인할 수 없습니다. %@",
            "ForgePlay Runtime을 실행해 확인하지 못했습니다. 로그를 확인하세요: %@",
            "Apple 보조 렌더러 입력을 검사하지 못했습니다: %@. %@",
            "Evaluation environment redist를 검사하지 못했습니다: %@. %@",
            "Evaluation environment redist 안의 symlink가 redist 폴더 밖을 가리킵니다: %@",
            "Evaluation environment redist 안의 hardlink 파일을 제거해야 합니다: %@",
            "Apple 보조 렌더러 교체에 실패했고 기존 파일을 되돌리지 못했습니다: %@. 백업 위치: %@. 원인: %@. 복구 오류: %@",
            "이전 ForgePlay 저장 위치를 사용할 수 없어 다시 선택해야 합니다: %@",
            "이전 저장 위치를 찾을 수 없습니다: %@",
            "선택한 위치에 쓸 수 없습니다: %@",
            "필요한 폴더를 만들 수 없습니다: %@",
            "선택한 위치가 안전한 일반 폴더가 아닙니다: %@",
            "저장 위치를 확인하지 못했습니다: %@. %@",
            "저장 위치를 확인하지 못했습니다: %@",
            "기존 저장 위치 안쪽이나 바깥쪽의 상위 폴더로는 바로 복사할 수 없습니다. 별도의 빈 폴더를 선택하세요.",
            "기존 데이터를 복사하려면 비어 있는 폴더를 선택해야 합니다: %@",
            "저장 위치를 옮기기에 공간이 부족합니다. 필요 공간: %@, 여유 공간: %@",
            "저장 위치를 옮기기 전에 외부를 가리키는 symlink를 제거해야 합니다: %@",
            "저장 위치를 옮기기 전에 hardlink 파일을 제거해야 합니다: %@",
            "저장 기록의 %@ JSON을 UTF-8 텍스트로 저장하지 못했습니다.",
            "저장 위치 이동에 실패했고 부분 복사본을 정리하지 못했습니다: %@. 원인: %@. 정리 오류: %@",
            "Steam 공식 페이지에서 받은 일반 파일 SteamSetup.exe를 선택해야 합니다: %@",
            "Steam 설치 파일 정보를 읽지 못했습니다: %@. %@",
            "Steam 참고 실행 파일 후보를 검사하지 못했습니다: %@. %@",
            "Steam 참고 실행 파일 후보 정보를 읽지 못했습니다: %@. %@",
            "로그 파일은 symlink/hardlink가 아닌 일반 파일이어야 합니다: %@",
            "최근 로그 폴더를 검사하지 못했습니다: %@. %@",
            "최근 로그 파일 정보를 읽지 못했습니다: %@. %@",
            "최근 로그 파일을 UTF-8 텍스트로 읽지 못했습니다: %@",
            "지원 번들 압축 파일을 만들지 못했습니다. 로그를 확인하세요: %@",
            "지원 번들 압축 파일을 만들지 못했고 부분 파일을 정리하지 못했습니다: %@. 로그: %@. 정리 오류: %@",
            "지원 번들 압축 결과를 검증하지 못했습니다: %@. %@",
            "지원 번들 자료 폴더를 검사하지 못했습니다: %@. %@",
            "지원 번들 자료 파일 정보를 읽지 못했습니다: %@. %@",
            "Steam 명령 전달됨 · 수동 확인 필요",
            "Windows용 Steam 실행 명령은 전달됐지만 실제 프로세스 실행 증거를 확인하지 못했습니다. Steam 창을 직접 확인해야 하며, 검은 화면이면 성공으로 보지 않습니다.",
            "로그 폴더를 검사하지 못했습니다: %@. %@",
            "로그 파일 정보를 읽지 못했습니다: %@. %@",
            "실행 규칙 DB 업데이트 주소를 먼저 입력해야 합니다.",
            "호환성 DB 갱신",
            "데이터 출처 %@ · 목록 기준일 %@ · 제보 %d건",
            "앱 포함 데이터",
            "홈페이지에서 갱신한 데이터",
            "공식 홈페이지의 호환성 DB를 확인하고 안전하게 저장했습니다.",
            "현재 호환성 목록은 그대로 유지됩니다. %@",
            "호환성 DB를 갱신하지 못했습니다. 네트워크 연결을 확인하고 다시 시도하세요.",
            "실행 규칙 DB 업데이트는 HTTPS 주소만 사용할 수 있습니다.",
            "실행 규칙 DB 업데이트 주소는 호스트가 있는 HTTPS URL이어야 하며, 사용자 정보나 프래그먼트 또는 민감한 쿼리 매개변수를 포함할 수 없습니다.",
            "실행 규칙 파일은 HTTPS 주소만 사용할 수 있습니다: %@",
            "실행 규칙 파일은 symlink/hardlink가 아닌 일반 파일이어야 합니다: %@",
            "실행 규칙 descriptor가 올바르지 않습니다: %@",
            "실행 규칙 descriptor ID가 중복되었습니다: %@",
            "실행 규칙 DB index에 포함된 recipe가 너무 많습니다: %d / limit %d",
            "실행 규칙 DB 업데이트가 공개 HTTPS 최종 주소가 아닌 곳으로 이동해 중단했습니다: %@",
            "실행 규칙 DB 업데이트 서버 응답이 올바르지 않습니다: %@ HTTP %d",
            "실행 규칙 DB 업데이트 응답이 너무 큽니다: %@ %d bytes / limit %d bytes",
            "이 앱에는 원격 실행 규칙 DB 서명 검증 키가 포함되어 있지 않아 원격 업데이트를 적용하지 않습니다.",
            "실행 규칙 DB 서명 검증 키를 읽을 수 없습니다.",
            "지원하지 않는 실행 규칙 DB schema version입니다: %d",
            "실행 규칙 DB index.json 서명이 올바르지 않습니다.",
            "실행 규칙 파일 서명이 올바르지 않습니다: %@",
            "실행 규칙 파일 무결성 검사가 실패했습니다: %@",
            "실행 규칙 파일 ID가 인덱스와 일치하지 않습니다. 예상: %@, 실제: %@",
            "실행 규칙 파일을 해석할 수 없습니다: %@",
            "실행 파일을 찾을 수 없습니다: %@",
            "실행 파일은 symlink/hardlink가 아닌 일반 파일이어야 합니다: %@",
            "실행 입력 경로가 안전한 일반 파일/폴더가 아닙니다: %@",
            "압축 파일 경로가 안전한 일반 경로가 아닙니다: %@",
            "로그 파일을 만들 수 없습니다: %@",
            "실행 입력 경로 정보를 읽지 못했습니다: %@. %@",
            "ForgePlay Runtime의 라이브러리 경로를 검사하지 못했습니다: %@. %@"
        ]

        for language in ForgePlayLanguageMode.allCases where language != .system && language != .korean && language != .english {
            let directory = try XCTUnwrap(language.localizationDirectory)
            let localized = try strings(for: directory)

            for key in criticalKeys {
                XCTAssertNotEqual(
                    localized[key],
                    english[key],
                    "English fallback remains for commercial-critical key \(key) in \(directory)"
                )
            }
        }
    }

    func testUserFacingSwiftUIStringLiteralsUseLocalizationAccessors() throws {
        let projectRoot = try projectRoot()
        let sourceRoots = [
            projectRoot.appending(path: "Sources/ForgePlay/App"),
            projectRoot.appending(path: "Sources/ForgePlay/UI")
        ]
        let patterns = [
            #"\b(?:Text|Label|Button|Picker|Toggle|TextField|DisclosureGroup)\(\s*"[^"\n]*[가-힣]"#,
            #"\.confirmationDialog\(\s*"[^"\n]*[가-힣]"#,
            #"\.accessibilityLabel\(\s*"[^"\n]*[가-힣]"#
        ]
        let regexes = try patterns.map { try NSRegularExpression(pattern: $0) }
        var violations: [String] = []

        for sourceRoot in sourceRoots {
            guard let enumerator = FileManager.default.enumerator(
                at: sourceRoot,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                XCTFail("Could not enumerate source root \(sourceRoot.path)")
                continue
            }

            for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
                let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else { continue }
                let source = try String(contentsOf: fileURL, encoding: .utf8)
                let range = NSRange(source.startIndex..<source.endIndex, in: source)
                for regex in regexes where regex.firstMatch(in: source, range: range) != nil {
                    violations.append(fileURL.path.replacingOccurrences(of: projectRoot.path + "/", with: ""))
                    break
                }
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            "SwiftUI text controls must pass Korean UI literals through appState.localized or a localizing component: \(violations.sorted())"
        )
    }

    func testSetupAndSettingsStatusHelpersLocalizeDisplayValuesBeforeReturning() throws {
        let projectRoot = try projectRoot()
        let setupView = try String(contentsOf: projectRoot.appending(path: "Sources/ForgePlay/UI/SetupView.swift"), encoding: .utf8)
        let settingsView = try String(contentsOf: projectRoot.appending(path: "Sources/ForgePlay/UI/SettingsView.swift"), encoding: .utf8)
        let dashboardView = try String(contentsOf: projectRoot.appending(path: "Sources/ForgePlay/UI/DashboardView.swift"), encoding: .utf8)
        let domainModels = try String(contentsOf: projectRoot.appending(path: "Sources/ForgePlay/Models/DomainModels.swift"), encoding: .utf8)

        let requiredFragments = [
            (setupView, #"appState.selectedRootURL?.path ?? appState.localized("앱 데이터 위치를 준비하는 중입니다.")"#),
            (setupView, #"return appState.localized("앱 데이터를 준비한 뒤 Mac 상태를 확인합니다.")"#),
            (setupView, #"return appState.localized("앱 데이터 관리: Prefixes, RuntimeCache, Logs, Snapshots, Config · 외장: 사용자가 선택한 Steam 게임 라이브러리")"#),
            (setupView, #"return appState.localized("실패 시 Logs/Launch + Rule Engine 진단")"#),
            (setupView, #"? appState.localized("Steam 프리픽스가 이미 준비되어 있습니다.")"#),
            (setupView, #"summary.blockingResults.map { appState.localized($0.detail) }.joined(separator: " ")"#),
            (settingsView, #"value: games.isEmpty ? appState.localized("Steam 참고 기록이 아직 없습니다.")"#),
            (settingsView, #"return appState.localized("아직 Mac 상태를 확인하지 않았습니다.")"#),
            (settingsView, #"return appState.localized("ForgePlay Runtime을 확인하지 못했습니다.")"#),
            (settingsView, #"return appState.localized("SteamSetup.exe를 선택해 Steam 프리픽스 안에 설치해야 합니다.")"#),
            (settingsView, #"? appState.localized("AI 문제 진단을 켰습니다. Apple Foundation Models를 사용할 수 있을 때만 실행됩니다.")"#),
            (settingsView, #"summary.blockingResults.map { appState.localized($0.detail) }.joined(separator: " ")"#),
            (settingsView, #"Text(compatibilityDBStatusMessage)"#),
            (setupView, #"guard let refreshToken = services.beginSteamReferenceRefresh() else"#),
            (setupView, #"defer { services.endSteamReferenceRefresh(refreshToken) }"#),
            (dashboardView, #"return appState.localized("설치 필요")"#),
            (dashboardView, #"readiness.hasSteamPrefix ? appState.localized("Steam 프리픽스")"#),
            (domainModels, #"technical: "Renderer""#)
        ]

        for (source, fragment) in requiredFragments {
            XCTAssertTrue(source.contains(fragment), "Expected localized display helper fragment: \(fragment)")
        }

        let runtimeStatusSources: [(name: String, source: String)] = [
            ("SetupView", setupView),
            ("SettingsView", settingsView),
            ("DashboardView", dashboardView)
        ]
        let publishedRuntimeSnapshot =
            #"appState.latestChecks.first { $0.category == .windowsRuntime }"#
        let localizedRuntimeDetail =
            #"appState.localized(runtimeSystemCheck.detail)"#

        for runtimeStatusSource in runtimeStatusSources {
            XCTAssertTrue(
                runtimeStatusSource.source.contains(
                    #"private var runtimeSystemCheck: SystemCheckResult? {"#
                ),
                "\(runtimeStatusSource.name) must expose the published Windows Runtime system-check snapshot."
            )
            let snapshotRange = try XCTUnwrap(
                runtimeStatusSource.source.range(of: publishedRuntimeSnapshot),
                "\(runtimeStatusSource.name) must read the Windows Runtime result from appState.latestChecks."
            )
            let localizedDetailRange = try XCTUnwrap(
                runtimeStatusSource.source.range(of: localizedRuntimeDetail),
                "\(runtimeStatusSource.name) must localize the published runtimeSystemCheck.detail."
            )
            XCTAssertLessThan(
                snapshotRange.lowerBound,
                localizedDetailRange.lowerBound,
                "\(runtimeStatusSource.name) must derive display text from its published runtime snapshot."
            )
        }

        let forbiddenFragments = [
            #"return appState.selectedRootURL?.path ?? "아직 저장 위치를 선택하지 않았습니다.""#,
            #"return "아직 Mac 상태를 확인하지 않았습니다.""#,
            #"failed.map(\.detail).joined(separator: " ")"#,
            #"Text(appState.localized(compatibilityDBStatusMessage))"#,
            #"return games.isEmpty ? "설치 필요" : "선택 사항""#,
            #"return games.isEmpty ? appState.localized("설치 필요") : appState.localized("선택 사항")"#,
            #"? "AI 문제 진단을 켰습니다. Apple Foundation Models를 사용할 수 있을 때만 실행됩니다.""#,
            #"WindowsRuntimeDisplayName."#,
            #"services.windowsRuntimeService.inspectRuntimeCapability"#,
            #"technical: "D3DMetal""#,
            #"return gptk.path"#
        ]

        let combinedSource = [setupView, settingsView, dashboardView, domainModels].joined(separator: "\n")
        for fragment in forbiddenFragments {
            XCTAssertFalse(combinedSource.contains(fragment), "Display helper must not return raw Korean UI text: \(fragment)")
        }
    }

    @MainActor
    func testRuntimeCapabilityInspectionFailureBecomesAnExplicitSystemCheckError()
        async throws
    {
        let fileManager = FileManager.default
        let fixtureRoot = fileManager.temporaryDirectory.appending(
            path: "ForgePlay-RuntimeInspectionFailure-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? fileManager.removeItem(at: fixtureRoot) }

        let managedRoot = fixtureRoot.appending(path: "Managed", directoryHint: .isDirectory)
        let executable = fixtureRoot.appending(
            path: "BundledResources/Runners/ForgePlayRuntime/wine/bin/wine"
        )
        try writeExecutable(at: executable, exitCode: 0)

        let pathManager = PathManager(fileManager: fileManager)
        try pathManager.configureRoot(managedRoot)
        let externalRenderer = fixtureRoot.appending(
            path: "ExternalRenderer",
            directoryHint: .isDirectory
        )
        try fileManager.createDirectory(
            at: externalRenderer,
            withIntermediateDirectories: true
        )
        let rendererRoot = ForgePlaySupplementalRendererPolicy
            .rendererRoot(forManagedRoot: managedRoot)
        try fileManager.createDirectory(
            at: rendererRoot.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.createSymbolicLink(
            at: rendererRoot,
            withDestinationURL: externalRenderer
        )

        let runner = SafeProcessRunner(
            fileManager: FileManager(),
            sandboxEnabled: false,
            runtimeLaunchObjectIdentityProvider: { _ in nil },
            windowsRuntimeValidator: { candidate, _ in
                guard candidate.standardizedFileURL == executable.standardizedFileURL else {
                    throw ForgePlayRuntimeCapabilityError.nonBundledRuntimeRejected(
                        actionName: "runtime-inspection-test",
                        path: candidate.path
                    )
                }
            }
        )
        let runtimeService = WindowsRuntimeService(
            pathManager: pathManager,
            runner: runner,
            fileManager: fileManager,
            bundledRuntimeExecutableProvider: { executable }
        )
        let service = SystemCheckService(
            pathManager: pathManager,
            windowsRuntimeService: runtimeService,
            prefixManager: PrefixManager(pathManager: pathManager, runner: runner),
            canRunBundledWindowsRuntime: { true },
            runtimeTranslationAvailability: { "available" }
        )

        let checks = await service.runChecks(
            rootURL: managedRoot,
            runtimeExecutable: executable
        )
        let runtimeCheck = try XCTUnwrap(
            checks.first { $0.category == .windowsRuntime }
        )

        XCTAssertEqual(runtimeCheck.status, .error)
        XCTAssertEqual(
            runtimeCheck.detail,
            "앱에 포함된 ForgePlay Runtime을 확인하는 중 오류가 발생했습니다."
        )
        XCTAssertNotNil(runtimeCheck.technicalDetail)
        XCTAssertTrue(
            runtimeCheck.technicalDetail?.contains("supplementalRedistScanFailed") == true ||
                runtimeCheck.technicalDetail?.contains("WindowsRuntimeServiceError") == true,
            "The underlying inspection failure must remain available for diagnostics."
        )
    }

    func testNoticeBannerDisplaysPreparedMessageWithoutRelocalizing() throws {
        let projectRoot = try projectRoot()
        let rootView = try String(contentsOf: projectRoot.appending(path: "Sources/ForgePlay/UI/RootView.swift"), encoding: .utf8)
        let appState = try String(contentsOf: projectRoot.appending(path: "Sources/ForgePlay/App/AppState.swift"), encoding: .utf8)

        XCTAssertTrue(rootView.contains("Text(notice.message)"))
        XCTAssertFalse(rootView.contains("Text(appState.localized(notice.message))"))
        XCTAssertNotNil(appState.range(
            of: #"func setNotice\(\s*_ message: String,\s*kind: AppNoticeKind,"#,
            options: .regularExpression
        ))
    }

    func testSettingsLanguageSelectionIsVisibleAdaptiveAndAccessible() throws {
        let settingsView = try String(
            contentsOf: projectRoot().appending(path: "Sources/ForgePlay/UI/SettingsView.swift"),
            encoding: .utf8
        )

        let languageOptionsStart = try XCTUnwrap(
            settingsView.range(of: "private func languageSelectionOptions")
        )
        let languageOptionsEnd = try XCTUnwrap(
            settingsView[languageOptionsStart.upperBound...].range(
                of: "private func generalPreferencesGrid"
            )
        )
        let languageOptionsSource = String(
            settingsView[languageOptionsStart.lowerBound..<languageOptionsEnd.lowerBound]
        )
        XCTAssertTrue(languageOptionsSource.contains("LazyVGrid"))
        XCTAssertTrue(languageOptionsSource.contains("ForgePlayLanguageMode.allCases"))
        XCTAssertTrue(languageOptionsSource.contains("languageOptionButton"))
        XCTAssertFalse(languageOptionsSource.contains(".labelsHidden()"))

        let languageButtonStart = try XCTUnwrap(
            settingsView.range(of: "private func languageOptionButton")
        )
        let languageButtonEnd = try XCTUnwrap(
            settingsView[languageButtonStart.upperBound...].range(
                of: "private func generalPreferencesGrid"
            )
        )
        let languageButtonSource = String(
            settingsView[languageButtonStart.lowerBound..<languageButtonEnd.lowerBound]
        )
        XCTAssertTrue(languageButtonSource.contains("Button"))
        XCTAssertTrue(languageButtonSource.contains("setLanguageModeFromUserSelection"))
        XCTAssertTrue(languageButtonSource.contains("saveUserPreferencesAfterMutation"))
        XCTAssertTrue(languageButtonSource.contains("contentShape(Rectangle())"))
        XCTAssertTrue(languageButtonSource.contains(
            ".accessibilityLabel(languageOptionDisplayName(language))"
        ))
        XCTAssertTrue(languageButtonSource.contains(".accessibilityValue"))
        XCTAssertTrue(languageButtonSource.contains(".lineLimit(nil)"))
    }

    func testSharedActionButtonsUseFullSurfaceHitTargetsAndHoverFeedback() throws {
        let components = try String(
            contentsOf: projectRoot().appending(path: "Sources/ForgePlay/UI/Components.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(components.contains("struct ForgeActionButtonStyle: ButtonStyle"))
        XCTAssertTrue(components.contains(".frame(maxWidth: .infinity, minHeight: minimumHeight)"))
        XCTAssertTrue(components.contains(".contentShape(Rectangle())"))
        XCTAssertTrue(components.contains(".onHover { isHovering = $0 }"))
        XCTAssertTrue(components.contains("let showsHover = isEnabled && isHovering && !configuration.isPressed"))
        XCTAssertTrue(components.contains(".allowsHitTesting(false)"))
        XCTAssertTrue(components.contains("reduceMotion ? nil : .easeOut(duration:"))
    }

    func testSteamLaunchRuntimeBadgesUseAdaptiveFlowLayout() throws {
        let projectRoot = try projectRoot()
        let components = try String(
            contentsOf: projectRoot.appending(path: "Sources/ForgePlay/UI/Components.swift"),
            encoding: .utf8
        )
        let steamLaunchView = try String(
            contentsOf: projectRoot.appending(path: "Sources/ForgePlay/UI/SteamLaunchView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(components.contains("struct AdaptiveFlowLayout: Layout"))
        XCTAssertTrue(steamLaunchView.contains("RuntimeDependencyWorkflowCard()"))
        XCTAssertFalse(steamLaunchView.contains("GameDetailView("))
        XCTAssertFalse(steamLaunchView.contains("game.graphicsBackendSelection"))
    }

    func testSteamLaunchTopLevelLayoutUsesSteamLaunchPanelsInsteadOfSplitGameDetail() throws {
        let projectRoot = try projectRoot()
        let steamLaunchView = try String(
            contentsOf: projectRoot.appending(path: "Sources/ForgePlay/UI/SteamLaunchView.swift"),
            encoding: .utf8
        )
        let localizedResources = try ForgePlayLanguageMode.allCases
            .compactMap(\.localizationDirectory)
            .map {
                try String(
                    contentsOf: projectRoot.appending(path: "Resources/\($0).lproj/Localizable.strings"),
                    encoding: .utf8
                )
            }
            .joined(separator: "\n")

        XCTAssertTrue(steamLaunchView.contains("ForgePageScaffold("))
        XCTAssertTrue(steamLaunchView.contains("@State private var selectedWorkspace: SteamWorkspace = .launch"))
        XCTAssertTrue(steamLaunchView.contains(".pickerStyle(.segmented)"))
        XCTAssertTrue(steamLaunchView.contains("steamLaunchPanel(palette: palette)"))
        XCTAssertTrue(steamLaunchView.contains("manualRendererSelectionGrid(palette: palette)"))
        XCTAssertTrue(steamLaunchView.contains("experimentalGameModeControl(palette: palette)"))
        XCTAssertTrue(steamLaunchView.contains("Text(appState.localized(\"Game Mode\"))"))
        XCTAssertFalse(steamLaunchView.contains("Game Mode (베타)"))
        XCTAssertTrue(steamLaunchView.contains(
            "repeating: GridItem(.flexible(), spacing: 8)"
        ))
        XCTAssertTrue(steamLaunchView.contains(
            ".frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)"
        ))
        XCTAssertFalse(steamLaunchView.contains(
            ".frame(maxWidth: .infinity, minHeight: 76"
        ))
        let launchPanelRange = try XCTUnwrap(
            steamLaunchView.range(of: "private func steamLaunchPanel")
        )
        let primaryActionsDefinitionRange = try XCTUnwrap(
            steamLaunchView.range(
                of: "private func steamLaunchPrimaryActions(",
                range: launchPanelRange.upperBound..<steamLaunchView.endIndex
            )
        )
        let launchPanelSource = String(
            steamLaunchView[
                launchPanelRange.lowerBound..<primaryActionsDefinitionRange.lowerBound
            ]
        )
        let actionRange = try XCTUnwrap(
            launchPanelSource.range(of: "steamLaunchPrimaryActions")
        )
        let rendererRange = try XCTUnwrap(
            launchPanelSource.range(
                of: "manualRendererSelectionGrid(palette: palette)"
            )
        )
        XCTAssertLessThan(actionRange.lowerBound, rendererRange.lowerBound)
        let rendererDetailRange = try XCTUnwrap(
            launchPanelSource.range(
                of: "selectedRendererForNextSteamLaunch?.detailKey"
            )
        )
        XCTAssertTrue(
            launchPanelSource.contains("cachedSelectedRendererLaunchBlocker")
        )
        let gameModeRange = try XCTUnwrap(
            launchPanelSource.range(
                of: "experimentalGameModeControl(palette: palette)"
            )
        )
        let compatibilityControlsRange = try XCTUnwrap(
            launchPanelSource.range(
                of: "steamCompatibilitySelectionControls(palette: palette)"
            )
        )
        XCTAssertLessThan(rendererRange.lowerBound, rendererDetailRange.lowerBound)
        XCTAssertLessThan(rendererDetailRange.lowerBound, gameModeRange.lowerBound)
        XCTAssertLessThan(gameModeRange.lowerBound, compatibilityControlsRange.lowerBound)
        XCTAssertTrue(
            launchPanelSource.contains(
                "ForEach(StandardSteamLaunchPanelSection.ordered, id: \\.self)"
            )
        )
        let orderedSectionsStart = try XCTUnwrap(
            steamLaunchView.range(of: "static let ordered: [Self] = [")
        )
        let orderedSectionsEnd = try XCTUnwrap(
            steamLaunchView[orderedSectionsStart.upperBound...].range(of: "]")
        )
        let orderedSectionsSource = String(
            steamLaunchView[
                orderedSectionsStart.lowerBound..<orderedSectionsEnd.upperBound
            ]
        )
        let orderedSectionTokens = [
            ".renderer",
            ".frameGeneration",
            ".gameMode",
            ".compatibility",
            ".keyboard",
            ".controller",
            ".configurationState"
        ]
        for (earlier, later) in zip(
            orderedSectionTokens,
            orderedSectionTokens.dropFirst()
        ) {
            let earlierRange = try XCTUnwrap(orderedSectionsSource.range(of: earlier))
            let laterRange = try XCTUnwrap(orderedSectionsSource.range(of: later))
            XCTAssertLessThan(earlierRange.lowerBound, laterRange.lowerBound)
        }
        let primaryActionsSource = String(
            steamLaunchView[primaryActionsDefinitionRange.lowerBound...]
        )
        XCTAssertTrue(primaryActionsSource.contains("title: \"Steam 실행\""))
        XCTAssertTrue(primaryActionsSource.contains("title: \"설정 저장\""))
        XCTAssertTrue(primaryActionsSource.contains("let availability = standardLaunchAvailability"))
        XCTAssertFalse(primaryActionsSource.contains("guard standardLaunchDraftIsSaved else"))
        XCTAssertFalse(steamLaunchView.contains("standardSteamLaunchActionTitle"))
        XCTAssertFalse(steamLaunchView.contains("저장된 구성으로 Steam 실행"))
        XCTAssertFalse(steamLaunchView.contains("저장하고 Steam 실행"))
        XCTAssertTrue(steamLaunchView.contains("? .experimentalRequiredHost"))
        XCTAssertTrue(steamLaunchView.contains(": .standard"))
        XCTAssertFalse(steamLaunchView.contains("steamRendererPolicyPanel(palette: palette)"))
        XCTAssertFalse(steamLaunchView.contains("Game Mode 필수"))
        XCTAssertFalse(steamLaunchView.contains("자동 라우팅"))
        for retiredRendererCopy in [
            "자동 모드입니다. 현재 실행 엔진에서 확인된 %@ 변환을 Steam 실행에 적용합니다.",
            "자동 모드입니다. Windows용 Steam은 직접 실행하고, Steam 안에서 실행할 게임에는 현재 실행 엔진에서 확인된 %@ 변환을 우선 사용합니다.",
            "Steam 클라이언트 실행은 시도할 수 있지만, 이 실행 엔진에서 현대 Direct3D 게임용 D3DMetal/DXVK 백엔드는 확인되지 않았습니다.",
            "Windows용 Steam 실행은 가능하지만, 현대 Direct3D 게임용 D3DMetal/DXVK 렌더러는 포함되어 있지 않습니다.",
            "같은 오류가 반복되면 Vulkan/DXVK로 바꾼 뒤 Steam 안에서 같은 게임을 다시 실행해 두 결과를 비교합니다.",
            "현재 ForgePlay Runtime에서 사용할 수 있는 D3DMetal 또는 Vulkan/DXVK 게임 렌더러 payload를 찾지 못했습니다."
        ] {
            XCTAssertFalse(
                localizedResources.contains(retiredRendererCopy),
                "Retired renderer copy remains localized: \(retiredRendererCopy)"
            )
        }
        XCTAssertTrue(steamLaunchView.contains("libraryManagementPanel(palette: palette)"))
        XCTAssertTrue(steamLaunchView.contains("steamReferenceRecordsPanel(palette: palette)"))
        XCTAssertFalse(steamLaunchView.contains("steamRendererRecoveryActionTitleKey"))
        XCTAssertFalse(steamLaunchView.contains("@State private var isRefreshingSteamReferences = false"))
        XCTAssertTrue(steamLaunchView.contains("guard let refreshToken = services.beginSteamReferenceRefresh() else"))
        XCTAssertTrue(steamLaunchView.contains("isDisabled: services.isSteamReferenceRefreshInProgress"))
        XCTAssertTrue(steamLaunchView.contains("defer { services.endSteamReferenceRefresh(refreshToken) }"))
        XCTAssertTrue(steamLaunchView.contains("rendererInspection.recoveryStatusLabelKey"))
        XCTAssertTrue(steamLaunchView.contains("ViewThatFits(in: .horizontal)"))
        XCTAssertTrue(steamLaunchView.contains("steamReferenceRecordDetails(game, palette: palette)"))
        XCTAssertTrue(steamLaunchView.contains("AdaptivePathText("))
        XCTAssertFalse(steamLaunchView.contains("text: game.libraryPath"))
        XCTAssertFalse(steamLaunchView.contains("GeometryReader { geometry in"))
        XCTAssertFalse(steamLaunchView.contains("GameDetailView"))
        XCTAssertFalse(steamLaunchView.contains("gameListPanel(palette: palette"))
        XCTAssertFalse(steamLaunchView.contains("private enum GameListPresentation"))
    }

    func testLaunchViewsKeepPrimaryActionsAboveRendererSettings() throws {
        let projectRoot = try projectRoot()
        let compatibilityView = try String(
            contentsOf: projectRoot.appending(
                path: "Sources/ForgePlay/UI/SteamCompatibilityLaunchView.swift"
            ),
            encoding: .utf8
        )
        let utilityView = try String(
            contentsOf: projectRoot.appending(
                path: "Sources/ForgePlay/UI/WindowsUtilityLaunchView.swift"
            ),
            encoding: .utf8
        )

        let compatibilityAction = try XCTUnwrap(
            compatibilityView.range(of: "actionCard(palette: palette)")
        )
        let compatibilityProfile = try XCTUnwrap(
            compatibilityView.range(
                of: "profileAndManifestSelectionCard(palette: palette)"
            )
        )
        let compatibilityOptions = try XCTUnwrap(
            compatibilityView.range(of: "profileOptionsCard(palette: palette)")
        )
        XCTAssertLessThan(
            compatibilityAction.lowerBound,
            compatibilityProfile.lowerBound
        )
        XCTAssertLessThan(
            compatibilityAction.lowerBound,
            compatibilityOptions.lowerBound
        )
        XCTAssertTrue(compatibilityView.contains("title: \"Steam 실행\""))
        XCTAssertFalse(compatibilityView.contains("!compatibilityDraftIsPersisted"))
        XCTAssertFalse(compatibilityView.contains("호환성 Steam 실행 및 설정 저장"))
        XCTAssertFalse(compatibilityView.contains("설정 저장 후 호환성 Steam 실행"))

        let utilityFileAction = try XCTUnwrap(
            utilityView.range(of: "title: \"EXE 파일 선택\"")
        )
        let utilityLaunchAction = try XCTUnwrap(
            utilityView.range(of: ": \"같은 프리픽스에서 실행\"")
        )
        let utilityRendererSettings = try XCTUnwrap(
            utilityView.range(
                of: "Text(appState.localized(\"선택 그래픽 백엔드\"))"
            )
        )
        XCTAssertLessThan(
            utilityFileAction.lowerBound,
            utilityRendererSettings.lowerBound
        )
        XCTAssertLessThan(
            utilityLaunchAction.lowerBound,
            utilityRendererSettings.lowerBound
        )
        XCTAssertTrue(
            utilityView.contains(
                "고전 게임·독립 실행형 프로그램·패처·설정 도구를 현재 SteamShared 프리픽스에서 기본 Runtime으로 실행합니다."
            )
        )
        XCTAssertTrue(
            utilityView.contains(
                "SteamShared 프리픽스에서 실행할 고전 게임·독립 실행형 프로그램·패처·설정 도구를 선택하세요."
            )
        )
        XCTAssertFalse(
            utilityView.contains(
                "subtitle: \"패처·설정 도구를 현재 SteamShared 프리픽스에서 기본 Runtime으로 실행합니다.\""
            )
        )
        XCTAssertFalse(
            utilityView.contains(
                "SteamShared 프리픽스에서 실행할 패처 또는 설정 도구를 선택하세요."
            )
        )
    }

    func testSteamLaunchPrimaryActionsUseValidatedInMemoryDraftsWithoutPersistenceGate() throws {
        let projectRoot = try projectRoot()
        let standardView = try String(
            contentsOf: projectRoot.appending(path: "Sources/ForgePlay/UI/SteamLaunchView.swift"),
            encoding: .utf8
        )
        let compatibilityView = try String(
            contentsOf: projectRoot.appending(
                path: "Sources/ForgePlay/UI/SteamCompatibilityLaunchView.swift"
            ),
            encoding: .utf8
        )

        let standardLaunchStart = try XCTUnwrap(standardView.range(of: "private func launchSteam()"))
        let standardLaunchSource = String(standardView[standardLaunchStart.lowerBound...])
        XCTAssertFalse(standardLaunchSource.contains("guard standardLaunchDraftIsSaved else"))
        XCTAssertFalse(standardLaunchSource.contains("persistCurrentStandardLaunchConfiguration()"))
        XCTAssertFalse(standardLaunchSource.contains("snapshot.canonicalDigest == savedDigest"))
        XCTAssertTrue(
            standardLaunchSource.contains(
                "let selection = try currentStandardLaunchProductSelection()"
            )
        )

        let compatibilityLaunchStart = try XCTUnwrap(
            compatibilityView.range(of: "private func saveAndPrepareSteamSession()")
        )
        let compatibilityLaunchEnd = try XCTUnwrap(
            compatibilityView[compatibilityLaunchStart.upperBound...].range(
                of: "private func completeSteamSession()"
            )
        )
        let compatibilityLaunchSource = String(
            compatibilityView[compatibilityLaunchStart.lowerBound..<compatibilityLaunchEnd.lowerBound]
        )
        XCTAssertFalse(
            compatibilityLaunchSource.contains(
                "compatibilityDraftIsPersisted,"
            )
        )
        XCTAssertFalse(compatibilityLaunchSource.contains("persistCurrentDraft()"))
        XCTAssertTrue(
            compatibilityLaunchSource.contains(
                "let oneLaunchOverride = currentOneLaunchOverride()"
            )
        )
        XCTAssertTrue(
            compatibilityLaunchSource.contains("if currentDraftIsPersisted")
        )
    }

    func testSteamRendererExposureAndSaveConfirmationStayInTheProductUI() throws {
        let projectRoot = try projectRoot()
        let standardView = try String(
            contentsOf: projectRoot.appending(
                path: "Sources/ForgePlay/UI/SteamLaunchView.swift"
            ),
            encoding: .utf8
        )
        let compatibilityView = try String(
            contentsOf: projectRoot.appending(
                path: "Sources/ForgePlay/UI/SteamCompatibilityLaunchView.swift"
            ),
            encoding: .utf8
        )
        let rootView = try String(
            contentsOf: projectRoot.appending(
                path: "Sources/ForgePlay/UI/RootView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(
            standardView.contains(
                "SteamRendererPolicySelection.currentReleaseSelectableCases"
            )
        )
        XCTAssertTrue(
            standardView.contains(
                "repeating: GridItem(.flexible(), spacing: 8)"
            )
        )
        XCTAssertTrue(standardView.contains("count: 3"))
        XCTAssertTrue(
            compatibilityView.contains("\\.isCurrentReleaseUserSelectable")
        )
        XCTAssertFalse(standardView.contains("standardLaunchSaveConfirmation"))
        XCTAssertTrue(rootView.contains("TaskBanner(notice: notice)"))
        XCTAssertTrue(
            rootView.contains("if let notice = appState.currentNotice")
        )
        XCTAssertFalse(rootView.contains("notice: appState.currentNotice"))
        XCTAssertTrue(
            standardView.contains("clearStandardLaunchSaveNoticeLater(notice.id)")
        )
        XCTAssertTrue(standardView.contains("Task.sleep(for: .seconds(5))"))
        XCTAssertTrue(
            standardView.contains(
                "appState.setNotice(\n                message,\n                kind: .success"
            )
        )
    }

    @MainActor
    func testCurrentNoticeBannerHostObservesIdleNoticeChanges() {
        let appState = AppState()
        let hostingView = NSHostingView(
            rootView: CurrentNoticeBannerHost().environment(appState)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 900, height: 180)
        hostingView.layoutSubtreeIfNeeded()
        let emptyHeight = hostingView.fittingSize.height

        let firstNotice = appState.setNotice("Saved", kind: .success)
        for _ in 0..<8 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            hostingView.layoutSubtreeIfNeeded()
        }
        let visibleHeight = hostingView.fittingSize.height
        XCTAssertGreaterThan(visibleHeight, emptyHeight + 1)

        _ = appState.setNotice("Newer", kind: .progress)
        appState.clearNotice(id: firstNotice.id)
        for _ in 0..<4 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            hostingView.layoutSubtreeIfNeeded()
        }
        XCTAssertGreaterThan(hostingView.fittingSize.height, emptyHeight + 1)

        appState.clearNotice()
        for _ in 0..<8 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            hostingView.layoutSubtreeIfNeeded()
        }
        XCTAssertLessThanOrEqual(
            hostingView.fittingSize.height,
            emptyHeight + 1
        )
    }

    func testFrameGenerationBetaAndNVIDIACopyHasEightLocaleParity() {
        let keys = [
            "Frame Generation (베타)",
            "D3DMetal - NVIDIA에서 원본 프레임 사이에 보간 프레임을 생성해 선택한 표시 목표에 맞춥니다. 현재 베타 기능이며 게임과 입력 방식에 따라 입력 지연이 늘어날 수 있습니다.",
            "Frame Generation (베타)은 현재 D3DMetal - NVIDIA에서만 켤 수 있습니다.",
            "Frame Generation (베타) 설정을 확인하세요. 이 기능은 현재 D3DMetal - NVIDIA에서만 사용할 수 있고 Frame Check는 Frame Generation을 켠 경우에만 사용할 수 있습니다.",
            "그래픽 %@ · Frame Generation (베타) %@ · Frame Check %@ · 네트워크 %@ · 오디오 입력 %@ · 동기화 %@ · 게임 비디오 메모리 %@ · Game Mode %@ · FPS 커서 %@ · 컨트롤러 %@ · 키보드 %@",
            "이전에 저장한 숨겨진 그래픽 백엔드를 현재 선택 가능한 D3DMetal - NVIDIA로 바꾼 저장되지 않은 초안입니다. 저장하기 전에는 기존 저장값을 덮어쓰지 않습니다."
        ]

        for language in ForgePlayLanguageMode.allCases where language != .system {
            for key in keys {
                let localized = ForgePlayLocalization.localized(
                    key,
                    language: language
                )
                XCTAssertFalse(localized.isEmpty)
                XCTAssertEqual(placeholders(in: key), placeholders(in: localized))
                if language != .korean {
                    XCTAssertNotEqual(localized, key)
                    XCTAssertNil(
                        localized.range(
                            of: "[가-힣]",
                            options: .regularExpression
                        )
                    )
                }
            }
        }
    }

    func testLaunchAvailabilityCarriesOnePrimaryActionMessage() {
        let available = LaunchAvailability.available(message: "ready")
        XCTAssertTrue(available.isAvailable)
        XCTAssertEqual(available.message, "ready")
        XCTAssertNil(available.disabledReason)

        let unavailable = LaunchAvailability.unavailable(reason: "save first")
        XCTAssertFalse(unavailable.isAvailable)
        XCTAssertEqual(unavailable.message, "save first")
        XCTAssertEqual(unavailable.disabledReason, "save first")
    }

    func testSteamPrimaryActionsShareTypedAvailabilityAndVisibleReasons() throws {
        let projectRoot = try projectRoot()
        let components = try String(
            contentsOf: projectRoot.appending(path: "Sources/ForgePlay/UI/Components.swift"),
            encoding: .utf8
        )
        let standardView = try String(
            contentsOf: projectRoot.appending(path: "Sources/ForgePlay/UI/SteamLaunchView.swift"),
            encoding: .utf8
        )
        let compatibilityView = try String(
            contentsOf: projectRoot.appending(
                path: "Sources/ForgePlay/UI/SteamCompatibilityLaunchView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(components.contains("enum LaunchAvailability: Equatable"))
        XCTAssertTrue(standardView.contains(
            "private var standardLaunchAvailability: LaunchAvailability"
        ))
        XCTAssertTrue(compatibilityView.contains(
            "private var compatibilityLaunchAvailability: LaunchAvailability"
        ))

        for source in [standardView, compatibilityView] {
            XCTAssertTrue(source.contains("let availability ="))
            XCTAssertTrue(source.contains("isDisabled: !availability.isAvailable"))
            XCTAssertTrue(source.contains(".help(availability.message)"))
            XCTAssertTrue(source.contains(".accessibilityHint(availability.message)"))
            XCTAssertTrue(source.contains("if let disabledReason = availability.disabledReason"))
        }
        XCTAssertFalse(compatibilityView.contains("private var saveAndPrepareIsDisabled"))
    }

    @MainActor
    func testPrefixKeyboardDefaultIsSeparateFromConfigurableHostModifierMapping() throws {
        XCTAssertEqual(
            SteamLaunchConfigurationSnapshot.standardDefault.keyboardMapping,
            .systemDefault,
            "Prefix launch configuration remains a no-mutation input contract."
        )

        let appState = AppState()
        appState.isGameInputModifierMappingEnabled = true
        appState.setGameInputModifierBinding(.command, to: .control)
        appState.setGameInputModifierBinding(.option, to: .control)
        appState.setGameInputModifierBinding(.control, to: .disabled)

        XCTAssertEqual(
            appState.gameInputModifierMap,
            GameInputModifierMap(
                command: .control,
                option: .control,
                control: .disabled
            ),
            "Host modifier mapping must support duplicate destinations and disabled keys."
        )
        XCTAssertEqual(GameInputModifierBinding.control.rawValue, "control")
        XCTAssertEqual(GameInputModifierBinding.alt.rawValue, "alt")
        XCTAssertEqual(GameInputModifierBinding.disabled.rawValue, "disabled")
        XCTAssertThrowsError(
            try ModifierKeyPermutation(
                command: .control,
                option: .control,
                control: .alt
            )
        ) { error in
            XCTAssertEqual(
                error as? SteamLaunchConfigurationError,
                .invalidKeyboardMapping("modifier-role-not-bijective")
            )
        }
    }

    func testCompatibilityLaunchSelectsOnlyOneCanonicalPersistedStorageMount() {
        let rootRecord = SteamStorageMountRecord(
            id: "root",
            path: "/Volumes/Steam/./",
            bookmark: Data("root-bookmark".utf8)
        )
        let nestedRecord = SteamStorageMountRecord(
            id: "nested",
            path: "/Volumes/Steam/SteamLibrary",
            bookmark: Data("nested-bookmark".utf8)
        )
        let missingBookmarkRecord = SteamStorageMountRecord(
            id: "missing-bookmark",
            path: "/Volumes/Other",
            bookmark: nil
        )
        let candidates = [rootRecord, nestedRecord, missingBookmarkRecord]
            .compactMap { record -> CompatibilityManifestMountCandidate? in
                guard let bookmark = record.bookmark, !bookmark.isEmpty else { return nil }
                return CompatibilityManifestMountCandidate(
                    id: record.id,
                    path: record.path,
                    bookmark: bookmark
                )
            }

        XCTAssertEqual(rootRecord.path, "/Volumes/Steam")
        XCTAssertEqual(
            CompatibilityManifestMountSelectionPolicy.matchingCandidates(
                libraryPath: "/Volumes/Steam/steamapps",
                candidates: [candidates[0]]
            ).map(\.id),
            ["root"]
        )
        XCTAssertEqual(
            CompatibilityManifestMountSelectionPolicy.matchingCandidates(
                libraryPath: "/Volumes/Steam/SteamLibrary/steamapps",
                candidates: candidates
            ).map(\.id),
            ["root", "nested"],
            "Multiple persisted mount owners are ambiguous and must not be guessed."
        )
        XCTAssertTrue(
            CompatibilityManifestMountSelectionPolicy.matchingCandidates(
                libraryPath: "/Volumes/Steam2/steamapps",
                candidates: candidates
            ).isEmpty,
            "A sibling path with the same textual prefix is not inside the approved mount."
        )
        XCTAssertFalse(candidates.contains { $0.id == missingBookmarkRecord.id })
    }

    func testCompatibilityStatusUsesTypedSeverityAndOnlyRealDiagnosticLogs() throws {
        let source = try String(
            contentsOf: projectRoot().appending(
                path: "Sources/ForgePlay/UI/SteamCompatibilityLaunchView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("private enum CompatibilityStatusKind: Equatable"))
        for status in ["case progress", "case success", "case warning", "case failure"] {
            XCTAssertTrue(source.contains(status))
        }
        XCTAssertTrue(source.contains("compatibilityStatusView("))
        XCTAssertTrue(source.contains("checkmark.circle.fill"))
        XCTAssertTrue(source.contains("exclamationmark.triangle.fill"))
        XCTAssertTrue(source.contains("xmark.octagon.fill"))
        XCTAssertTrue(source.contains(".accessibilityValue(status.message)"))
        XCTAssertTrue(source.contains(
            "(error as? ForgePlayDiagnosticLogProvidingError)?.forgePlayDiagnosticLogURL"
        ))
        XCTAssertTrue(source.contains("if let logURL = status.logURL"))
        XCTAssertTrue(source.contains("appState.revealInFinder(logURL)"))
        XCTAssertFalse(source.contains("statusMessage"))
    }

    func testPrefixAndHostKeyboardCopyHasEightLocaleParity() throws {
        let keys = [
            "키보드 입력",
            "System Default",
            "지원되지 않는 이전 키보드 저장 값이 있습니다. System Default로 복원한 뒤 설정을 저장하세요.",
            "지원되지 않는 이전 키보드 저장 값입니다. 프로필 권장값을 복원한 뒤 설정을 저장하세요.",
            "System Default로 복원",
            "지원되지 않는 이전 저장 값",
            "Steam 프리픽스 내부 키보드 입력은 System Default로 유지됩니다. 호스트 보조키 매핑과 macOS 단축키 보호는 설정 > 입력 및 게임 보호에서 관리합니다.",
            "프리픽스 키보드 입력은 읽기 전용이며 System Default로 유지됩니다. 호스트 입력 보호는 설정에서 관리합니다.",
            "게임용 보조키 매핑 사용",
            "물리 Command 키",
            "물리 Option 키",
            "물리 Control 키",
            "Ctrl로 전달",
            "Alt로 전달",
            "전달 안 함",
            "이 게임과 정확히 일치하는 승인된 SteamLibrary 북마크를 찾지 못했습니다. Steam 매니페스트 루트를 직접 선택하세요.",
            "관리 ForgePlay Runtime 권한을 자동 준비하지 못했습니다. 관리 Runtime을 다시 확인하세요.",
            "지원되지 않는 프로필 옵션이 있습니다: %@. 프로필 권장값을 복원한 뒤 저장하세요."
        ]

        for language in ForgePlayLanguageMode.allCases where language != .system {
            let directory = try XCTUnwrap(language.localizationDirectory)
            let localizations = try strings(for: directory)
            for key in keys {
                let localized = try XCTUnwrap(
                    localizations[key],
                    "Missing launch requirement localization for \(directory): \(key)"
                )
                XCTAssertFalse(localized.isEmpty)
                XCTAssertEqual(placeholders(in: key), placeholders(in: localized))
                if language != .korean {
                    XCTAssertNil(
                        localized.range(of: "[가-힣]", options: .regularExpression),
                        "Korean fallback remains in \(directory): \(localized)"
                    )
                }
            }
        }
    }

    func testSteamLaunchBetaLabelsAndFinalGameModeLabelHaveEightLocaleParity() throws {
        let keys = [
            "Steam 실행",
            "Game Mode",
            "네트워크 (베타)",
            "오디오 입력 (베타)",
            "게임 비디오 메모리 (베타)"
        ]

        for language in ForgePlayLanguageMode.allCases where language != .system {
            let directory = try XCTUnwrap(language.localizationDirectory)
            let localizations = try strings(for: directory)
            for key in keys {
                XCTAssertFalse(
                    try XCTUnwrap(localizations[key]).isEmpty,
                    "Missing \(key) localization for \(directory)"
                )
            }
            XCTAssertNil(
                localizations["Game Mode (베타)"],
                "Retired Game Mode beta label remains in \(directory)"
            )
            XCTAssertNil(
                localizations[
                    "Game Mode(베타) 호스트를 요청했습니다. 실제 활성화 여부는 게임을 macOS 전체 화면으로 전환한 뒤 직접 확인해야 합니다."
                ],
                "Retired Game Mode beta status copy remains in \(directory)"
            )
        }
    }

    func testSteamProfileAndRosettaErrorsHaveEightLocalePlaceholderParity() throws {
        let keys = [
            "이 Steam 호환성 프로필 버전은 지원되지 않습니다(%lld). ForgePlay를 업데이트한 뒤 다시 시도하세요.",
            "이 Steam 호환성 레시피 버전은 지원되지 않습니다(%lld). ForgePlay를 업데이트한 뒤 다시 시도하세요.",
            "Steam 호환성 레시피를 사용할 수 없습니다(%@). 기본 설정으로 되돌린 뒤 다시 시도하세요.",
            "선택한 게임과 저장된 Steam 호환성 프로필이 일치하지 않습니다. 해당 게임의 호환성 설정을 다시 여세요.",
            "저장된 Steam 호환성 설정을 사용할 수 없습니다(%@). 설정을 기본값으로 재설정하세요.",
            "저장된 Steam 호환성 설정 파일을 읽을 수 없습니다(%@). 설정을 기본값으로 재설정하세요.",
            "Steam 라이브러리 접근 권한을 확인할 수 없습니다(%@). 라이브러리 폴더를 다시 연결하세요.",
            "필수 자동 호환성 정책은 끌 수 없습니다. 자동 정책을 복원한 뒤 다시 시도하세요.",
            "현재 실행 환경은 선택한 Steam 호환성 옵션을 지원하지 않습니다(%@=%@). 지원되는 옵션을 선택하거나 기본값으로 되돌리세요.",
            "Steam 호환성 설정이 실행 전에 확인되지 않았습니다(%@). 다시 시도하고 문제가 계속되면 진단 정보를 확인하세요.",
            "이전 Steam 호환성 설정을 변환할 수 없습니다(%@). 설정을 기본값으로 재설정하세요.",
            "Rosetta AVX 설정 값이 올바르지 않습니다. FORGEPLAY_ROSETTA_ADVERTISE_AVX에는 0 또는 1만 사용하세요."
        ]

        for language in ForgePlayLanguageMode.allCases where language != .system {
            let directory = try XCTUnwrap(language.localizationDirectory)
            let localizations = try strings(for: directory)
            for key in keys {
                let localized = try XCTUnwrap(
                    localizations[key],
                    "Missing Steam profile error localization for \(directory): \(key)"
                )
                XCTAssertFalse(localized.isEmpty)
                XCTAssertEqual(
                    placeholders(in: key),
                    placeholders(in: localized),
                    "Placeholder mismatch for \(directory): \(key)"
                )
                if language != .korean {
                    XCTAssertNil(
                        localized.range(of: "[가-힣]", options: .regularExpression),
                        "Korean fallback remains in \(directory): \(localized)"
                    )
                }
            }
        }
    }

    func testSteamLaunchHeadersKeepOnlyContextualHelpActions() throws {
        let projectRoot = try projectRoot()
        let componentSource = try String(
            contentsOf: projectRoot.appending(path: "Sources/ForgePlay/UI/Components.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(componentSource.contains("let headerActions: HeaderActions"))
        XCTAssertFalse(componentSource.contains("SettingsView()"))
        XCTAssertFalse(componentSource.contains("systemImage: \"folder\""))

        for path in [
            "Sources/ForgePlay/UI/SteamLaunchView.swift",
            "Sources/ForgePlay/UI/SteamCompatibilityLaunchView.swift"
        ] {
            let source = try String(
                contentsOf: projectRoot.appending(path: path),
                encoding: .utf8
            )
            let scaffoldStart = try XCTUnwrap(source.range(of: "ForgePageScaffold("))
            let contentStart = try XCTUnwrap(
                source[scaffoldStart.upperBound...].range(of: "} content:")
            )
            let headerSource = String(source[scaffoldStart.lowerBound..<contentStart.lowerBound])
            XCTAssertTrue(headerSource.contains("SectionHelpButton("))
            XCTAssertFalse(headerSource.contains("Settings"))
            XCTAssertFalse(headerSource.contains("설정"))
            XCTAssertFalse(headerSource.contains("folder"))
            XCTAssertFalse(headerSource.contains("externaldrive"))
        }
    }

    func testSteamLaunchSavedDraftChecksRestoreStandardBeforeYielding() throws {
        let projectRoot = try projectRoot()
        let standardView = try String(
            contentsOf: projectRoot.appending(path: "Sources/ForgePlay/UI/SteamLaunchView.swift"),
            encoding: .utf8
        )
        let compatibilityView = try String(
            contentsOf: projectRoot.appending(
                path: "Sources/ForgePlay/UI/SteamCompatibilityLaunchView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertFalse(standardView.contains(".task {\n            await Task.yield()"))
        XCTAssertTrue(standardView.contains("restoreStandardLaunchConfigurationOnce()"))
        XCTAssertTrue(standardView.contains(
            "if standardLaunchConfigurationRestoreState == .pending"
        ))
        XCTAssertTrue(compatibilityView.contains(".task {\n            await Task.yield()"))
        XCTAssertFalse(standardView.contains("currentStandardLaunchConfigurationDigest"))

        let compatibilityPersistedStart = try XCTUnwrap(
            compatibilityView.range(of: "private var compatibilityDraftIsPersisted: Bool")
        )
        let compatibilityPersistedEnd = try XCTUnwrap(
            compatibilityView[compatibilityPersistedStart.upperBound...].range(
                of: "private func restoreActiveSessionPresentationIfAvailable()"
            )
        )
        let compatibilityPersistedSource = String(
            compatibilityView[
                compatibilityPersistedStart.lowerBound..<compatibilityPersistedEnd.lowerBound
            ]
        )
        XCTAssertFalse(compatibilityPersistedSource.contains("canonicalDigest"))
        XCTAssertFalse(compatibilityView.contains("persistedDraftDigest"))
        XCTAssertTrue(
            compatibilityPersistedSource.contains(
                "currentPayload == savedEnvelope.payload"
            )
        )
    }

    func testSteamLaunchReadinessProjectionTracksOnlyCurrentEnvironmentRecords() {
        let staleEnvironment = LaunchRecord(
            id: "stale-environment",
            prefixId: PrefixIdentifier.steamShared,
            commandKind: "launchSteam",
            startedAt: Date(timeIntervalSince1970: 30),
            steamUIVerificationStatus: SteamUIVerificationState.failed.rawValue,
            hostAppSessionID: "session-current",
            environmentGenerationID: "generation-old"
        )
        let currentEnvironment = LaunchRecord(
            id: "current-environment",
            prefixId: PrefixIdentifier.steamShared,
            commandKind: "launchSteam",
            startedAt: Date(timeIntervalSince1970: 20),
            steamUIVerificationStatus: SteamUIVerificationState.launchedButUnverified.rawValue,
            hostAppSessionID: "session-current",
            environmentGenerationID: "generation-current"
        )
        let unrelatedCommand = LaunchRecord(
            id: "unrelated-command",
            prefixId: "game-prefix",
            commandKind: "launchGame",
            startedAt: Date(timeIntervalSince1970: 40),
            hostAppSessionID: "session-current",
            environmentGenerationID: "generation-current"
        )
        let records = [unrelatedCommand, staleEnvironment, currentEnvironment]

        XCTAssertEqual(
            SteamLaunchRecordLookup.latestSteamLaunchRecord(
                from: records,
                environmentGenerationID: "generation-current",
                currentAppSessionID: "session-current"
            )?.id,
            currentEnvironment.id
        )
        XCTAssertEqual(
            SteamLaunchRecordLookup.latestSteamLaunchRecordFromNewestFirst(
                records.sorted { $0.startedAt > $1.startedAt },
                environmentGenerationID: "generation-current",
                currentAppSessionID: "session-current"
            )?.id,
            currentEnvironment.id
        )

        let before = SteamLaunchRecordLookup.newestFirstReadinessFingerprint(
            from: records.sorted { $0.startedAt > $1.startedAt },
            environmentIdentity: SteamEnvironmentIdentity(
                generationID: "generation-current",
                createdAt: nil
            ),
            currentAppSessionID: "session-current"
        )
        currentEnvironment.markSteamUIBlackScreenSuspected(
            now: Date(timeIntervalSince1970: 50)
        )
        let after = SteamLaunchRecordLookup.newestFirstReadinessFingerprint(
            from: records.sorted { $0.startedAt > $1.startedAt },
            environmentIdentity: SteamEnvironmentIdentity(
                generationID: "generation-current",
                createdAt: nil
            ),
            currentAppSessionID: "session-current"
        )

        XCTAssertNotEqual(before, after)
        XCTAssertEqual(currentEnvironment.steamUIVerificationState, .blackScreenSuspected)
        XCTAssertFalse(before.records.contains { $0.id == unrelatedCommand.id })
    }

    func testSteamPersistenceRecoveryKeepsReloadForConflictsAndUsesRecommendationsAfterReadFailure() throws {
        let projectRoot = try projectRoot()
        let standardView = try String(
            contentsOf: projectRoot.appending(path: "Sources/ForgePlay/UI/SteamLaunchView.swift"),
            encoding: .utf8
        )
        let compatibilityView = try String(
            contentsOf: projectRoot.appending(
                path: "Sources/ForgePlay/UI/SteamCompatibilityLaunchView.swift"
            ),
            encoding: .utf8
        )

        let recoveryActionsStart = try XCTUnwrap(
            standardView.range(of: "if let standardLaunchConfigurationErrorMessage")
        )
        let recoveryActionsEnd = try XCTUnwrap(
            standardView[recoveryActionsStart.upperBound...].range(
                of: "ViewThatFits(in: .horizontal)"
            )
        )
        let recoveryActionsSource = String(
            standardView[
                recoveryActionsStart.lowerBound..<recoveryActionsEnd.lowerBound
            ]
        )
        XCTAssertTrue(
            recoveryActionsSource.contains(
                "if standardLaunchConfigurationRestoreIsBlocked ||"
            )
        )
        XCTAssertTrue(
            recoveryActionsSource.contains("savedStandardLaunchConfigurationVersion != nil")
        )
        XCTAssertFalse(
            recoveryActionsSource.contains("!standardLaunchConfigurationReloadIsAvailable")
        )

        let resetStart = try XCTUnwrap(
            standardView.range(of: "private func resetBlockedStandardLaunchConfiguration()")
        )
        let reloadStart = try XCTUnwrap(
            standardView.range(of: "private func reloadLatestStandardLaunchConfiguration(")
        )
        let resetSource = String(
            standardView[resetStart.lowerBound..<reloadStart.lowerBound]
        )
        XCTAssertTrue(resetSource.contains("try repository.resetStandard("))
        XCTAssertTrue(resetSource.contains("reloadLatestStandardLaunchConfiguration("))
        XCTAssertFalse(resetSource.contains("applyRestoredStandardLaunchConfiguration("))

        XCTAssertTrue(
            compatibilityView.contains("if isPersistenceBlocked || mustReloadAfterConflict")
        )
        let compatibilityLoadStart = try XCTUnwrap(
            compatibilityView.range(of: "private func loadSelectedRecipeDraft()")
        )
        let compatibilityLoadEnd = try XCTUnwrap(
            compatibilityView[compatibilityLoadStart.upperBound...].range(
                of: "private func setAllUserProvenance"
            )
        )
        let compatibilityLoadSource = String(
            compatibilityView[
                compatibilityLoadStart.lowerBound..<compatibilityLoadEnd.lowerBound
            ]
        )
        XCTAssertTrue(compatibilityLoadSource.contains("isPersistenceBlocked = false"))
        XCTAssertFalse(compatibilityLoadSource.contains("isPersistenceBlocked = true"))
        XCTAssertTrue(compatibilityLoadSource.contains("} catch {"))
        XCTAssertTrue(compatibilityLoadSource.contains("savedEnvelope = nil"))
        XCTAssertTrue(
            compatibilityLoadSource.contains(
                "draftSelections = selectedRecipe.recommendations.selections"
            )
        )
        XCTAssertTrue(
            compatibilityLoadSource.contains("setAllUserProvenance(.recipe)")
        )
        XCTAssertTrue(
            compatibilityLoadSource.contains("compatibilityDraftSaveFailed = true")
        )
        let validationRange = try XCTUnwrap(
            compatibilityLoadSource.range(of: "SteamCompatibilityLaunchResolverV1.resolveDraft(")
        )
        let unblockRange = try XCTUnwrap(
            compatibilityLoadSource.range(of: "isPersistenceBlocked = false")
        )
        XCTAssertLessThan(validationRange.lowerBound, unblockRange.lowerBound)
    }

    @MainActor
    func testSteamLaunchVerificationLifecyclePersistsUserVisibleStates() throws {
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let startedAt = Date(timeIntervalSince1970: 10)
        let record = try context.createSteamLaunchRecord(
            appSessionID: "session-current",
            environmentGenerationID: "generation-current",
            startedAt: startedAt
        )
        let launchResult = ProcessRunResult(
            actionName: "launchSteam",
            executable: URL(fileURLWithPath: "/tmp/wine"),
            arguments: [],
            startedAt: startedAt,
            endedAt: Date(timeIntervalSince1970: 11),
            exitCode: 0,
            hasProcessExitCode: false,
            stdoutLog: URL(fileURLWithPath: "/tmp/stdout.log"),
            stderrLog: URL(fileURLWithPath: "/tmp/stderr.log"),
            didTimeOut: false,
            waitedForExit: false,
            outcome: .runningDetached
        )

        try context.saveSteamLaunchResult(launchResult, for: record)
        XCTAssertEqual(record.status, "launchedUnverified")
        XCTAssertEqual(record.steamUIVerificationState, .launchedButUnverified)

        try context.markSteamUISurface(
            .library,
            for: record,
            now: Date(timeIntervalSince1970: 12)
        )
        let persisted = try XCTUnwrap(
            try context.fetch(FetchDescriptor<LaunchRecord>()).first
        )
        XCTAssertEqual(persisted.status, "finished")
        XCTAssertEqual(persisted.steamUIVerificationState, .rendered)
        XCTAssertEqual(persisted.steamUISurface, .library)
        XCTAssertEqual(persisted.stdoutPath, "/tmp/stdout.log")

        let failed = try context.createSteamLaunchRecord(
            appSessionID: "session-current",
            environmentGenerationID: "generation-current",
            startedAt: Date(timeIntervalSince1970: 20)
        )
        try context.markSteamLaunchFailedWithoutResult(
            failed,
            now: Date(timeIntervalSince1970: 21),
            failureDomain: "ForgePlayTests",
            failureCode: 7,
            failureSummary: "fixture failure"
        )
        XCTAssertEqual(failed.status, "failed")
        XCTAssertEqual(failed.steamUIVerificationState, .failed)
        XCTAssertEqual(failed.failureDomain, "ForgePlayTests")
        XCTAssertEqual(failed.failureCode, 7)

        XCTAssertEqual(
            SteamLaunchRecordLookup.latestSteamLaunchRecord(
                from: try context.fetch(FetchDescriptor<LaunchRecord>()),
                environmentGenerationID: "generation-current",
                currentAppSessionID: "session-current"
            )?.id,
            failed.id
        )
    }

    func testSteamReadinessUISplitsInstallStateFromRendererState() throws {
        let projectRoot = try projectRoot()
        let dashboardView = try String(
            contentsOf: projectRoot.appending(path: "Sources/ForgePlay/UI/DashboardView.swift"),
            encoding: .utf8
        )
        let steamLaunchView = try String(
            contentsOf: projectRoot.appending(path: "Sources/ForgePlay/UI/SteamLaunchView.swift"),
            encoding: .utf8
        )

        let steamDisplayStatusStart = try XCTUnwrap(
            dashboardView.range(of: "private var steamDisplayStatus: CheckStatus")
        )
        let steamDisplayStatusEnd = try XCTUnwrap(
            dashboardView[steamDisplayStatusStart.lowerBound...]
                .range(of: "private var executionEnvironmentDisplayValue")
        )
        let steamDisplayStatusBody = String(
            dashboardView[steamDisplayStatusStart.lowerBound..<steamDisplayStatusEnd.lowerBound]
        )

        XCTAssertTrue(dashboardView.contains(#"title: "Windows용 Steam""#))
        XCTAssertTrue(dashboardView.contains(#"title: "게임 렌더러 payload""#))
        XCTAssertTrue(steamDisplayStatusBody.contains("readiness.hasSteamExecutable ? .ok : .warning"))
        XCTAssertTrue(steamDisplayStatusBody.contains("if readiness.steamPrefixIssue != nil { return .error }"))
        XCTAssertFalse(steamDisplayStatusBody.contains("hasLaunchableWindowsSteam ? .ok : .warning"))

        let detailTextStart = try XCTUnwrap(
            steamLaunchView.range(of: "private var steamLaunchDetailText: String")
        )
        let detailTextEnd = try XCTUnwrap(
            steamLaunchView[detailTextStart.lowerBound...]
                .range(of: "private var latestSteamLaunchRecord")
        )
        let detailTextBody = String(
            steamLaunchView[detailTextStart.lowerBound..<detailTextEnd.lowerBound]
        )
        let blockerRange = try XCTUnwrap(
            detailTextBody.range(of: "if let blocker = cachedSteamLaunchBlocker")
        )
        let rendererRange = try XCTUnwrap(detailTextBody.range(of: "rendererInspection.status != .ok"))

        XCTAssertLessThan(
            detailTextBody.distance(from: detailTextBody.startIndex, to: blockerRange.lowerBound),
            detailTextBody.distance(from: detailTextBody.startIndex, to: rendererRange.lowerBound)
        )
    }

    func testSteamInstallUIUsesSteamPrefixServiceSurface() throws {
        let projectRoot = try projectRoot()
        let sheetHostView = try String(
            contentsOf: projectRoot.appending(path: "Sources/ForgePlay/UI/SheetHostView.swift"),
            encoding: .utf8
        )
        let steamLaunchView = try String(
            contentsOf: projectRoot.appending(path: "Sources/ForgePlay/UI/SteamLaunchView.swift"),
            encoding: .utf8
        )
        let appServices = try String(
            contentsOf: projectRoot.appending(path: "Sources/ForgePlay/App/AppServices.swift"),
            encoding: .utf8
        )
        let steamPrefixService = try String(
            contentsOf: projectRoot.appending(path: "Sources/ForgePlay/Services/SteamPrefixService.swift"),
            encoding: .utf8
        )
        let steamManager = try String(
            contentsOf: projectRoot.appending(path: "Sources/ForgePlay/Services/SteamManager.swift"),
            encoding: .utf8
        )

        for uiSource in [sheetHostView, steamLaunchView] {
            XCTAssertFalse(uiSource.contains("services.steamManager.installSteam"))
            XCTAssertFalse(uiSource.contains("services.steamManager.validateSteamInstaller"))
            XCTAssertTrue(uiSource.contains("services.installSteamInSteamPrefix"))
            XCTAssertTrue(uiSource.contains("services.validateSteamInstaller"))
            XCTAssertTrue(uiSource.contains("appState.effectiveSteamClientLanguage"))
            XCTAssertTrue(uiSource.contains("language: steamLanguage"))
        }
        XCTAssertTrue(appServices.contains("func installSteamInSteamPrefix"))
        XCTAssertTrue(appServices.contains("language: SteamClientLanguage"))
        XCTAssertTrue(appServices.contains("language: language"))
        XCTAssertTrue(appServices.contains("func validateSteamInstaller"))
        XCTAssertTrue(steamPrefixService.contains("func installSteam("))
        XCTAssertTrue(steamPrefixService.contains("language: SteamClientLanguage"))
        XCTAssertTrue(steamPrefixService.contains("try steamManager.requireSteamInstaller(installer)"))
        XCTAssertTrue(steamPrefixService.contains("validatedRunnerSnapshotForWindowsSteam(runtimeExecutable)"))
        XCTAssertTrue(steamPrefixService.contains("revalidatedRunnerSnapshotForWindowsSteam("))
        let languageClaim = try XCTUnwrap(
            steamManager.range(of: ".claimFreshInstallation(")
        )
        let installerDispatch = try XCTUnwrap(
            steamManager.range(of: "runner.run(.installSteam(")
        )
        XCTAssertLessThan(
            steamManager.distance(
                from: steamManager.startIndex,
                to: languageClaim.lowerBound
            ),
            steamManager.distance(
                from: steamManager.startIndex,
                to: installerDispatch.lowerBound
            ),
            "Fresh Steam language projection must complete before SteamSetup.exe dispatch."
        )
        XCTAssertTrue(
            steamManager.contains("lease: steamLanguageOwnershipLease")
        )
        XCTAssertGreaterThanOrEqual(
            steamManager.components(
                separatedBy: "steamClientLanguageOwnershipPolicy.reaffirm("
            ).count - 1,
            2,
            "First-launch preparation and normal Steam launch must retain language ownership after Wine-backed mutations."
        )
    }

    func testRendererRepairIsExplicitAndStopsPrefixBeforeMutation() throws {
        let projectRoot = try projectRoot()
        let steamManager = try String(
            contentsOf: projectRoot.appending(path: "Sources/ForgePlay/Services/SteamManager.swift"),
            encoding: .utf8
        )
        let steamPrefixService = try String(
            contentsOf: projectRoot.appending(path: "Sources/ForgePlay/Services/SteamPrefixService.swift"),
            encoding: .utf8
        )

        let launchStart = try XCTUnwrap(steamManager.range(of: "func launchSteam("))
        let launchEnd = try XCTUnwrap(steamManager[launchStart.upperBound...].range(of: "nonisolated static let steamCrashDumpExitCode"))
        let launchBody = String(steamManager[launchStart.lowerBound..<launchEnd.lowerBound])
        XCTAssertTrue(launchBody.contains("applySteamClientCompatibilityProfile"))
        XCTAssertFalse(launchBody.contains("restoreSteamRendererBridgeModules"))
        XCTAssertTrue(launchBody.contains("rendererPolicyVerificationFailed"))

        let shutdownRange = try XCTUnwrap(steamPrefixService.range(of: "shutdownSteamPrefixBeforePolicyMutation"))
        let profileRange = try XCTUnwrap(steamPrefixService.range(of: "applySteamClientCompatibilityProfile"))
        let bridgeRange = try XCTUnwrap(steamPrefixService.range(of: "restoreSteamRendererBridgeModules"))
        XCTAssertLessThan(
            steamPrefixService.distance(from: steamPrefixService.startIndex, to: shutdownRange.lowerBound),
            steamPrefixService.distance(from: steamPrefixService.startIndex, to: profileRange.lowerBound),
            "Explicit policy repair must stop the Steam Prefix before registry or renderer files are mutated."
        )
        XCTAssertLessThan(
            steamPrefixService.distance(from: steamPrefixService.startIndex, to: profileRange.lowerBound),
            steamPrefixService.distance(from: steamPrefixService.startIndex, to: bridgeRange.lowerBound),
            "Wine registry profile calls must run before renderer overlay cleanup. Wine can resync system32/syswow64 during reg.exe calls."
        )
    }

    func testSteamLaunchValidatesRuntimeBindingWithoutMigratingPrefix() throws {
        let source = try String(
            contentsOf: projectRoot().appending(path: "Sources/ForgePlay/Services/SteamPrefixService.swift"),
            encoding: .utf8
        )
        let launchStart = try XCTUnwrap(source.range(of: "func launchSteam("))
        let launchEnd = try XCTUnwrap(source[launchStart.upperBound...].range(of: "private func withExclusiveOperation"))
        let launchBody = String(source[launchStart.lowerBound..<launchEnd.lowerBound])

        XCTAssertTrue(launchBody.contains("requireSteamSharedPrefixRuntimeCompatibility"))
        XCTAssertTrue(launchBody.contains("let context = try prepareLaunch()"))
        XCTAssertTrue(launchBody.contains("var processResult = try await steamManager.launchSteam("))
        XCTAssertLessThan(
            try XCTUnwrap(launchBody.range(of: "let context = try prepareLaunch()")?.lowerBound),
            try XCTUnwrap(launchBody.range(of: "var processResult = try await steamManager.launchSteam(")?.lowerBound)
        )
        XCTAssertFalse(launchBody.contains("migrateSteamSharedPrefixRuntime"))
        XCTAssertFalse(launchBody.contains("prepareSteamSharedPrefix"))
    }

    func testSteamLaunchServiceRequiresExplicitNetworkAndAudioSelections() throws {
        let source = try String(
            contentsOf: projectRoot().appending(
                path: "Sources/ForgePlay/Services/SteamPrefixService.swift"
            ),
            encoding: .utf8
        )
        let launchStart = try XCTUnwrap(source.range(of: "func launchSteam("))
        let launchEnd = try XCTUnwrap(
            source[launchStart.upperBound...].range(of: "func launchSteam<LaunchContext>")
        )
        let signature = String(source[launchStart.lowerBound..<launchEnd.lowerBound])

        XCTAssertTrue(
            signature.contains(
                "networkSelection: SteamNetworkCompatibilitySelection,"
            )
        )
        XCTAssertTrue(
            signature.contains(
                "audioInputSelection: SteamAudioInputSelection,"
            )
        )
        XCTAssertFalse(
            signature.contains(
                "networkSelection: SteamNetworkCompatibilitySelection ="
            )
        )
        XCTAssertFalse(
            signature.contains(
                "audioInputSelection: SteamAudioInputSelection ="
            )
        )
    }

    func testSteamLaunchServiceDefaultsToSupportedKeyboardMapping() throws {
        let source = try String(
            contentsOf: projectRoot().appending(
                path: "Sources/ForgePlay/Services/SteamPrefixService.swift"
            ),
            encoding: .utf8
        )
        let firstLaunch = try XCTUnwrap(source.range(of: "func launchSteam("))
        let privateHelpers = try XCTUnwrap(
            source[firstLaunch.upperBound...].range(of: "private func withExclusiveOperation")
        )
        let launchSurface = String(
            source[firstLaunch.lowerBound..<privateHelpers.lowerBound]
        )

        XCTAssertEqual(
            launchSurface.components(
                separatedBy:
                    "keyboardMapping: KeyboardMappingPreference = .systemDefault"
            ).count - 1,
            2
        )
        XCTAssertFalse(
            launchSurface.contains(
                "keyboardMapping: KeyboardMappingPreference = .windowsFriendly"
            )
        )
    }

    func testSteamOnlyArchitectureDoesNotExposeDirectGameLauncherSurface() throws {
        let projectRoot = try projectRoot()
        let appServices = try String(
            contentsOf: projectRoot.appending(path: "Sources/ForgePlay/App/AppServices.swift"),
            encoding: .utf8
        )
        let steamManager = try String(
            contentsOf: projectRoot.appending(path: "Sources/ForgePlay/Services/SteamManager.swift"),
            encoding: .utf8
        )
        let project = try String(
            contentsOf: projectRoot.appending(path: "ForgePlay.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        let uiRoot = projectRoot.appending(path: "Sources/ForgePlay/UI")
        let uiSource = try FileManager.default
            .contentsOfDirectory(at: uiRoot, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        let resourceSource = try ForgePlayLanguageMode.allCases
            .compactMap(\.localizationDirectory)
            .map { directory in
                try String(
                    contentsOf: projectRoot.appending(path: "Resources/\(directory).lproj/Localizable.strings"),
                    encoding: .utf8
                )
            }
            .joined(separator: "\n")
        let serviceSource = try [
            "Sources/ForgePlay/Services/SteamManager.swift",
            "Sources/ForgePlay/Services/SteamServiceModels.swift",
            "Sources/ForgePlay/Services/SteamLibraryManifestSupport.swift",
            "Sources/ForgePlay/App/Localization.swift"
        ]
            .map { try String(contentsOf: projectRoot.appending(path: $0), encoding: .utf8) }
            .joined(separator: "\n")

        XCTAssertFalse(appServices.contains("gameExecutableCandidateScanner"))
        XCTAssertFalse(appServices.contains("createLegacyGamePrefix"))
        XCTAssertFalse(appServices.contains("prepareLegacyGamePrefix"))
        XCTAssertFalse(project.contains("GameLauncher.swift"))
        XCTAssertFalse(project.contains("GameLauncherTests.swift"))
        XCTAssertFalse(steamManager.lowercased().contains("applaunch"))
        XCTAssertFalse(steamManager.lowercased().contains("rungameid"))
        XCTAssertFalse(steamManager.lowercased().contains("steam://"))
        XCTAssertFalse(uiSource.contains(#""게임 화면""#))
        XCTAssertFalse(uiSource.contains("게임 다시 찾기"))
        XCTAssertFalse(uiSource.contains("게임 목록"))
        XCTAssertFalse(uiSource.contains("게임 폴더 복사"))
        XCTAssertFalse(uiSource.contains("게임 폴더를 ForgePlay로 복사"))
        XCTAssertFalse(uiSource.contains("chooseAndCopyGameFolder"))
        XCTAssertFalse(uiSource.contains("importExistingGameFolderInBackground"))
        XCTAssertFalse(uiSource.contains("prepareSteamSharedPrefix"))
        XCTAssertFalse(uiSource.contains("GPTK 실행 엔진"))
        XCTAssertFalse(uiSource.contains("먼저 GPTK 파일을 선택하세요."))
        XCTAssertFalse(uiSource.contains("Game Porting Toolkit 또는 Wine 실행 엔진이 선택되어 있습니다."))
        XCTAssertFalse(uiSource.contains("Steam과 Windows 게임을 실행할 수 있습니다."))
        XCTAssertFalse(uiSource.contains("Game Runner"))
        XCTAssertFalse(uiSource.contains("game execution engine"))
        XCTAssertFalse(uiSource.contains("Steam Steam 프리픽스"))
        XCTAssertFalse(uiSource.contains("Steam 공용 Steam 프리픽스"))
        XCTAssertFalse(uiSource.contains("Steam 공용 프리픽스"))
        XCTAssertFalse(uiSource.contains("공용 Steam 프리픽스"))
        XCTAssertFalse(uiSource.contains("shared Steam Prefix"))
        XCTAssertFalse(uiSource.contains("shared Steam prefix"))
        XCTAssertFalse(uiSource.contains("게임 렌더러 payload를 Steam 프로세스에 직접 주입"))
        XCTAssertFalse(uiSource.contains("Steam 클라이언트와 Steam에서 실행한 게임"))
        XCTAssertFalse(uiSource.contains("Windows용 Steam 표시와 Steam 안에서 실행할 게임"))
        XCTAssertFalse(uiSource.contains("Windows용 Steam 자체와 Steam 안에서 실행할 게임 모두"))
        XCTAssertFalse(uiSource.contains("Windows용 Steam은 Steam 클라이언트 표시와 Steam 안에서 실행할 게임"))

        for obsoleteImportSurface in [
            "SteamImportResult",
            "SteamImportError",
            "SteamGameImportOperation",
            "importExistingGameFolder",
            "discardImportedGameArtifacts",
            "게임 가져오기",
            "가져올 게임 폴더",
            "게임 폴더를 선택해야 합니다",
            "게임을 선택하세요",
            "보통 steamapps/common 안의 게임 이름 폴더를 선택합니다. 큰 게임은 복사에 시간이 걸릴 수 있습니다.",
            "게임 폴더 선택",
            "%@을 가져왔습니다. 복사한 크기: %@",
            "설치 폴더: %@",
            "아직 후보를 찾지 못했습니다. Steam에서 게임 설치가 끝났는지 확인한 뒤 다시 찾기를 누르세요.",
            "%@을 실행하는 중입니다.",
            "게임별 독립 실행 환경",
            "게임 파일, 실행 환경, 문제 분석 기록을 저장할 위치를 고릅니다.",
            "ForgePlay가 이 Mac에서 게임을 실행할 준비가 되었는지 확인합니다."
        ] {
            XCTAssertFalse(serviceSource.contains(obsoleteImportSurface), "Legacy game-folder copy import surface in services: \(obsoleteImportSurface)")
            XCTAssertFalse(resourceSource.contains(obsoleteImportSurface), "Legacy game-folder copy import surface in resources: \(obsoleteImportSurface)")
        }

        for legacySurface in [
            "설치된 게임",
            "Installed Games",
            "게임 찾기",
            "Find Games",
            "%d개 게임을 찾았습니다.",
            "Found %d games.",
            "Steam 실행 엔진",
            "Steam runner",
            "게임 목록 관리",
            "Managing the Game List",
            "게임 상세 보기",
            "게임 상세",
            "게임 상세 화면",
            "게임 상세 보기는",
            "목록의 게임을 누르면",
            "게임 상세 화면에서 그래픽 변환",
            "게임 상세 화면의 그래픽 변환",
            "Steam 실행 준비 완료",
            "Steam 실행 준비 필요",
            "Steam 실행 가능, 게임 그래픽 렌더러 미포함",
            "Steam 실행 준비가 완료되었습니다.",
            "1. 게임 저장 위치 선택",
            "게임 저장 위치 선택",
            "게임 저장 위치",
            "먼저 게임 저장 위치를 선택하세요.",
            "게임 저장 위치를 먼저 선택하세요.",
            "게임 저장 위치를 먼저 선택해야 합니다.",
            "게임 저장 위치를 확인하세요.",
            "게임 실행 기록 최대 %d개 보존",
            "ForgePlay가 게임 실행 환경, Steam 라이브러리, 로그를 정리할 폴더를 선택합니다."
        ] {
            XCTAssertFalse(uiSource.contains(legacySurface), "Legacy direct-game UI phrase in source: \(legacySurface)")
            XCTAssertFalse(resourceSource.contains(legacySurface), "Legacy direct-game UI phrase in resources: \(legacySurface)")
        }
    }

    func testRuntimeAndCompatibilityResourcesUseSteamPrefixTerminology() throws {
        let projectRoot = try projectRoot()
        let scannedRoots = [
            projectRoot.appending(path: "Sources/ForgePlay/App"),
            projectRoot.appending(path: "Sources/ForgePlay/Models"),
            projectRoot.appending(path: "Sources/ForgePlay/Services"),
            projectRoot.appending(path: "Sources/ForgePlay/UI"),
            projectRoot.appending(path: "Resources/CompatibilityDB/recipes")
        ]
        let localizations = ForgePlayLanguageMode.allCases
            .compactMap(\.localizationDirectory)
            .map { projectRoot.appending(path: "Resources/\($0).lproj/Localizable.strings") }

        var scannedText = ""
        for root in scannedRoots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for case let url as URL in enumerator where ["swift", "json"].contains(url.pathExtension) {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else { continue }
                scannedText += try String(contentsOf: url, encoding: .utf8)
                scannedText += "\n"
            }
        }
        for url in localizations {
            scannedText += try String(contentsOf: url, encoding: .utf8)
            scannedText += "\n"
        }

        for legacyTerm in [
            "게임 실행 엔진(GPTK)",
            "Direct3D 게임 화면",
            "현재 선택한 실행 엔진",
            "selected runner",
            "current runner",
            "Game Runner",
            "Steam runner"
        ] {
            XCTAssertFalse(
                scannedText.localizedCaseInsensitiveContains(legacyTerm),
                "Legacy runtime/direct-game terminology returned: \(legacyTerm)"
            )
        }
    }

    func testSteamClientSafeLaunchCopyDoesNotPromiseImplicitRendererOverlayRepair() throws {
        let projectRoot = try projectRoot()
        let scannedRoots = [
            projectRoot.appending(path: "Sources/ForgePlay/UI"),
            projectRoot.appending(path: "Sources/ForgePlay/Services")
        ]
        let localizations = ForgePlayLanguageMode.allCases
            .compactMap(\.localizationDirectory)
            .map { projectRoot.appending(path: "Resources/\($0).lproj/Localizable.strings") }

        var scannedText = ""
        for root in scannedRoots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else { continue }
                scannedText += try String(contentsOf: url, encoding: .utf8)
                scannedText += "\n"
            }
        }
        for url in localizations {
            scannedText += try String(contentsOf: url, encoding: .utf8)
            scannedText += "\n"
        }

        for stalePromise in [
            "남은 overlay를 복구한 뒤 실행",
            "실행 전에 복구합니다",
            "실행 전에 자동 복구",
            "repaired before launch",
            "automatically repairs before launch",
            "after leftover overlays are repaired",
            "Steam UI launches on the default WineD3D path"
        ] {
            XCTAssertFalse(
                scannedText.localizedCaseInsensitiveContains(stalePromise),
                "Steam client launch copy must not promise implicit renderer overlay repair: \(stalePromise)"
            )
        }
    }

    func testUserFacingKoreanStringLiteralsHaveLocalizationEntries() throws {
        let english = try strings(for: "en")
        let projectRoot = try projectRoot()
        let sourceRoots = [
            projectRoot.appending(path: "Sources/ForgePlay/App"),
            projectRoot.appending(path: "Sources/ForgePlay/UI")
        ]
        let regex = try NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*[가-힣](?:[^"\\]|\\.)*)""#)
        var missing: [String] = []
        var interpolated: [String] = []

        for sourceRoot in sourceRoots {
            guard let enumerator = FileManager.default.enumerator(
                at: sourceRoot,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                XCTFail("Could not enumerate source root \(sourceRoot.path)")
                continue
            }

            for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
                let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else { continue }
                let source = try String(contentsOf: fileURL, encoding: .utf8)
                let sourceNSString = source as NSString
                let range = NSRange(source.startIndex..<source.endIndex, in: source)

                for match in regex.matches(in: source, range: range) {
                    let rawLiteral = sourceNSString.substring(with: match.range(at: 1))
                    let line = sourceNSString.substring(to: match.range.location).components(separatedBy: .newlines).count
                    let relativePath = fileURL.path.replacingOccurrences(of: projectRoot.path + "/", with: "")
                    let location = relativePath + ":\(line)"
                    if rawLiteral.contains("\\(") {
                        interpolated.append("\(location): \(rawLiteral)")
                        continue
                    }

                    let key = decodedSwiftStringLiteral(rawLiteral)
                    if english[key] == nil {
                        missing.append("\(location): \(rawLiteral)")
                    }
                }
            }
        }

        XCTAssertTrue(
            interpolated.isEmpty,
            "Interpolated Korean UI literals must use localizedFormat keys: \(interpolated.sorted())"
        )
        XCTAssertTrue(
            missing.isEmpty,
            "Korean UI literals in App/UI sources must exist as localization keys: \(missing.sorted())"
        )
    }

    func testSignedCompatibilityGuidanceExplainsReadOnlyUserConfirmedContract() throws {
        let root = try projectRoot()
        let settings = try String(
            contentsOf: root.appending(path: "Sources/ForgePlay/UI/SettingsView.swift"),
            encoding: .utf8
        )
        let catalog = try String(
            contentsOf: root.appending(path: "Sources/ForgePlay/UI/CompatibilityCatalogView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(settings.contains(#"ForgeCard("호환성 정보 업데이트""#))
        XCTAssertTrue(settings.contains(#"localized("호환성 DB 주소")"#))
        XCTAssertTrue(settings.contains("실행 설정을 자동 변경하지 않으며"))
        XCTAssertTrue(settings.contains("사용자가 확인할 권장 조치로만 제시합니다"))
        XCTAssertFalse(settings.contains(#"ForgeCard("실행 규칙 업데이트""#))
        XCTAssertTrue(catalog.contains("공개 호환성 목록"))
    }

    func testSteamFailureGuidanceConsumesSelectedGameAndSignedRecipe() throws {
        let root = try projectRoot()
        let source = try String(
            contentsOf: root.appending(path: "Sources/ForgePlay/UI/SteamLaunchView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("diagnosticGuidanceRecipe("))
        XCTAssertTrue(source.contains("game: game,"))
        XCTAssertTrue(source.contains("recipe: compatibilityGuidance.recipe,"))
        XCTAssertTrue(source.contains("game: selectedGame"))
    }

    func testPublicCatalogUnsafeLockFallbackCopyHasEightLocaleParity() {
        let key = "저장된 공개 호환성 목록 잠금을 안전하게 사용할 수 없어 앱 포함 목록을 사용합니다."

        for language in ForgePlayLanguageMode.allCases where language != .system {
            let localized = ForgePlayLocalization.localized(key, language: language)
            XCTAssertFalse(localized.isEmpty, "Empty catalog-lock warning for \(language)")
            XCTAssertEqual(placeholders(in: key), placeholders(in: localized))
            if language != .korean {
                XCTAssertNotEqual(localized, key, "Untranslated catalog-lock warning for \(language)")
                XCTAssertNil(
                    localized.range(of: "[가-힣]", options: .regularExpression),
                    "Korean catalog-lock fallback remains for \(language): \(localized)"
                )
            }
        }
    }

    @MainActor
    func testSignedExecutionRuleErrorsNeverUsePublicCompatibilityTerminology() {
        let ruleURL = URL(fileURLWithPath: "/tmp/ExecutionRules/steam-42.json")
        let keyURL = URL(fileURLWithPath: "/tmp/ExecutionRules/public-key.pem")
        let nestedError = NavigationStableSessionOwnershipError.standardSteamLaunchReserved
        let errors: [Error] = [
            CompatibilityServiceError.decodeFailed(ruleURL),
            CompatibilityServiceError.unsafeRecipeFile(ruleURL),
            CompatibilityServiceError.recipeTooLarge(ruleURL, 4097, 4096),
            CompatibilityServiceError.invalidRecipe(ruleURL),
            CompatibilityServiceError.recipeDiscoveryFailed(ruleURL, nestedError),
            CompatibilityServiceError.recipeMetadataReadFailed(ruleURL, nestedError),
            CompatibilityServiceError.storedRecipeInvalidUTF8("steam-42"),
            CompatibilityServiceError.storedRecipeTooLarge("steam-42", 4097, 4096),
            CompatibilityServiceError.storedRecipeDecodeFailed("steam-42"),
            CompatibilityServiceError.storedRecipeInvalid("steam-42"),
            CompatibilityServiceError.storedRecipeRecordMismatch("steam-42"),
            CompatibilityServiceError.ambiguousSteamAppID("42"),
            CompatibilityRecipeRecordProjectionError.encodeFailed("steam-42"),
            CompatibilityRecipeRecordProjectionError.utf8ConversionFailed("steam-42"),
            CompatibilityDBUpdateError.missingFeedURL,
            CompatibilityDBUpdateError.insecureFeedURL,
            CompatibilityDBUpdateError.invalidFeedURL,
            CompatibilityDBUpdateError.insecureRecipeURL("steam-42"),
            CompatibilityDBUpdateError.invalidRecipeDescriptor("steam-42"),
            CompatibilityDBUpdateError.duplicateRecipeDescriptor("steam-42"),
            CompatibilityDBUpdateError.tooManyRecipes(65, 64),
            CompatibilityDBUpdateError.insecureResolvedURL("index.json"),
            CompatibilityDBUpdateError.invalidHTTPStatus("index.json", 403),
            CompatibilityDBUpdateError.responseTooLarge("index.json", 4097, 4096),
            CompatibilityDBUpdateError.signatureVerifierMissing,
            CompatibilityDBUpdateError.invalidPublicKey,
            CompatibilityDBUpdateError.unsupportedSchemaVersion(99),
            CompatibilityDBUpdateError.invalidIndexSignature,
            CompatibilityDBUpdateError.invalidRecipeSignature("steam-42"),
            CompatibilityDBUpdateError.checksumMismatch("steam-42"),
            CompatibilityDBUpdateError.recipeIdMismatch(
                expected: "steam-42",
                actual: "steam-43"
            ),
            CompatibilityDBUpdateError.invalidRecipe("steam-42"),
            CompatibilityDBUpdateError.duplicateStoredRecipeRecord("steam-42"),
            CompatibilityDBUpdateError.duplicateSteamAppID("42"),
            CompatibilityDBUpdateError.updateInProgress,
            CompatibilityDBPublicKeyResourceError.unsafeResource(keyURL),
            CompatibilityDBPublicKeyResourceError.metadataReadFailed(
                keyURL,
                "permission denied"
            ),
            CompatibilityDBPublicKeyResourceError.readFailed(
                keyURL,
                "permission denied"
            ),
            CompatibilityDBPublicKeyResourceError.oversized(keyURL, 4097, 4096),
            CompatibilityDBPublicKeyResourceError.textDecodeFailed(keyURL)
        ]
        let appState = AppState()

        for language in ForgePlayLanguageMode.allCases where language != .system {
            let terminology: (executionRule: String, publicCompatibility: String)
            switch language {
            case .system:
                continue
            case .korean:
                terminology = ("실행 규칙", "호환성")
            case .english:
                terminology = ("execution rule", "compatibility")
            case .spanish:
                terminology = ("ejecución", "compatibilidad")
            case .german:
                terminology = ("Ausführungsregel", "Kompatibilität")
            case .french:
                terminology = ("exécution", "compatibilité")
            case .japanese:
                terminology = ("実行ルール", "互換性")
            case .simplifiedChinese:
                terminology = ("执行规则", "兼容性")
            case .traditionalChinese:
                terminology = ("執行規則", "相容性")
            }

            appState.languageMode = language
            for error in errors {
                let message = appState.localizedError(error)
                XCTAssertFalse(
                    message.isEmpty,
                    "Empty signed-rule error for \(type(of: error)) in \(language)"
                )
                XCTAssertTrue(
                    message.localizedCaseInsensitiveContains(terminology.executionRule),
                    "Signed-rule terminology missing for \(type(of: error)) in \(language): \(message)"
                )
                XCTAssertFalse(
                    message.localizedCaseInsensitiveContains(terminology.publicCompatibility),
                    "Public-catalog terminology leaked for \(type(of: error)) in \(language): \(message)"
                )
            }
        }
    }

    @MainActor
    func testUserFacingLocalizedErrorsDoNotFallBackToKoreanOutsideKorean() {
        let errors: [Error] = [
            PathManagerError.rootNotConfigured,
            PathManagerError.missing(URL(fileURLWithPath: "/Volumes/MissingForgePlayRoot")),
            PathManagerError.notWritable(URL(fileURLWithPath: "/tmp/ForgePlayNoWrite")),
            PathManagerError.validationFailed(
                URL(fileURLWithPath: "/tmp/ForgePlayRoot"),
                "permission denied"
            ),
            PathManagerError.validationFailed(nil, "permission denied"),
            NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileWriteVolumeReadOnlyError,
                userInfo: [NSFilePathErrorKey: "/Sample Games/ForgePlay Library"]
            ),
            StorageMigrationError.nestedLocation,
            StorageMigrationError.destinationIsVolumeRoot(URL(fileURLWithPath: "/Volumes/External")),
            StorageMigrationError.unsafeHardlink(URL(fileURLWithPath: "/tmp/ForgePlayRoot/hardlinked.log")),
            StorageMigrationError.scanFailed(URL(fileURLWithPath: "/tmp/ForgePlayRoot"), "permission denied"),
            StorageMigrationError.metadataReadFailed(URL(fileURLWithPath: "/tmp/ForgePlayRoot/prefix.json"), "permission denied"),
            StorageMigrationError.recordProjectionFailed("snapshots"),
            StorageMigrationError.cleanupFailed(
                destination: URL(fileURLWithPath: "/tmp/ForgePlayDestination"),
                originalError: CocoaError(.fileWriteUnknown),
                cleanupError: CocoaError(.fileNoSuchFile)
            ),
            ManagedRootOperationLeaseError.operationInProgress(
                URL(fileURLWithPath: "/tmp/OperationLocks/managed-root.lock")
            ),
            ManagedRootOperationLeaseError.unsafeLockFile(
                URL(fileURLWithPath: "/tmp/OperationLocks/unsafe.lock")
            ),
            ManagedRootOperationLeaseError.lockFailed(
                URL(fileURLWithPath: "/tmp/OperationLocks/failed.lock"),
                "permission denied"
            ),
            WindowsFontCompatibilityProfileError.bundledPayloadMissing,
            WindowsFontCompatibilityProfileError.unsafeDestination(
                URL(fileURLWithPath: "/tmp/Prefixes/SteamShared/drive_c/windows/Fonts")
            ),
            WindowsFontCompatibilityProfileError.verificationFailed([
                "HKLM\\Software\\Microsoft\\Windows NT\\CurrentVersion\\FontSubstitutes\\MS Shell Dlg 2=Tahoma"
            ]),
            SteamInstallError.invalidInstaller(URL(fileURLWithPath: "/tmp/SteamSetup.dmg")),
            SteamInstallError.installerMetadataReadFailed(URL(fileURLWithPath: "/tmp/SteamSetup.exe"), "permission denied"),
            SteamLibraryScanError.metadataReadFailed(URL(fileURLWithPath: "/tmp/steamapps/appmanifest_42.acf"), "permission denied"),
            PrefixMetadataError.metadataReadFailed(URL(fileURLWithPath: "/tmp/Prefixes/SteamShared/prefix.json"), "permission denied"),
            PrefixUsabilityError.missingRequiredItem(URL(fileURLWithPath: "/tmp/Prefixes/SteamShared/drive_c")),
            PrefixUsabilityError.unsafeRequiredItem(URL(fileURLWithPath: "/tmp/Prefixes/SteamShared/system.reg")),
            PrefixUsabilityError.unreadableRequiredItem(URL(fileURLWithPath: "/tmp/Prefixes/SteamShared/user.reg"), "permission denied"),
            PrefixUsabilityError.invalidMetadata(URL(fileURLWithPath: "/tmp/Prefixes/SteamShared/prefix.json"), "decode failed"),
            PrefixUsabilityError.architectureMismatch(URL(fileURLWithPath: "/tmp/Prefixes/SteamShared"), expected: "win64", actual: nil),
            PrefixRestoreError.rollbackFailed(
                destination: URL(fileURLWithPath: "/tmp/Prefixes/SteamShared"),
                backup: URL(fileURLWithPath: "/tmp/Prefixes/.SteamShared.restore-backup"),
                originalError: CocoaError(.fileWriteUnknown),
                rollbackError: CocoaError(.fileWriteNoPermission)
            ),
            PrefixResetError.rollbackFailed(
                destination: URL(fileURLWithPath: "/tmp/Prefixes/SteamShared"),
                displacedEnvironment: URL(fileURLWithPath: "/tmp/Prefixes/.SteamShared.reset-staging"),
                originalError: CocoaError(.fileWriteUnknown),
                rollbackError: CocoaError(.fileWriteNoPermission)
            ),
            PrefixResetError.steamLibraryPreservationFailed(
                URL(fileURLWithPath: "/tmp/Prefixes/SteamShared/drive_c/Program Files (x86)/Steam/steamapps"),
                "identity changed"
            ),
            WindowsRuntimeServiceError.invalidSelection("runner missing"),
            WindowsRuntimeServiceError.probeFailed(sampleProcessRunResult()),
            WindowsRuntimeServiceError.missingSteamRendererCapability(WindowsRuntimeCapability(
                executableURL: URL(fileURLWithPath: "/Applications/ForgePlay.app/Contents/Resources/Runners/ForgePlayRuntime/wine/bin/wine"),
                graphicsBackend: .unsupportedByMetadata,
                evidence: [],
                limitations: ["built-without-vulkan-or-d3dmetal"]
            )),
            WindowsRuntimeServiceError.sourceScanFailed(
                URL(fileURLWithPath: "/tmp/Evaluation"),
                CocoaError(.fileReadNoPermission)
            ),
            WindowsRuntimeServiceError.supplementalRedistScanFailed(
                URL(fileURLWithPath: "/tmp/Evaluation/redist"),
                CocoaError(.fileReadNoPermission)
            ),
            WindowsRuntimeServiceError.unsafeSupplementalRedistSymlink(URL(fileURLWithPath: "/tmp/Evaluation/redist/lib/external-link")),
            WindowsRuntimeServiceError.unsafeSupplementalRedistHardlink(URL(fileURLWithPath: "/tmp/Evaluation/redist/lib/hardlinked.dylib")),
            WindowsRuntimeServiceError.payloadReplacementRollbackFailed(
                destination: URL(fileURLWithPath: "/tmp/Renderers/AppleD3DMetal"),
                backup: URL(fileURLWithPath: "/tmp/Renderers/.AppleD3DMetal.backup"),
                originalError: CocoaError(.fileWriteUnknown),
                rollbackError: CocoaError(.fileWriteNoPermission)
            ),
            LogTextReaderError.scanFailed(URL(fileURLWithPath: "/tmp/Logs"), "permission denied"),
            LogTextReaderError.textDecodeFailed(URL(fileURLWithPath: "/tmp/Logs/invalid.log")),
            DiagnosticRecordPersistenceError.utf8ConversionFailed,
            SupportBundleServiceError.rootMissing,
            SupportBundleServiceError.archiveCleanupFailed(
                destination: URL(fileURLWithPath: "/tmp/Support/ForgePlaySupport.zip"),
                processResult: sampleProcessRunResult(),
                cleanupError: CocoaError(.fileWriteNoPermission)
            ),
            SupportBundleServiceError.archiveValidationFailed(
                URL(fileURLWithPath: "/tmp/Support/ForgePlaySupport-invalid.zip"),
                "invalid ZIP signature"
            ),
            ProcessRunEvidenceWriterError.unsafeEvidencePath(
                URL(fileURLWithPath: "/tmp/Logs/unsafe.run.json")
            ),
            ProcessRunEvidenceWriterError.evidenceTooLarge(
                URL(fileURLWithPath: "/tmp/Logs/oversized.run.json"),
                524_289
            ),
            ProcessRunEvidenceWriterError.evidenceChangedDuringRead(
                URL(fileURLWithPath: "/tmp/Logs/changed.run.json")
            ),
            ProcessRunEvidenceWriterError.invalidEvidenceIdentity(
                URL(fileURLWithPath: "/tmp/Logs/mismatched.run.json")
            ),
            FailureDiagnosticEvidenceServiceError.unsafeDiagnosticDirectory(
                URL(fileURLWithPath: "/tmp/Logs/FailureEvidence")
            ),
            FailureDiagnosticEvidenceServiceError.allDiagnosticStorageUnavailable(
                primary: "permission denied",
                emergency: "disk full"
            ),
            LogRetentionServiceError.metadataReadFailed(URL(fileURLWithPath: "/tmp/log.txt"), CocoaError(.fileReadUnknown)),
            LLMServiceError.badResponse,
            AutoFixServiceError.unsupportedAction,
            CompatibilityServiceError.storedRecipeDecodeFailed("steam-1"),
            CompatibilityServiceError.storedRecipeRecordMismatch("steam-2"),
            CompatibilityServiceError.ambiguousSteamAppID("2"),
            CompatibilityDBUpdateError.invalidHTTPStatus("index.json", 403),
            CompatibilityDBUpdateError.duplicateStoredRecipeRecord("steam-1"),
            CompatibilityDBUpdateError.duplicateSteamAppID("1"),
            CompatibilityDBUpdateError.updateInProgress,
            SafeProcessRunnerError.unsafeExecutable(URL(fileURLWithPath: "/tmp/wine")),
            SafeProcessRunnerError.unsafeActionInput(URL(fileURLWithPath: "/tmp/Prefix")),
            SafeProcessRunnerError.metadataReadFailed(URL(fileURLWithPath: "/tmp/Prefix"), "permission denied"),
            SafeProcessRunnerError.sandboxIPCConfigurationMissing,
            RuntimeManagerError.unsafeCachedInstaller(URL(fileURLWithPath: "/tmp/RuntimeCache/Installers/xnafx40_redist.msi")),
            RuntimeManagerError.metadataReadFailed(URL(fileURLWithPath: "/tmp/RuntimeCache/Installers/xnafx40_redist.msi"), "permission denied"),
            RuntimeManagerError.extractionCleanupFailed(
                directory: URL(fileURLWithPath: "/tmp/RuntimeCache/ExtractedInstallers/DirectX"),
                originalError: RuntimeManagerError.extractedInstallerMissing(URL(fileURLWithPath: "/tmp/RuntimeCache/ExtractedInstallers/DirectX")),
                cleanupError: CocoaError(.fileWriteNoPermission)
            ),
            RuntimeManagerError.extractionCleanupAfterUseFailed(
                directory: URL(fileURLWithPath: "/tmp/RuntimeCache/ExtractedInstallers/DirectX"),
                cleanupError: CocoaError(.fileWriteNoPermission)
            ),
            RuntimeManagerError.cacheCleanupFailed(
                target: URL(fileURLWithPath: "/tmp/RuntimeCache/Installers/.xnafx40_redist.msi.tmp"),
                originalError: CocoaError(.fileWriteUnknown),
                cleanupError: CocoaError(.fileWriteNoPermission)
            ),
            WindowsExecutableExternalRootAccessError.accessUnavailable(
                URL(fileURLWithPath: "/Volumes/External/Classic Game")
            ),
            WindowsExecutableLaunchServiceError.unusableSharedPrefix(
                URL(fileURLWithPath: "/tmp/Prefixes/SteamShared")
            ),
            WindowsExecutableLaunchServiceError.rendererCapabilityUnavailable,
            WindowsExecutableLaunchServiceError.prefixShutdownNotConfirmed(
                URL(fileURLWithPath: "/tmp/Prefixes/SteamShared")
            ),
            RuntimeInstallerError.unusablePrefix("SteamShared")
        ]

        let appState = AppState()
        for language in ForgePlayLanguageMode.allCases where language != .system && language != .korean {
            appState.languageMode = language
            for error in errors {
                let message = appState.localizedError(error)
                XCTAssertNil(
                    message.range(of: "[가-힣]", options: .regularExpression),
                    "Korean fallback remains for \(type(of: error)) in \(language.rawValue): \(message)"
                )
            }
        }
    }

    @MainActor
    func testSteamProfileAndRosettaErrorsNeverExposeRawDomainCodes() {
        let cases: [(error: Error, technicalMarker: String)] = [
            (
                SteamCompatibilityLaunchProfileErrorV1.unsupportedContractVersion(91),
                "case=unsupportedContractVersion"
            ),
            (
                SteamCompatibilityLaunchProfileErrorV1.unsupportedRecipeSchemaVersion(92),
                "case=unsupportedRecipeSchemaVersion"
            ),
            (
                SteamCompatibilityLaunchProfileErrorV1.invalidRecipe("recipe-invalid"),
                "case=invalidRecipe"
            ),
            (
                SteamCompatibilityLaunchProfileErrorV1.identityMismatch(
                    expected: "expected-profile",
                    actual: "actual-profile"
                ),
                "case=identityMismatch"
            ),
            (
                SteamCompatibilityLaunchProfileErrorV1.invalidPreference("preference-invalid"),
                "case=invalidPreference"
            ),
            (
                SteamCompatibilityLaunchProfileErrorV1.invalidCanonicalPayload("payload-invalid"),
                "case=invalidCanonicalPayload"
            ),
            (
                SteamCompatibilityLaunchProfileErrorV1.invalidManifestRootAuthorization(
                    "authorization-invalid"
                ),
                "case=invalidManifestRootAuthorization"
            ),
            (
                SteamCompatibilityLaunchProfileErrorV1.attemptedAutomaticPolicyRemoval,
                "case=attemptedAutomaticPolicyRemoval"
            ),
            (
                SteamCompatibilityLaunchProfileErrorV1.unsupportedCapability(
                    category: "network-policy",
                    value: "offline"
                ),
                "case=unsupportedCapability"
            ),
            (
                SteamCompatibilityLaunchProfileErrorV1.invalidReceipt("receipt-invalid"),
                "case=invalidReceipt"
            ),
            (
                SteamCompatibilityLaunchProfileErrorV1.migrationRejected("migration-invalid"),
                "case=migrationRejected"
            ),
            (
                SafeProcessRunnerError.invalidRosettaAVXHostOverride("unexpected-value"),
                "case=invalidRosettaAVXHostOverride"
            )
        ]
        let appState = AppState()

        for language in ForgePlayLanguageMode.allCases where language != .system {
            appState.languageMode = language
            for testCase in cases {
                let bridgedError = testCase.error as NSError
                let userMessage = appState.localizedError(testCase.error)
                XCTAssertFalse(userMessage.contains(bridgedError.domain), userMessage)
                XCTAssertFalse(
                    userMessage.contains("\(bridgedError.domain) \(bridgedError.code)"),
                    userMessage
                )
                if language != .korean {
                    XCTAssertNil(
                        userMessage.range(of: "[가-힣]", options: .regularExpression),
                        "Korean fallback remains in \(language.rawValue): \(userMessage)"
                    )
                }
            }
        }

        for testCase in cases {
            let bridgedError = testCase.error as NSError
            let technicalMessage = forgePlayTechnicalErrorSummary(testCase.error)
            XCTAssertTrue(
                technicalMessage.contains(testCase.technicalMarker),
                technicalMessage
            )
            XCTAssertFalse(technicalMessage.contains(bridgedError.domain), technicalMessage)
            XCTAssertFalse(
                technicalMessage.contains("\(bridgedError.domain) \(bridgedError.code)"),
                technicalMessage
            )
        }
    }

    @MainActor
    func testWindowsExecutableLaunchErrorsPreserveLocalizedAndTechnicalPaths() {
        let cases: [(error: Error, path: String)] = [
            (
                WindowsExecutableExternalRootAccessError.accessUnavailable(
                    URL(fileURLWithPath: "/Volumes/External/Classic Game")
                ),
                "/Volumes/External/Classic Game"
            ),
            (
                WindowsExecutableLaunchServiceError.unusableSharedPrefix(
                    URL(fileURLWithPath: "/tmp/Prefixes/SteamShared")
                ),
                "/tmp/Prefixes/SteamShared"
            ),
            (
                WindowsExecutableLaunchServiceError.prefixShutdownNotConfirmed(
                    URL(fileURLWithPath: "/tmp/Prefixes/SteamShared")
                ),
                "/tmp/Prefixes/SteamShared"
            )
        ]
        let appState = AppState()
        appState.languageMode = .english

        for testCase in cases {
            let userMessage = appState.localizedError(testCase.error)
            XCTAssertTrue(userMessage.contains(testCase.path), userMessage)
            XCTAssertNil(userMessage.range(of: "[가-힣]", options: .regularExpression), userMessage)

            let technicalMessage = forgePlayTechnicalErrorSummary(testCase.error)
            XCTAssertTrue(technicalMessage.contains(testCase.path), technicalMessage)
            XCTAssertNil(
                technicalMessage.range(of: "[가-힣]", options: .regularExpression),
                technicalMessage
            )
        }

        let rendererError = WindowsExecutableLaunchServiceError
            .rendererCapabilityUnavailable
        let rendererNSError = rendererError as NSError
        let rendererKey = "선택한 그래픽 백엔드를 현재 ForgePlay Runtime에서 사용할 수 없습니다."
        for language in ForgePlayLanguageMode.allCases where language != .system {
            appState.languageMode = language
            let message = appState.localizedError(rendererError)
            XCTAssertFalse(message.isEmpty, "Empty renderer error for \(language)")
            XCTAssertEqual(
                message,
                ForgePlayLocalization.localized(rendererKey, language: language),
                "Wrong renderer error for \(language)"
            )
            XCTAssertFalse(message.contains(rendererNSError.domain), message)
            XCTAssertFalse(message.contains("Error Domain"), message)
        }
        XCTAssertEqual(
            forgePlayTechnicalErrorSummary(rendererError),
            "Windows executable launch renderer capability unavailable"
        )
    }

    @MainActor
    func testSteamSessionOwnershipErrorsUseLocalizedMessagesAndStableTechnicalCases() {
        let cases: [(
            error: NavigationStableSessionOwnershipError,
            userKey: String,
            technicalDescription: String
        )] = [
            (
                .transitionInProgress,
                "호환성 Steam 세션 작업이 이미 진행 중입니다.",
                "steam-session-ownership case=transition-in-progress"
            ),
            (
                .sessionAlreadyActive,
                "기존 호환성 Steam 세션을 먼저 종료하고 기준 상태 복원을 확인하세요.",
                "steam-session-ownership case=session-already-active"
            ),
            (
                .noActiveSession,
                "종료할 활성 호환성 Steam 세션이 없습니다.",
                "steam-session-ownership case=no-active-session"
            ),
            (
                .preparationNotInProgress,
                "호환성 Steam 세션 준비 상태가 올바르지 않습니다.",
                "steam-session-ownership case=preparation-not-in-progress"
            ),
            (
                .standardSteamLaunchReserved,
                "일반 Steam 실행 전환이 진행 중입니다.",
                "steam-session-ownership case=standard-steam-launch-reserved"
            ),
            (
                .standardSteamLaunchReservationMismatch,
                "일반 Steam 실행 전환 중 호환성 세션 상태가 변경되었습니다.",
                "steam-session-ownership case=standard-steam-launch-reservation-mismatch"
            ),
            (
                .standardSteamLaunchNotReady,
                "호환성 세션 복원 또는 다른 프리픽스 작업이 끝나지 않았습니다.",
                "steam-session-ownership case=standard-steam-launch-not-ready"
            ),
            (
                .windowsExecutableLaunchReserved,
                "다른 Windows EXE 실행 전환이 진행 중입니다.",
                "steam-session-ownership case=windows-executable-launch-reserved"
            ),
            (
                .windowsExecutableLaunchBlockedByCompatibilitySession,
                "활성 호환성 Steam 세션을 먼저 종료하세요.",
                "steam-session-ownership case=windows-executable-blocked-by-compatibility-session"
            ),
            (
                .windowsExecutableLaunchBlockedByCompatibilityTransition,
                "호환성 Steam 세션 전환이 끝날 때까지 기다리세요.",
                "steam-session-ownership case=windows-executable-blocked-by-compatibility-transition"
            ),
            (
                .windowsExecutableLaunchNotReady,
                "Steam 실행 또는 다른 프리픽스 작업이 끝날 때까지 기다리세요.",
                "steam-session-ownership case=windows-executable-launch-not-ready"
            )
        ]
        let appState = AppState()

        for language in ForgePlayLanguageMode.allCases where language != .system {
            appState.languageMode = language
            for testCase in cases {
                let bridgedError = testCase.error as NSError
                let message = appState.localizedError(testCase.error)
                XCTAssertFalse(
                    message.isEmpty,
                    "Empty ownership error for \(testCase.error) in \(language)"
                )
                XCTAssertEqual(
                    message,
                    ForgePlayLocalization.localized(
                        testCase.userKey,
                        language: language
                    ),
                    "Wrong ownership message for \(testCase.error) in \(language)"
                )
                XCTAssertFalse(message.contains(bridgedError.domain), message)
                XCTAssertFalse(message.contains("Error Domain"), message)
                XCTAssertEqual(
                    forgePlayTechnicalErrorSummary(testCase.error),
                    testCase.technicalDescription
                )
            }
        }
    }

    @MainActor
    func testManagedRootOperationLeaseErrorsPreserveUserAndTechnicalContext() {
        let lockURL = URL(fileURLWithPath: "/tmp/OperationLocks/managed-root.lock")
        let error = ManagedRootOperationLeaseError.lockFailed(lockURL, "permission denied")
        let appState = AppState()
        appState.languageMode = .english

        let userMessage = appState.localizedError(error)
        XCTAssertTrue(userMessage.contains(lockURL.path), userMessage)
        XCTAssertTrue(userMessage.contains("permission denied"), userMessage)
        XCTAssertFalse(userMessage.contains("ForgePlay.ManagedRootOperationLeaseError"), userMessage)

        let technicalMessage = forgePlayTechnicalErrorSummary(error)
        XCTAssertTrue(technicalMessage.contains(lockURL.path), technicalMessage)
        XCTAssertTrue(technicalMessage.contains("permission denied"), technicalMessage)
        XCTAssertFalse(technicalMessage.contains("ForgePlay.ManagedRootOperationLeaseError"), technicalMessage)
    }

    @MainActor
    func testWindowsFontCompatibilityErrorsPreserveMissingItems() {
        let missing = "HKLM\\Software\\Microsoft\\Windows NT\\CurrentVersion\\FontSubstitutes\\MS Shell Dlg 2=Tahoma"
        let error = WindowsFontCompatibilityProfileError.verificationFailed([missing])
        let appState = AppState()
        appState.languageMode = .english

        let userMessage = appState.localizedError(error)
        XCTAssertTrue(userMessage.contains(missing), userMessage)
        XCTAssertFalse(userMessage.contains("ForgePlay.WindowsFontCompatibilityProfileError"), userMessage)

        let technicalMessage = forgePlayTechnicalErrorSummary(error)
        XCTAssertTrue(technicalMessage.contains(missing), technicalMessage)
        XCTAssertFalse(technicalMessage.contains("ForgePlay.WindowsFontCompatibilityProfileError"), technicalMessage)
    }

    @MainActor
    func testReadOnlyVolumeWriteErrorIsUserFacing() {
        let path = "/Sample Games/ForgePlay Library"
        let error = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileWriteVolumeReadOnlyError,
            userInfo: [NSFilePathErrorKey: path]
        )
        let appState = AppState()

        appState.languageMode = .korean
        let koreanMessage = appState.localizedError(error)
        XCTAssertEqual(koreanMessage, appState.localizedFormat("선택한 위치에 쓸 수 없습니다: %@", path))
        XCTAssertFalse(koreanMessage.contains("NSCocoaErrorDomain 642"))

        appState.languageMode = .english
        let englishMessage = appState.localizedError(error)
        XCTAssertEqual(englishMessage, "Cannot write to the selected location: \(path)")
        XCTAssertFalse(englishMessage.contains("NSCocoaErrorDomain 642"))
    }

    @MainActor
    func testSteamLaunchProcessFailureSurfacesActionExitCodeAndLog() {
        var result = sampleProcessRunResult()
        result.actionName = "setRegistryValue:HKCU\\Software\\Wine\\Direct3D:VideoMemorySize"
        result.exitCode = 9
        let error = SteamLaunchError.steamClientCompatibilitySetupFailed(result)
        let appState = AppState()

        let message = appState.localizedError(error)
        appState.setError(error)

        XCTAssertTrue(message.contains(result.actionName), message)
        XCTAssertTrue(message.contains("종료 코드: 9"), message)
        XCTAssertFalse(message.contains("ForgePlay.SteamLaunchError"), message)
        XCTAssertEqual(appState.currentNotice?.logURL, result.stderrLog)
    }

    @MainActor
    func testNVIDIARendererVerificationFailuresUseTheSelectedLanguage() {
        let policyError = SteamLaunchError.rendererPolicyVerificationFailed(
            "선택한 D3DMetal 공급자 경로에 실제로 적용된 레지스트리 또는 모듈 상태가 요청과 일치하지 않습니다."
        )
        let markerError = SteamLaunchError.rendererBridgeInstallFailed(
            URL(fileURLWithPath: "/tmp/ForgePlay/nvngx-on-metalfx.session.json"),
            "MetalFX 모듈 복원 정보 파일을 저장한 뒤 내용이 일치하는지 확인하지 못했습니다."
        )
        let appState = AppState()

        appState.languageMode = .korean
        let koreanPolicy = appState.localizedError(policyError)
        let koreanMarker = appState.localizedError(markerError)
        XCTAssertEqual(
            koreanPolicy,
            "선택한 D3DMetal 공급자 경로에 실제로 적용된 레지스트리 또는 모듈 상태가 요청과 일치하지 않습니다."
        )
        XCTAssertTrue(koreanMarker.contains("D3DMetal MetalFX/NGX 브리지를 준비하지 못했습니다"), koreanMarker)
        XCTAssertTrue(koreanMarker.contains("복원 정보 파일"), koreanMarker)

        appState.languageMode = .english
        let englishPolicy = appState.localizedError(policyError)
        let englishMarker = appState.localizedError(markerError)
        XCTAssertEqual(
            englishPolicy,
            "The registry or module state applied to the selected D3DMetal provider path does not match the requested configuration."
        )
        XCTAssertTrue(englishMarker.contains("Could not prepare the D3DMetal MetalFX/NGX bridge"), englishMarker)
        XCTAssertTrue(englishMarker.contains("restoration record"), englishMarker)
        XCTAssertFalse(englishPolicy.contains("레지스트리"), englishPolicy)
        XCTAssertFalse(englishMarker.contains("복원 정보"), englishMarker)
        XCTAssertFalse(englishPolicy.localizedCaseInsensitiveContains("readback"), englishPolicy)
        XCTAssertFalse(englishMarker.localizedCaseInsensitiveContains("readback"), englishMarker)
    }

    @MainActor
    func testRendererRestorationTimeoutPreservesStructuredProcessEvidence() {
        var result = sampleProcessRunResult()
        result.actionName = "waitForWinePrefix"
        result.exitCode = 0
        result.hasProcessExitCode = false
        result.forgePlayStatusCode = 124
        result.didTimeOut = true
        result.outcome = .timedOut
        result.terminationSignal = SIGKILL
        result.rawWaitStatus = SIGKILL
        let error = SteamLaunchError.rendererLifecycleFailed(
            SteamRendererLifecycleFailure(
                phase: .postLaunchRestoration,
                operation: .ngxCoreRegistryFlush,
                target: URL(fileURLWithPath: "/tmp/SteamShared/system.reg"),
                detail: "NGXCore registry flush timed out",
                processResults: [result]
            )
        )
        let appState = AppState()

        let message = appState.localizedError(error)
        let evidence = diagnosticProcessRunResults(from: error)

        XCTAssertTrue(message.contains("복원"), message)
        XCTAssertFalse(message.contains("payload 파일을 Steam 프리픽스에 준비"), message)
        XCTAssertTrue(message.contains("ForgePlay 상태 코드: 124"), message)
        XCTAssertTrue(message.contains("SIGKILL (9)"), message)
        XCTAssertTrue(message.contains("시간 초과"), message)
        XCTAssertTrue(message.contains("프로세스 종료 코드: unavailable"), message)
        XCTAssertEqual(evidence, [result])
        XCTAssertEqual(error.forgePlayDiagnosticLogURL, result.preferredDiagnosticLog)
    }

    func testServiceErrorDescriptionsUseTechnicalSummaryForNestedLocalizedErrors() {
        let nestedError = NSError(
            domain: "NestedKoreanError",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "테스트용 하위 오류 설명"]
        )
        let errors: [Error] = [
            CompatibilityServiceError.recipeDiscoveryFailed(URL(fileURLWithPath: "/tmp/Recipes"), nestedError),
            CompatibilityServiceError.recipeMetadataReadFailed(URL(fileURLWithPath: "/tmp/recipe.json"), nestedError),
            SteamLibraryScanError.scanFailed(URL(fileURLWithPath: "/tmp/steamapps"), forgePlayTechnicalErrorSummary(nestedError)),
            SteamLibraryScanError.metadataReadFailed(URL(fileURLWithPath: "/tmp/appmanifest_42.acf"), forgePlayTechnicalErrorSummary(nestedError)),
            SteamLibraryScanError.fileReadFailed(URL(fileURLWithPath: "/tmp/libraryfolders.vdf"), forgePlayTechnicalErrorSummary(nestedError)),
            RuntimeManagerError.extractedInstallerScanFailed(URL(fileURLWithPath: "/tmp/Extracted"), nestedError),
            RuntimeManagerError.extractionCleanupFailed(
                directory: URL(fileURLWithPath: "/tmp/Extracted"),
                originalError: nestedError,
                cleanupError: nestedError
            ),
            WindowsRuntimeServiceError.sourceScanFailed(URL(fileURLWithPath: "/tmp/Evaluation"), nestedError),
            WindowsRuntimeServiceError.supplementalRedistScanFailed(URL(fileURLWithPath: "/tmp/Redist"), nestedError),
            WindowsRuntimeServiceError.payloadReplacementRollbackFailed(
                destination: URL(fileURLWithPath: "/tmp/Renderers/AppleD3DMetal"),
                backup: URL(fileURLWithPath: "/tmp/Renderers/.AppleD3DMetal.backup"),
                originalError: nestedError,
                rollbackError: nestedError
            ),
            SupportBundleServiceError.scanFailed(URL(fileURLWithPath: "/tmp/Logs"), nestedError),
            SupportBundleServiceError.metadataReadFailed(URL(fileURLWithPath: "/tmp/log.txt"), nestedError),
            LogRetentionServiceError.scanFailed(URL(fileURLWithPath: "/tmp/Logs"), nestedError),
            LogRetentionServiceError.metadataReadFailed(URL(fileURLWithPath: "/tmp/log.txt"), nestedError),
            SafeProcessRunnerError.runnerLibrarySearchFailed(URL(fileURLWithPath: "/tmp/wine"), nestedError)
        ]

        for error in errors {
            let description = error.localizedDescription
            XCTAssertFalse(
                description.contains("테스트용 하위 오류 설명"),
                "Nested localized description leaked for \(type(of: error)): \(description)"
            )
            XCTAssertTrue(
                description.contains("NestedKoreanError 42"),
                "Expected technical summary for \(type(of: error)): \(description)"
            )
        }
    }

    func testFormatPlaceholdersArePreservedAcrossLocalizations() throws {
        let english = try strings(for: "en")

        for language in ForgePlayLanguageMode.allCases where language != .system {
            let directory = try XCTUnwrap(language.localizationDirectory)
            let localized = try strings(for: directory)

            for key in english.keys {
                let keyResult = parsedFormat(in: key)
                let localizedResult = parsedFormat(in: localized[key] ?? "")
                XCTAssertTrue(
                    keyResult.validityIssues.isEmpty,
                    "Invalid printf directive in localization key \(key): \(keyResult.validityIssues)"
                )
                XCTAssertTrue(
                    localizedResult.validityIssues.isEmpty,
                    "Invalid printf directive for \(key) in \(directory): \(localizedResult.validityIssues)"
                )
                XCTAssertEqual(
                    keyResult.canonicalArgumentSignatures,
                    localizedResult.canonicalArgumentSignatures,
                    "Placeholder mismatch for \(key) in \(directory)"
                )
            }
        }
    }

    func testPrintfPlaceholderTokenizerRecognizesCanonicalArgumentSignatures() {
        XCTAssertEqual(
            placeholders(in: "escaped %% object %@ count %lld precise %.1f whole %.0f"),
            [
                "1:value:flags=;width=none;precision=none;length=;conversion=@",
                "2:value:flags=;width=none;precision=none;length=ll;conversion=d",
                "3:value:flags=;width=none;precision=fixed:1;length=;conversion=f",
                "4:value:flags=;width=none;precision=fixed:0;length=;conversion=f"
            ]
        )
        XCTAssertEqual(
            placeholders(in: "%1$-+#010.4llx"),
            ["1:value:flags=-+#0;width=fixed:10;precision=fixed:4;length=ll;conversion=x"]
        )
        XCTAssertEqual(placeholders(in: "100%% ready"), [])
        XCTAssertEqual(
            placeholders(in: "%*.*f"),
            [
                "1:width:signed-int",
                "2:precision:signed-int",
                "3:value:flags=;width=argument:1;precision=argument:2;length=;conversion=f"
            ]
        )
        XCTAssertEqual(
            placeholders(in: "%*.*f"),
            placeholders(in: "%3$*1$.*2$f")
        )
        XCTAssertTrue(parsedFormat(in: "%*.*f").validityIssues.isEmpty)
        XCTAssertTrue(parsedFormat(in: "%3$*1$.*2$f").validityIssues.isEmpty)
        XCTAssertTrue(parsedFormat(in: "%1$@ then %1$@").validityIssues.isEmpty)
        XCTAssertTrue(parsedFormat(in: "%1$d then %1$i").validityIssues.isEmpty)
        XCTAssertTrue(parsedFormat(in: "%1$*1$d").validityIssues.isEmpty)
    }

    func testPrintfPlaceholderTokenizerPreservesDynamicArgumentOwnershipAcrossDirectiveReordering() {
        let baseline = parsedFormat(in: "%3$*1$.*2$f %6$*4$.*5$f")
        let reordered = parsedFormat(in: "%6$*4$.*5$f %3$*1$.*2$f")
        let swappedWidths = parsedFormat(in: "%3$*4$.*2$f %6$*1$.*5$f")
        let swappedPrecisions = parsedFormat(in: "%3$*1$.*5$f %6$*4$.*2$f")

        for result in [baseline, reordered, swappedWidths, swappedPrecisions] {
            XCTAssertTrue(result.validityIssues.isEmpty)
        }
        XCTAssertEqual(
            baseline.canonicalArgumentSignatures,
            reordered.canonicalArgumentSignatures
        )
        XCTAssertNotEqual(
            baseline.canonicalArgumentSignatures,
            swappedWidths.canonicalArgumentSignatures
        )
        XCTAssertNotEqual(
            baseline.canonicalArgumentSignatures,
            swappedPrecisions.canonicalArgumentSignatures
        )
    }

    func testPrintfPlaceholderTokenizerRejectsDecoratedCountConversions() {
        let malformedCountConversions = [
            "%+n",
            "%5n",
            "%*n",
            "%.2n",
            "%2$*1$n",
            "%2$.*1$n"
        ]
        for format in malformedCountConversions {
            XCTAssertEqual(
                parsedFormat(in: format).validityIssues.map(\.kind),
                [.malformedDirective],
                "Decorated count conversion was accepted: \(format)"
            )
        }

        let validCountConversions = ["%n", "%hhn", "%hn", "%ln", "%lln"]
        for format in validCountConversions {
            XCTAssertTrue(
                parsedFormat(in: format).validityIssues.isEmpty,
                "Valid count conversion was rejected: \(format)"
            )
        }
    }

    func testPrintfPlaceholderTokenizerReportsMalformedDirectiveFamilies() {
        typealias IssueKind = PrintfFormatArgumentTokenizer.ValidityIssue.Kind
        let malformedCases: [(name: String, format: String, expected: IssueKind)] = [
            ("dangling percent", "dangling %", .danglingPercent),
            ("unknown conversion", "unknown %Q", .unknownConversion),
            ("incomplete positional", "position %1$", .incompletePositionalArgument),
            ("incomplete star width", "width %*", .incompleteWidth),
            ("incomplete fixed width", "width %12", .incompleteWidth),
            ("incomplete precision", "precision %.", .incompletePrecision),
            ("incomplete positional precision", "precision %.*2$", .incompletePrecision),
            ("incomplete length", "length %ll", .incompleteLength),
            ("invalid length conversion", "invalid %ll@", .malformedDirective),
            ("illegal positional percent", "illegal %1$%", .illegalPositionalPercent),
            ("decorated percent", "illegal %*%", .malformedPercentDirective),
            ("zero positional", "invalid %0$@", .invalidPositionalArgument),
            ("incomplete flags", "malformed %-", .malformedDirective)
        ]

        for malformedCase in malformedCases {
            let result = parsedFormat(in: malformedCase.format)
            XCTAssertTrue(
                result.validityIssues.map(\.kind).contains(malformedCase.expected),
                "Missing \(malformedCase.expected) for \(malformedCase.name): \(result.validityIssues)"
            )
        }

        XCTAssertTrue(parsedFormat(in: "escaped %%").validityIssues.isEmpty)
    }

    func testPrintfPlaceholderTokenizerDoesNotHideMalformedTokensBehindValidSignatures() {
        let baseline = parsedFormat(in: "value %@")
        let unknownPrefix = parsedFormat(in: "bad %1$Q value %@")
        let danglingSuffix = parsedFormat(in: "value %@ trailing %")

        XCTAssertTrue(baseline.validityIssues.isEmpty)
        XCTAssertEqual(
            baseline.canonicalArgumentSignatures,
            unknownPrefix.canonicalArgumentSignatures
        )
        XCTAssertEqual(
            baseline.canonicalArgumentSignatures,
            danglingSuffix.canonicalArgumentSignatures
        )
        XCTAssertEqual(unknownPrefix.validityIssues.map(\.kind), [.unknownConversion])
        XCTAssertEqual(danglingSuffix.validityIssues.map(\.kind), [.danglingPercent])
        XCTAssertEqual(
            parsedFormat(in: "%1$%").validityIssues.map(\.kind),
            [.illegalPositionalPercent]
        )
    }

    func testPrintfPlaceholderTokenizerRejectsMixedAndConflictingPositionalArguments() {
        let allPositional = parsedFormat(in: "count %1$d object %2$@")
        let reordered = parsedFormat(in: "object %2$@ count %1$d")
        let mixed = parsedFormat(in: "object %2$@ count %d")
        let positionalStars = parsedFormat(in: "%3$*1$.*2$f")
        let mixedStars = parsedFormat(in: "%3$*.*f")

        XCTAssertTrue(allPositional.validityIssues.isEmpty)
        XCTAssertTrue(reordered.validityIssues.isEmpty)
        XCTAssertEqual(
            allPositional.canonicalArgumentSignatures,
            reordered.canonicalArgumentSignatures
        )
        XCTAssertEqual(
            allPositional.canonicalArgumentSignatures,
            mixed.canonicalArgumentSignatures
        )
        XCTAssertEqual(mixed.validityIssues.map(\.kind), [.mixedArgumentAddressing])
        XCTAssertTrue(positionalStars.validityIssues.isEmpty)
        XCTAssertEqual(
            positionalStars.canonicalArgumentSignatures,
            mixedStars.canonicalArgumentSignatures
        )
        XCTAssertEqual(mixedStars.validityIssues.map(\.kind), [.mixedArgumentAddressing])

        let compatibleReuse = [
            "%1$@ then %1$@",
            "%1$d then %1$i",
            "%1$*1$d",
            "%1$D then %1$ld",
            "%1$U then %1$lu"
        ]
        for format in compatibleReuse {
            XCTAssertTrue(
                parsedFormat(in: format).validityIssues.isEmpty,
                "Compatible positional reuse was rejected: \(format)"
            )
        }

        XCTAssertEqual(
            parsedFormat(in: "%1$@ then %1$d").validityIssues.map(\.kind),
            [.incompatibleDuplicatePosition]
        )
        XCTAssertEqual(
            parsedFormat(in: "%1$*1$u").validityIssues.map(\.kind),
            [.incompatibleDuplicatePosition]
        )
        XCTAssertEqual(
            parsedFormat(in: "%1$hn then %1$n").validityIssues.map(\.kind),
            [.incompatibleDuplicatePosition]
        )
    }

    func testPrintfPlaceholderTokenizerRejectsArgumentSignatureMutations() {
        let baseline = "object %@ count %lld whole %.0f precise %.1f"
        let baselineSignatures = placeholders(in: baseline)
        let mutations = [
            ("removed %.1f", "object %@ count %lld whole %.0f precise"),
            ("changed %.1f", "object %@ count %lld whole %.0f precise %.0f"),
            ("removed %.0f", "object %@ count %lld whole precise %.1f"),
            ("changed %.0f", "object %@ count %lld whole %.1f precise %.1f"),
            ("removed %lld", "object %@ count whole %.0f precise %.1f"),
            ("changed %lld", "object %@ count %ld whole %.0f precise %.1f"),
            ("removed %@", "object count %lld whole %.0f precise %.1f"),
            ("changed %@", "object %s count %lld whole %.0f precise %.1f"),
            (
                "changed positional arguments",
                "precise %3$.1f whole %4$.0f count %2$lld object %1$@"
            )
        ]

        XCTAssertEqual(
            baselineSignatures,
            placeholders(in: "precise %4$.1f whole %3$.0f count %2$lld object %1$@")
        )
        for (name, mutation) in mutations {
            XCTAssertNotEqual(
                baselineSignatures,
                placeholders(in: mutation),
                "Mutation unexpectedly preserved the argument signature: \(name)"
            )
        }
    }

    func testBluetoothUsageDescriptionIsLocalizedForEverySupportedLanguage() throws {
        let root = try projectRoot()
        let infoData = try Data(contentsOf: root.appending(path: "Sources/ForgePlay/Info.plist"))
        let info = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any]
        )
        let fallback = try XCTUnwrap(info["NSBluetoothAlwaysUsageDescription"] as? String)
        XCTAssertFalse(fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        let advertisedLocalizations = try XCTUnwrap(info["CFBundleLocalizations"] as? [String])
        let supportedLocalizations = ForgePlayLanguageMode.allCases.compactMap(\.localizationDirectory)
        XCTAssertEqual(Set(advertisedLocalizations), Set(supportedLocalizations))

        for localization in advertisedLocalizations {
            let stringsURL = root.appending(
                path: "Resources/\(localization).lproj/InfoPlist.strings"
            )
            let data = try Data(contentsOf: stringsURL)
            let values = try XCTUnwrap(
                PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String],
                "Invalid InfoPlist.strings in \(localization)"
            )
            let description = try XCTUnwrap(
                values["NSBluetoothAlwaysUsageDescription"],
                "Missing Bluetooth purpose string in \(localization)"
            )
            XCTAssertFalse(
                description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "Empty Bluetooth purpose string in \(localization)"
            )
        }
    }

    private func writeExecutable(at url: URL, exitCode: Int32) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "#!/bin/sh\nprintf 'runtime probe fixture\\n'\nexit \(exitCode)\n"
            .write(to: url, atomically: true, encoding: .utf8)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }

    private func projectRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appending(path: "project.yml").path) {
                return url
            }
        }
        throw XCTSkip("Could not locate project root from #filePath")
    }

    private func decodedSwiftStringLiteral(_ literal: String) -> String {
        var output = ""
        var iterator = literal.makeIterator()

        while let character = iterator.next() {
            guard character == "\\" else {
                output.append(character)
                continue
            }

            guard let escaped = iterator.next() else {
                output.append(character)
                break
            }

            switch escaped {
            case "n":
                output.append("\n")
            case "t":
                output.append("\t")
            case "r":
                output.append("\r")
            case "\"":
                output.append("\"")
            case "\\":
                output.append("\\")
            default:
                output.append("\\")
                output.append(escaped)
            }
        }

        return output
    }

    private func sampleProcessRunResult() -> ProcessRunResult {
        ProcessRunResult(
            actionName: "test",
            executable: URL(fileURLWithPath: "/tmp/wine"),
            arguments: [],
            startedAt: Date(timeIntervalSince1970: 0),
            endedAt: Date(timeIntervalSince1970: 1),
            exitCode: 1,
            stdoutLog: URL(fileURLWithPath: "/tmp/stdout.log"),
            stderrLog: URL(fileURLWithPath: "/tmp/stderr.log"),
            didTimeOut: false
        )
    }

    private func strings(for directory: String) throws -> [String: String] {
        let lprojPath = try XCTUnwrap(Bundle.main.path(forResource: directory, ofType: "lproj"))
        let stringsURL = URL(fileURLWithPath: lprojPath)
            .appending(path: "Localizable.strings")
        let data = try Data(contentsOf: stringsURL)
        var format = PropertyListSerialization.PropertyListFormat.openStep
        guard let output = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: &format
        ) as? [String: String] else {
            XCTFail("Invalid Localizable.strings file in \(directory)")
            return [:]
        }
        return output
    }

    private func placeholders(in string: String) -> [String] {
        parsedFormat(in: string).canonicalArgumentSignatures
    }

    private func parsedFormat(
        in string: String
    ) -> PrintfFormatArgumentTokenizer.ParseResult {
        PrintfFormatArgumentTokenizer.parse(string)
    }

}
