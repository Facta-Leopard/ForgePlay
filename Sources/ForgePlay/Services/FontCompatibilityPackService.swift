import CoreGraphics
import CoreText
import CryptoKit
import Foundation

enum FontCompatibilityPackFailure: String, Codable, Error, Hashable, Sendable {
    case resourceRootUnavailable
    case manifestMissing
    case manifestIntegrityMismatch
    case manifestInvalid
    case cyrillicCoverageMissing
    case cyrillicCoverageIntegrityMismatch
    case cyrillicCoverageInvalid
    case glyphCoverageMismatch
    case unsupportedLocalization
    case assetMissing
    case assetIntegrityMismatch
    case legalNoticeInvalid
    case registrationFailed
    case registrationRollbackFailed
}

enum FontCompatibilityPackActivationState: Hashable, Sendable {
    case notAttempted
    case active(localizationIdentifier: String, registeredFontCount: Int)
    case unavailable(localizationIdentifier: String, failure: FontCompatibilityPackFailure)
}

actor FontCompatibilityPackService {
    private static let packID = "forgeplay-font-compatibility-pack-v1"
    private static let manifestFileName = "forgeplay-font-compatibility-pack-v1.json"
    private static let manifestByteLength = 9_388
    private static let manifestSHA256 =
        "f8dfb7a7f7adbc54b77fd187c2cf0f976fa5445545c7a953dafd04e87f98e3b1"
    private static let cyrillicCoverageManifestFileName =
        "forgeplay-font-cyrillic-coverage-v1.json"
    private static let cyrillicCoverageManifestByteLength = 1_578
    private static let cyrillicCoverageManifestSHA256 =
        "d2292b92762c2d3eb7391b34f135c95349072502c673dd142fada39df30c35f9"
    private static let fontCount = 10
    private static let noticeCount = 2
    private static let packByteLength = 135_069_481
    private static let maximumHumanReadableNoticeBytes = 1_048_576
    private static let coreTextAlreadyRegisteredErrorCode = 105

    private struct Manifest: Decodable, Sendable {
        let schema: String
        let schemaVersion: Int
        let packID: String
        let license: String
        let sourceBytesModified: Bool
        let fontCountExact: Int
        let licenseTextCountExact: Int
        let packByteLengthExact: Int
        let fonts: [FontAsset]
        let licenseTexts: [LicenseTextAsset]
        let copyrightAttributions: [CopyrightAttribution]
        let localePolicy: [LocalePolicy]
        let humanReadableNoticeResource: String
    }

    private struct FontAsset: Decodable, Hashable, Sendable {
        let fileName: String
        let role: String
        let byteLength: Int
        let sha256: String
        let tableProfile: String
        let family: String
        let subfamily: String
        let fullName: String
        let postScriptName: String
        let uniqueID: String
        let version: String
        let os2WeightClass: Int
        let os2WidthClass: Int
        let os2Selection: Int
        let headMacStyle: Int
        let italicAngle: Int
        let mappedLocalizations: [String]
    }

    private struct LicenseTextAsset: Decodable, Hashable, Sendable {
        let fileName: String
        let role: String
        let byteLength: Int
        let sha256: String
        let appliesToRoles: [String]
    }

    private struct CopyrightAttribution: Decodable, Hashable, Sendable {
        let scope: String
        let notice: String
    }

    private struct LocalePolicy: Decodable, Hashable, Sendable {
        let localizations: [String]
        let regularRoleCascade: [String]
        let boldRoleCascade: [String]
    }

    private struct CyrillicCoverageManifest: Decodable, Sendable {
        let schema: String
        let schemaVersion: Int
        let coverageID: String
        let sourcePackID: String
        let activationScope: String
        let uiLocalizationContract: String
        let windowsPrefixContract: String
        let languageCoverage: [LanguageCoverage]
        let fontAssets: [CoverageFontAsset]
    }

    private struct LanguageCoverage: Decodable, Hashable, Sendable {
        let languageTag: String
        let sequenceID: String
        let requiredCharacters: String
    }

    private struct CoverageFontAsset: Decodable, Hashable, Sendable {
        let role: String
        let fileName: String
        let byteLength: Int
        let sha256: String
        let postScriptName: String
        let requiredSequenceIDs: [String]
    }

    private struct VerifiedPack: Sendable {
        let manifest: Manifest
        let fontURLsByRole: [String: URL]
    }

    private struct RegistrationResult {
        let succeeded: Bool
        let registeredByThisService: Bool
    }

    private var cachedPack: VerifiedPack?
    private var activeLocalizationIdentifier: String?
    private var activeFontURLs: [URL] = []
    private var ownedFontURLs: Set<URL> = []

    func activate(
        localizationIdentifier requestedIdentifier: String,
        resourceRootURL: URL? = nil
    ) -> FontCompatibilityPackActivationState {
        let localizationIdentifier: String
        do {
            localizationIdentifier = try Self.supportedLocalization(
                requestedIdentifier
            )
        } catch {
            return .unavailable(
                localizationIdentifier: requestedIdentifier,
                failure: .unsupportedLocalization
            )
        }

        if activeLocalizationIdentifier == localizationIdentifier,
           ownedFontURLs.isSubset(of: Set(activeFontURLs)) {
            return .active(
                localizationIdentifier: localizationIdentifier,
                registeredFontCount: activeFontURLs.count
            )
        }

        let pack: VerifiedPack
        do {
            if let cachedPack {
                pack = cachedPack
            } else {
                pack = try Self.loadAndVerifyPack(resourceRootURL: resourceRootURL)
                cachedPack = pack
            }
        } catch let failure as FontCompatibilityPackFailure {
            return .unavailable(
                localizationIdentifier: localizationIdentifier,
                failure: failure
            )
        } catch {
            return .unavailable(
                localizationIdentifier: localizationIdentifier,
                failure: .manifestInvalid
            )
        }

        let matchingPolicies = pack.manifest.localePolicy.filter {
            $0.localizations.contains(localizationIdentifier)
        }
        guard matchingPolicies.count == 1,
              let selectedPolicy = matchingPolicies.first else {
            return .unavailable(
                localizationIdentifier: localizationIdentifier,
                failure: .unsupportedLocalization
            )
        }
        let selectedRoles = selectedPolicy.regularRoleCascade +
            selectedPolicy.boldRoleCascade
        let selectedFontURLs = selectedRoles.compactMap {
            pack.fontURLsByRole[$0]
        }
        guard selectedFontURLs.count == selectedRoles.count,
              Set(selectedFontURLs).count == selectedFontURLs.count else {
            return .unavailable(
                localizationIdentifier: localizationIdentifier,
                failure: .assetMissing
            )
        }

        let previousFontURLs = activeFontURLs
        let previousFontURLSet = Set(previousFontURLs)
        let selectedFontURLSet = Set(selectedFontURLs)
        let knownRegisteredURLSet = previousFontURLSet.union(ownedFontURLs)
        let urlsToRegister = selectedFontURLs.filter {
            !knownRegisteredURLSet.contains($0)
        }
        var newlyOwnedURLs: [URL] = []

        for url in urlsToRegister {
            guard !Task.isCancelled else {
                let rollbackSucceeded = rollbackNewRegistrations(newlyOwnedURLs)
                return .unavailable(
                    localizationIdentifier: localizationIdentifier,
                    failure: rollbackSucceeded ? .registrationFailed : .registrationRollbackFailed
                )
            }
            let result = Self.registerFont(at: url)
            guard result.succeeded else {
                let rollbackSucceeded = rollbackNewRegistrations(newlyOwnedURLs)
                return .unavailable(
                    localizationIdentifier: localizationIdentifier,
                    failure: rollbackSucceeded ? .registrationFailed : .registrationRollbackFailed
                )
            }
            if result.registeredByThisService {
                newlyOwnedURLs.append(url)
                ownedFontURLs.insert(url)
            }
        }

        let obsoleteOwnedURLs = ownedFontURLs
            .filter { !selectedFontURLSet.contains($0) }
            .sorted { $0.path < $1.path }
        var unregisteredObsoleteURLs: [URL] = []
        for url in obsoleteOwnedURLs {
            guard Self.unregisterFont(at: url) else {
                let restoredPrevious = restoreRegistrations(unregisteredObsoleteURLs)
                let rolledBackNew = rollbackNewRegistrations(newlyOwnedURLs)
                if !restoredPrevious {
                    activeLocalizationIdentifier = nil
                    activeFontURLs = []
                }
                return .unavailable(
                    localizationIdentifier: localizationIdentifier,
                    failure: restoredPrevious && rolledBackNew
                        ? .registrationFailed
                        : .registrationRollbackFailed
                )
            }
            unregisteredObsoleteURLs.append(url)
            ownedFontURLs.remove(url)
        }

        activeFontURLs = selectedFontURLs
        activeLocalizationIdentifier = localizationIdentifier
        return .active(
            localizationIdentifier: localizationIdentifier,
            registeredFontCount: selectedFontURLs.count
        )
    }

    private func rollbackNewRegistrations(_ urls: [URL]) -> Bool {
        var succeeded = true
        for url in urls.reversed() {
            if Self.unregisterFont(at: url) {
                ownedFontURLs.remove(url)
            } else {
                succeeded = false
            }
        }
        return succeeded
    }

    private func restoreRegistrations(_ urls: [URL]) -> Bool {
        var succeeded = true
        for url in urls {
            let result = Self.registerFont(at: url)
            if result.succeeded {
                if result.registeredByThisService {
                    ownedFontURLs.insert(url)
                }
            } else {
                succeeded = false
            }
        }
        return succeeded
    }

    private static func loadAndVerifyPack(
        resourceRootURL suppliedResourceRootURL: URL?
    ) throws -> VerifiedPack {
        let resourceRootURL: URL
        if let suppliedResourceRootURL {
            resourceRootURL = suppliedResourceRootURL
        } else if let bundledResourceRootURL = Bundle.main.resourceURL {
            resourceRootURL = bundledResourceRootURL
        } else {
            throw FontCompatibilityPackFailure.resourceRootUnavailable
        }

        guard let manifestURL = resourceURL(
            named: manifestFileName,
            under: resourceRootURL
        ) else {
            throw FontCompatibilityPackFailure.manifestMissing
        }
        let manifestData = try exactData(
            at: manifestURL,
            byteLength: manifestByteLength,
            sha256: manifestSHA256,
            mismatch: .manifestIntegrityMismatch
        )
        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        } catch {
            throw FontCompatibilityPackFailure.manifestInvalid
        }

        guard let cyrillicCoverageManifestURL = resourceURL(
            named: cyrillicCoverageManifestFileName,
            under: resourceRootURL
        ) else {
            throw FontCompatibilityPackFailure.cyrillicCoverageMissing
        }
        let cyrillicCoverageManifestData = try exactData(
            at: cyrillicCoverageManifestURL,
            byteLength: cyrillicCoverageManifestByteLength,
            sha256: cyrillicCoverageManifestSHA256,
            mismatch: .cyrillicCoverageIntegrityMismatch
        )
        let cyrillicCoverageManifest: CyrillicCoverageManifest
        do {
            cyrillicCoverageManifest = try JSONDecoder().decode(
                CyrillicCoverageManifest.self,
                from: cyrillicCoverageManifestData
            )
        } catch {
            throw FontCompatibilityPackFailure.cyrillicCoverageInvalid
        }

        let fontFileNames = manifest.fonts.map(\.fileName)
        let licenseFileNames = manifest.licenseTexts.map(\.fileName)
        let allFileNames = fontFileNames + licenseFileNames
        let fontRoles = manifest.fonts.map(\.role)
        let licenseRoles = manifest.licenseTexts.map(\.role)
        let exactLocalizationSet: Set<String> = [
            "en", "ko", "de", "es", "fr", "ja", "zh-Hans", "zh-Hant"
        ]
        let policyLocalizations = manifest.localePolicy.flatMap(\.localizations)
        guard Set(allFileNames).count == fontCount + noticeCount,
              Set(fontRoles).count == fontCount,
              Set(licenseRoles).count == noticeCount else {
            throw FontCompatibilityPackFailure.manifestInvalid
        }
        let fontsByRole = Dictionary(
            uniqueKeysWithValues: manifest.fonts.map { ($0.role, $0) }
        )
        let declaredPackByteLength = manifest.fonts.reduce(0, { $0 + $1.byteLength }) +
            manifest.licenseTexts.reduce(0, { $0 + $1.byteLength })
        guard manifest.schema == "ForgePlayFontCompatibilityManifestV1",
              manifest.schemaVersion == 1,
              manifest.packID == packID,
              manifest.license == "SIL Open Font License 1.1",
              manifest.sourceBytesModified == false,
              manifest.fontCountExact == fontCount,
              manifest.licenseTextCountExact == noticeCount,
              manifest.packByteLengthExact == packByteLength,
              manifest.fonts.count == fontCount,
              manifest.licenseTexts.count == noticeCount,
              declaredPackByteLength == packByteLength,
              manifest.fonts.allSatisfy(validFontDeclaration),
              manifest.licenseTexts.allSatisfy(validLicenseDeclaration),
              Set(manifest.licenseTexts.flatMap(\.appliesToRoles)) == Set(fontRoles),
              manifest.licenseTexts.flatMap(\.appliesToRoles).count == fontRoles.count,
              Set(policyLocalizations) == exactLocalizationSet,
              Set(policyLocalizations).count == policyLocalizations.count,
              manifest.localePolicy.allSatisfy({ policy in
                  !policy.localizations.isEmpty &&
                      !policy.regularRoleCascade.isEmpty &&
                      !policy.boldRoleCascade.isEmpty &&
                      Set(policy.regularRoleCascade).count == policy.regularRoleCascade.count &&
                      Set(policy.boldRoleCascade).count == policy.boldRoleCascade.count &&
                      policy.regularRoleCascade.allSatisfy {
                          fontsByRole[$0]?.subfamily == "Regular"
                      } &&
                      policy.boldRoleCascade.allSatisfy {
                          fontsByRole[$0]?.subfamily == "Bold"
                      }
              }),
              manifest.fonts.allSatisfy({ font in
                  let mappedByPolicy = manifest.localePolicy
                      .filter {
                          $0.regularRoleCascade.contains(font.role) ||
                              $0.boldRoleCascade.contains(font.role)
                      }
                      .flatMap(\.localizations)
                  return Set(mappedByPolicy) == Set(font.mappedLocalizations) &&
                      Set(mappedByPolicy).count == mappedByPolicy.count
              }),
              manifest.copyrightAttributions == [
                  CopyrightAttribution(
                      scope: "latin",
                      notice: "Copyright 2022 The Noto Project Authors (https://github.com/notofonts/latin-greek-cyrillic)"
                  ),
                  CopyrightAttribution(
                      scope: "cjk",
                      notice: "© 2014-2021 Adobe (http://www.adobe.com/)."
                  )
              ],
              manifest.humanReadableNoticeResource == "ForgePlayThirdPartyNotices.md" else {
            throw FontCompatibilityPackFailure.manifestInvalid
        }
        let requiredScalarsByRole = try validateCyrillicCoverageManifest(
            cyrillicCoverageManifest,
            against: manifest
        )
        try validateHumanReadableNotice(
            named: manifest.humanReadableNoticeResource,
            licenseFileNames: licenseFileNames,
            attributions: manifest.copyrightAttributions,
            under: resourceRootURL
        )

        var fontURLsByRole: [String: URL] = [:]
        for font in manifest.fonts {
            guard !Task.isCancelled else {
                throw FontCompatibilityPackFailure.assetIntegrityMismatch
            }
            guard let url = resourceURL(named: font.fileName, under: resourceRootURL) else {
                throw FontCompatibilityPackFailure.assetMissing
            }
            let data = try exactData(
                at: url,
                byteLength: font.byteLength,
                sha256: font.sha256,
                mismatch: .assetIntegrityMismatch
            )
            guard fontMetadataMatches(font, data: data) else {
                throw FontCompatibilityPackFailure.assetIntegrityMismatch
            }
            if let requiredScalars = requiredScalarsByRole[font.role],
               !fontSupports(requiredScalars, data: data) {
                throw FontCompatibilityPackFailure.glyphCoverageMismatch
            }
            fontURLsByRole[font.role] = url
        }
        for licenseText in manifest.licenseTexts {
            guard !Task.isCancelled else {
                throw FontCompatibilityPackFailure.assetIntegrityMismatch
            }
            guard let url = resourceURL(
                named: licenseText.fileName,
                under: resourceRootURL
            ) else {
                throw FontCompatibilityPackFailure.assetMissing
            }
            _ = try exactData(
                at: url,
                byteLength: licenseText.byteLength,
                sha256: licenseText.sha256,
                mismatch: .assetIntegrityMismatch
            )
        }
        return VerifiedPack(
            manifest: manifest,
            fontURLsByRole: fontURLsByRole
        )
    }

    private static func validFontDeclaration(_ font: FontAsset) -> Bool {
        validFileDeclaration(
            fileName: font.fileName,
            byteLength: font.byteLength,
            sha256: font.sha256
        ) &&
            !font.role.isEmpty &&
            ["latinTrueTypeProfile", "cjkOpenTypeCFFProfile"].contains(font.tableProfile) &&
            !font.family.isEmpty &&
            ["Regular", "Bold"].contains(font.subfamily) &&
            !font.fullName.isEmpty &&
            !font.postScriptName.isEmpty &&
            !font.uniqueID.isEmpty &&
            !font.version.isEmpty &&
            [400, 700].contains(font.os2WeightClass) &&
            font.os2WidthClass == 5 &&
            font.os2Selection >= 0 && font.os2Selection <= 0xffff &&
            font.headMacStyle >= 0 && font.headMacStyle <= 0xffff &&
            font.italicAngle == 0 &&
            !font.mappedLocalizations.isEmpty &&
            Set(font.mappedLocalizations).count == font.mappedLocalizations.count
    }

    private static func validateCyrillicCoverageManifest(
        _ coverage: CyrillicCoverageManifest,
        against manifest: Manifest
    ) throws -> [String: [UInt32]] {
        let expectedLanguageTags: Set<String> = ["ru", "uk"]
        let expectedSequenceIDs: Set<String> = [
            "russian-alphabet",
            "ukrainian-alphabet"
        ]
        let languageTags = coverage.languageCoverage.map(\.languageTag)
        let sequenceIDs = coverage.languageCoverage.map(\.sequenceID)
        let baseFontsByRole = Dictionary(
            uniqueKeysWithValues: manifest.fonts.map { ($0.role, $0) }
        )

        guard coverage.schema == "ForgePlayFontCyrillicCoverageManifestV1",
              coverage.schemaVersion == 1,
              coverage.coverageID == "forgeplay-font-cyrillic-coverage-v1",
              coverage.sourcePackID == packID,
              coverage.activationScope == "native-process",
              coverage.uiLocalizationContract ==
                "glyph-coverage-only-no-russian-or-ukrainian-ui-localization",
              coverage.windowsPrefixContract == "separate-capability",
              Set(languageTags) == expectedLanguageTags,
              languageTags.count == expectedLanguageTags.count,
              Set(sequenceIDs) == expectedSequenceIDs,
              sequenceIDs.count == expectedSequenceIDs.count,
              coverage.languageCoverage.allSatisfy({ language in
                  let scalars = language.requiredCharacters.unicodeScalars.map(\.value)
                  return !scalars.isEmpty &&
                      Set(scalars).count == scalars.count &&
                      scalars.allSatisfy { (0x0400...0x052f).contains($0) }
              }),
              coverage.fontAssets.count == 2,
              Set(coverage.fontAssets.map(\.role)) == ["latin-regular", "latin-bold"],
              coverage.fontAssets.allSatisfy({ coverageFont in
                  guard let baseFont = baseFontsByRole[coverageFont.role] else {
                      return false
                  }
                  return coverageFont.fileName == baseFont.fileName &&
                      coverageFont.byteLength == baseFont.byteLength &&
                      coverageFont.sha256 == baseFont.sha256 &&
                      coverageFont.postScriptName == baseFont.postScriptName &&
                      Set(coverageFont.requiredSequenceIDs) == expectedSequenceIDs &&
                      coverageFont.requiredSequenceIDs.count == expectedSequenceIDs.count
              }) else {
            throw FontCompatibilityPackFailure.cyrillicCoverageInvalid
        }

        let sequencesByID = Dictionary(
            uniqueKeysWithValues: coverage.languageCoverage.map {
                ($0.sequenceID, $0.requiredCharacters.unicodeScalars.map(\.value))
            }
        )
        return Dictionary(
            uniqueKeysWithValues: coverage.fontAssets.map { font in
                let scalars = font.requiredSequenceIDs.flatMap {
                    sequencesByID[$0] ?? []
                }
                return (font.role, Array(Set(scalars)).sorted())
            }
        )
    }

    private static func fontSupports(_ requiredScalars: [UInt32], data: Data) -> Bool {
        guard !requiredScalars.isEmpty,
              requiredScalars.allSatisfy({ $0 <= UInt32(UInt16.max) }),
              let provider = CGDataProvider(data: data as CFData),
              let graphicsFont = CGFont(provider) else {
            return false
        }
        let font = CTFontCreateWithGraphicsFont(graphicsFont, 12, nil, nil)
        let characters = requiredScalars.map { UniChar($0) }
        var glyphs = Array(repeating: CGGlyph(0), count: characters.count)
        let mappedAllCharacters = characters.withUnsafeBufferPointer { characterBuffer in
            glyphs.withUnsafeMutableBufferPointer { glyphBuffer in
                guard let characterBaseAddress = characterBuffer.baseAddress,
                      let glyphBaseAddress = glyphBuffer.baseAddress else {
                    return false
                }
                return CTFontGetGlyphsForCharacters(
                    font,
                    characterBaseAddress,
                    glyphBaseAddress,
                    characterBuffer.count
                )
            }
        }
        return mappedAllCharacters && glyphs.allSatisfy { $0 != 0 }
    }

    private static func validLicenseDeclaration(_ license: LicenseTextAsset) -> Bool {
        validFileDeclaration(
            fileName: license.fileName,
            byteLength: license.byteLength,
            sha256: license.sha256
        ) &&
            !license.role.isEmpty &&
            !license.appliesToRoles.isEmpty &&
            Set(license.appliesToRoles).count == license.appliesToRoles.count
    }

    private static func validFileDeclaration(
        fileName: String,
        byteLength: Int,
        sha256: String
    ) -> Bool {
        !fileName.isEmpty &&
            fileName == URL(fileURLWithPath: fileName).lastPathComponent &&
            !fileName.contains("/") &&
            !fileName.contains("\\") &&
            byteLength > 0 &&
            sha256.count == 64 &&
            sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
    }

    private static func fontMetadataMatches(_ font: FontAsset, data: Data) -> Bool {
        guard let scalerType = uint32(in: data, at: 0),
              let os2 = tableRange(tag: "OS/2", in: data),
              let head = tableRange(tag: "head", in: data),
              let post = tableRange(tag: "post", in: data),
              let name = tableRange(tag: "name", in: data),
              let weightClass = uint16(in: data, at: os2.lowerBound + 4),
              let widthClass = uint16(in: data, at: os2.lowerBound + 6),
              let selection = uint16(in: data, at: os2.lowerBound + 62),
              let macStyle = uint16(in: data, at: head.lowerBound + 44),
              let italicAngleFixed = int32(in: data, at: post.lowerBound + 4),
              let familyNames = nameStrings(nameID: 1, table: name, data: data),
              let subfamilyNames = nameStrings(nameID: 2, table: name, data: data),
              let uniqueNames = nameStrings(nameID: 3, table: name, data: data),
              let fullNames = nameStrings(nameID: 4, table: name, data: data),
              let versionNames = nameStrings(nameID: 5, table: name, data: data),
              let postScriptNames = nameStrings(nameID: 6, table: name, data: data) else {
            return false
        }

        let profileMatches: Bool
        switch font.tableProfile {
        case "latinTrueTypeProfile":
            profileMatches = scalerType == 0x0001_0000 &&
                tableRange(tag: "glyf", in: data) != nil
        case "cjkOpenTypeCFFProfile":
            profileMatches = scalerType == 0x4f54_544f &&
                tableRange(tag: "CFF ", in: data) != nil
        default:
            profileMatches = false
        }

        return profileMatches &&
            weightClass == font.os2WeightClass &&
            widthClass == font.os2WidthClass &&
            selection == font.os2Selection &&
            macStyle == font.headMacStyle &&
            italicAngleFixed == Int32(font.italicAngle * 65_536) &&
            familyNames.contains(font.family) &&
            subfamilyNames.contains(font.subfamily) &&
            uniqueNames.contains(font.uniqueID) &&
            fullNames.contains(font.fullName) &&
            versionNames.contains(font.version) &&
            postScriptNames.contains(font.postScriptName)
    }

    private static func tableRange(tag: String, in data: Data) -> Range<Int>? {
        guard tag.utf8.count == 4,
              let tableCount = uint16(in: data, at: 4),
              tableCount > 0,
              tableCount <= 256 else {
            return nil
        }
        let expectedTag = Array(tag.utf8)
        let directoryStart = 12
        guard tableCount <= (data.count - min(data.count, directoryStart)) / 16 else {
            return nil
        }
        for index in 0..<tableCount {
            let recordOffset = directoryStart + index * 16
            guard recordOffset <= data.count - 16,
                  Array(data[recordOffset..<(recordOffset + 4)]) == expectedTag,
                  let rawOffset = uint32(in: data, at: recordOffset + 8),
                  let rawLength = uint32(in: data, at: recordOffset + 12),
                  let offset = Int(exactly: rawOffset),
                  let length = Int(exactly: rawLength),
                  offset <= data.count,
                  length <= data.count - offset else {
                continue
            }
            return offset..<(offset + length)
        }
        return nil
    }

    private static func nameStrings(
        nameID expectedNameID: Int,
        table: Range<Int>,
        data: Data
    ) -> Set<String>? {
        guard table.count >= 6,
              let recordCount = uint16(in: data, at: table.lowerBound + 2),
              let stringOffset = uint16(in: data, at: table.lowerBound + 4),
              recordCount <= (table.count - 6) / 12 else {
            return nil
        }
        let recordsStart = table.lowerBound + 6
        let stringsStart = table.lowerBound + stringOffset
        guard stringsStart >= recordsStart + recordCount * 12,
              stringsStart <= table.upperBound else {
            return nil
        }

        var values: Set<String> = []
        for index in 0..<recordCount {
            let recordOffset = recordsStart + index * 12
            guard let platformID = uint16(in: data, at: recordOffset),
                  let encodingID = uint16(in: data, at: recordOffset + 2),
                  let nameID = uint16(in: data, at: recordOffset + 6),
                  let length = uint16(in: data, at: recordOffset + 8),
                  let relativeOffset = uint16(in: data, at: recordOffset + 10),
                  nameID == expectedNameID else {
                continue
            }
            let valueStart = stringsStart + relativeOffset
            guard valueStart >= stringsStart,
                  valueStart <= table.upperBound,
                  length <= table.upperBound - valueStart else {
                return nil
            }
            let valueData = data.subdata(in: valueStart..<(valueStart + length))
            let value: String?
            if platformID == 0 ||
                (platformID == 3 && [0, 1, 10].contains(encodingID)) {
                value = String(data: valueData, encoding: .utf16BigEndian)
            } else if platformID == 1 && encodingID == 0 {
                value = String(data: valueData, encoding: .macOSRoman)
            } else {
                value = nil
            }
            if let value, !value.isEmpty {
                values.insert(value)
            }
        }
        return values.isEmpty ? nil : values
    }

    private static func uint16(in data: Data, at offset: Int) -> Int? {
        guard offset >= 0, offset <= data.count - 2 else { return nil }
        return (Int(data[offset]) << 8) | Int(data[offset + 1])
    }

    private static func uint32(in data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset <= data.count - 4 else { return nil }
        return (UInt32(data[offset]) << 24) |
            (UInt32(data[offset + 1]) << 16) |
            (UInt32(data[offset + 2]) << 8) |
            UInt32(data[offset + 3])
    }

    private static func int32(in data: Data, at offset: Int) -> Int32? {
        uint32(in: data, at: offset).map(Int32.init(bitPattern:))
    }

    private static func humanReadableNoticeURL(
        named fileName: String,
        under rootURL: URL
    ) -> URL? {
        let candidates = [
            rootURL
                .appending(path: "Legal", directoryHint: .isDirectory)
                .appending(path: fileName, directoryHint: .notDirectory),
            rootURL.appending(path: fileName, directoryHint: .notDirectory)
        ]
        return candidates.first(where: isRegularNonSymbolicFile)
    }

    private static func validateHumanReadableNotice(
        named fileName: String,
        licenseFileNames: [String],
        attributions: [CopyrightAttribution],
        under rootURL: URL
    ) throws {
        guard let url = humanReadableNoticeURL(named: fileName, under: rootURL),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              !data.isEmpty,
              data.count <= maximumHumanReadableNoticeBytes,
              let notice = String(data: data, encoding: .utf8),
              !notice.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw FontCompatibilityPackFailure.legalNoticeInvalid
        }
        let requiredFragments = [
            "## Noto Fonts in the Native App",
            "SIL Open Font License, Version 1.1"
        ] + licenseFileNames + attributions.map(\.notice)
        guard requiredFragments.allSatisfy(notice.contains) else {
            throw FontCompatibilityPackFailure.legalNoticeInvalid
        }
    }

    private static func resourceURL(named fileName: String, under rootURL: URL) -> URL? {
        let candidates = [
            rootURL
                .appending(path: "Fonts", directoryHint: .isDirectory)
                .appending(path: "ForgePlayNotoV1", directoryHint: .isDirectory)
                .appending(path: fileName, directoryHint: .notDirectory),
            rootURL.appending(path: fileName, directoryHint: .notDirectory)
        ]
        return candidates.first(where: isRegularNonSymbolicFile)
    }

    private static func isRegularNonSymbolicFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey
        ]) else {
            return false
        }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private static func exactData(
        at url: URL,
        byteLength: Int,
        sha256: String,
        mismatch: FontCompatibilityPackFailure
    ) throws -> Data {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw mismatch
        }
        guard data.count == byteLength,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == sha256 else {
            throw mismatch
        }
        return data
    }

    private static func supportedLocalization(_ identifier: String) throws -> String {
        let normalized = identifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        if normalized == "zh-hant" {
            return "zh-Hant"
        }
        if normalized == "zh-hans" {
            return "zh-Hans"
        }
        let supported = ["en", "ko", "de", "es", "fr", "ja"]
        if let match = supported.first(where: { normalized == $0 }) {
            return match
        }
        throw FontCompatibilityPackFailure.unsupportedLocalization
    }

    private static func registerFont(at url: URL) -> RegistrationResult {
        var unmanagedError: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &unmanagedError) {
            return RegistrationResult(succeeded: true, registeredByThisService: true)
        }
        guard let error = unmanagedError?.takeRetainedValue() else {
            return RegistrationResult(succeeded: false, registeredByThisService: false)
        }
        let isAlreadyRegistered = (CFErrorGetDomain(error) as String) ==
            (kCTFontManagerErrorDomain as String) &&
            CFErrorGetCode(error) == coreTextAlreadyRegisteredErrorCode
        return RegistrationResult(
            succeeded: isAlreadyRegistered,
            registeredByThisService: false
        )
    }

    private static func unregisterFont(at url: URL) -> Bool {
        var unmanagedError: Unmanaged<CFError>?
        let succeeded = CTFontManagerUnregisterFontsForURL(
            url as CFURL,
            .process,
            &unmanagedError
        )
        if let unmanagedError {
            _ = unmanagedError.takeRetainedValue()
        }
        return succeeded
    }
}
