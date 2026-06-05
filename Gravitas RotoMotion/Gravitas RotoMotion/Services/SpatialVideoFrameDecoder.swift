import AppKit
import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

@_silgen_name("CMVideoFormatDescriptionCopyTagCollectionArray")
private func bridgedCMVideoFormatDescriptionCopyTagCollectionArray(
    _ formatDescription: CMFormatDescription,
    _ tagCollectionsOut: UnsafeMutablePointer<CFArray?>
) -> OSStatus

struct SpatialVideoAssetProbeReport: Codable, CustomStringConvertible {
    var urlPath: String
    var trackCount: Int
    var selectedTrackIndex: Int?
    var naturalSize: String?
    var nominalFrameRate: Float?
    var mediaSubtypes: [String]
    var formatDescriptionExtensions: [String]
    var candidateLayerIDPairsTried: [[Int]]
    var sampleCountByCandidate: [String: Int]
    var taggedSampleCountByCandidate: [String: Int]
    var leftFrameCountByCandidate: [String: Int]
    var rightFrameCountByCandidate: [String: Int]
    var firstTagDescriptionsByCandidate: [String: [String]]
    var startReaderErrorByCandidate: [String: String]
    var discoveredLayerIDs: [Int]
    var eyeLayerMap: SpatialEyeLayerMap
    var diagnosticDefaultLayerProbe: SpatialLayerProbeResult?
    var selectedLayerIDs: [Int]?

    var description: String {
        let candidates = candidateLayerIDPairsTried.map { pair in
            let key = Self.key(for: pair)
            let errorText = startReaderErrorByCandidate[key]
                .map { ", startReaderError: \($0)" }
                ?? ""
            let tags = firstTagDescriptionsByCandidate[key] ?? []
            let tagsText = tags.isEmpty ? "" : ", tags: \(tags.joined(separator: " | "))"
            return "candidate \(key): samples \(sampleCountByCandidate[key] ?? 0), tagged \(taggedSampleCountByCandidate[key] ?? 0), left \(leftFrameCountByCandidate[key] ?? 0), right \(rightFrameCountByCandidate[key] ?? 0)\(errorText)\(tagsText)"
        }
        .joined(separator: "\n  ")

        let defaultProbeText = diagnosticDefaultLayerProbe
            .map { "\n  diagnostic default-layer probe: \($0.summary)" }
            ?? ""

        return """
        Spatial video probe report:
          url: \(urlPath)
          video track count: \(trackCount)
          selected track index: \(selectedTrackIndex.map(String.init) ?? "nil")
          natural size: \(naturalSize ?? "nil")
          nominal frame rate: \(nominalFrameRate.map { String(format: "%.3f", $0) } ?? "nil")
          media subtypes: \(mediaSubtypes.joined(separator: ", "))
          format description extensions:
          \(formatDescriptionExtensions.joined(separator: "\n"))
          discovered layer IDs: \(discoveredLayerIDs.map(String.init).joined(separator: ", "))
          eye layer map: left=\(eyeLayerMap.leftLayerID.map(String.init) ?? "nil"), right=\(eyeLayerMap.rightLayerID.map(String.init) ?? "nil")
          candidates:
          \(candidates.isEmpty ? "none" : candidates)
          \(defaultProbeText)
          selected layer IDs: \(selectedLayerIDs.map { "\($0)" } ?? "nil")
        """
    }

    static func key(for layerIDs: [Int]) -> String {
        "[\(layerIDs.map(String.init).joined(separator: ","))]"
    }
}

struct SpatialLayerProbeResult: Codable {
    let layerIDs: [Int]?
    let sampleCount: Int
    let taggedSampleCount: Int
    let leftCount: Int
    let rightCount: Int
    let firstTagDescriptions: [String]
    let startReaderError: String?

    var summary: String {
        let layerText = layerIDs
            .map { SpatialVideoAssetProbeReport.key(for: $0) }
            ?? "[default]"
        let errorText = startReaderError
            .map { ", startReaderError: \($0)" }
            ?? ""
        let tagsText = firstTagDescriptions.isEmpty
            ? ""
            : ", tags: \(firstTagDescriptions.joined(separator: " | "))"
        return "\(layerText): samples=\(sampleCount) tagged=\(taggedSampleCount) left=\(leftCount) right=\(rightCount)\(errorText)\(tagsText)"
    }
}

enum SpatialVideoDecodeError: LocalizedError {
    case noVideoTrack
    case cannotAddReaderOutput
    case cannotStartReader(Error?)
    case readerFailed(Error?)
    case noTaggedStereoBuffers(SpatialVideoAssetProbeReport)
    case noMatchingLayerIDs(
        discoveredIDs: [Int],
        probeResults: [SpatialLayerProbeResult],
        defaultProbe: SpatialLayerProbeResult?
    )
    case eyeAssignmentInverted(String)
    case noLeftEyeFrames(SpatialVideoAssetProbeReport)
    case noRightEyeFrames(SpatialVideoAssetProbeReport)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return "Spatial video has no video track."
        case .cannotAddReaderOutput:
            return "Cannot add spatial AVAssetReaderTrackOutput."
        case .cannotStartReader(let error):
            return "Spatial AVAssetReader failed to start: \(error?.localizedDescription ?? "unknown error")."
        case .readerFailed(let error):
            return "Spatial AVAssetReader failed: \(error?.localizedDescription ?? "unknown error")."
        case .noTaggedStereoBuffers(let report):
            return """
            No MV-HEVC tagged stereo buffers were decoded.
            \(report.description)
            """
        case .noMatchingLayerIDs(let discoveredIDs, let probeResults, let defaultProbe):
            let probeTable = probeResults
                .map { "  \($0.summary)" }
                .joined(separator: "\n")
            let defaultText = defaultProbe
                .map { "\nDiagnostic no-layer request:\n  \($0.summary)" }
                ?? "\nDiagnostic no-layer request: not run"

            return """
            No requested MV-HEVC layer ID pair matched this file.

            Discovered layer IDs from format description: \(discoveredIDs.map(String.init).joined(separator: ", "))
            Candidate probes:
            \(probeTable.isEmpty ? "  none" : probeTable)
            \(defaultText)
            """
        case .eyeAssignmentInverted(let message):
            return "Spatial eye assignment failed: \(message)"
        case .noLeftEyeFrames(let report):
            return """
            Spatial decode produced no left-eye frames.
            \(report.description)
            """
        case .noRightEyeFrames(let report):
            return """
            Spatial decode produced no right-eye frames.
            \(report.description)
            """
        }
    }
}

enum SpatialVideoAssetProbe {
    static func inspect(
        asset: AVURLAsset
    ) async throws -> SpatialVideoAssetProbeReport {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        var mediaSubtypes: [String] = []
        var extensionDescriptions: [String] = []
        var selectedTrackIndex: Int?
        var naturalSize: String?
        var nominalFrameRate: Float?

        for (index, track) in tracks.enumerated() {
            if selectedTrackIndex == nil {
                selectedTrackIndex = index
                let size = try await track.load(.naturalSize)
                naturalSize = "\(size.width)x\(size.height)"
                nominalFrameRate = try await track.load(.nominalFrameRate)
            }

            let formatDescriptions = try await track.load(.formatDescriptions)
            for (formatIndex, formatDescription) in formatDescriptions.enumerated() {
                let subtype = CMFormatDescriptionGetMediaSubType(formatDescription)
                mediaSubtypes.append(fourCharCodeString(subtype))
                extensionDescriptions.append(
                    formatDescriptionSummary(
                        formatDescription,
                        trackIndex: index,
                        formatIndex: formatIndex
                    )
                )

                if let tagCollections = copyTagCollections(from: formatDescription) {
                    extensionDescriptions.append(
                        """
                        track \(index) tag collections:
                        \(tagCollections)
                        """
                    )
                }
            }
        }

        return SpatialVideoAssetProbeReport(
            urlPath: asset.url.path,
            trackCount: tracks.count,
            selectedTrackIndex: selectedTrackIndex,
            naturalSize: naturalSize,
            nominalFrameRate: nominalFrameRate,
            mediaSubtypes: mediaSubtypes,
            formatDescriptionExtensions: extensionDescriptions,
            candidateLayerIDPairsTried: [],
            sampleCountByCandidate: [:],
            taggedSampleCountByCandidate: [:],
            leftFrameCountByCandidate: [:],
            rightFrameCountByCandidate: [:],
            firstTagDescriptionsByCandidate: [:],
            startReaderErrorByCandidate: [:],
            discoveredLayerIDs: [],
            eyeLayerMap: .empty,
            diagnosticDefaultLayerProbe: nil,
            selectedLayerIDs: nil
        )
    }

    static func findLayerIDsInFormatDescription(
        _ formatDescription: CMFormatDescription
    ) -> [Int] {
        let extensions = extensionDictionary(from: formatDescription)
        var ids: Set<Int> = []

        func scan(_ value: Any, path: String) {
            let pathLower = path.lowercased()

            if let number = value as? NSNumber,
               !pathLower.contains("fieldofview"),
               pathLower.contains("layer") ||
               pathLower.contains("viewid") ||
               pathLower.contains("viewids") ||
               pathLower.contains("view id") {
                ids.insert(number.intValue)
                return
            }

            if let array = value as? [Any] {
                for (index, item) in array.enumerated() {
                    scan(item, path: "\(path)[\(index)]")
                }
                return
            }

            if let nsArray = value as? NSArray {
                for (index, item) in nsArray.enumerated() {
                    scan(item, path: "\(path)[\(index)]")
                }
                return
            }

            if let dictionary = value as? [String: Any] {
                for (key, item) in dictionary {
                    scan(item, path: "\(path).\(key)")
                }
                return
            }

            if let nsDictionary = value as? NSDictionary {
                for (key, item) in nsDictionary {
                    scan(item, path: "\(path).\(String(describing: key))")
                }
            }
        }

        scan(extensions, path: "extensions")
        return Array(ids).sorted()
    }

    static func eyeLayerMap(
        in formatDescriptions: [CMFormatDescription]
    ) -> SpatialEyeLayerMap {
        var leftLayerID: Int?
        var rightLayerID: Int?

        for formatDescription in formatDescriptions {
            guard let tagCollections = copyTagCollections(from: formatDescription) else {
                continue
            }

            let map = eyeLayerMap(fromTagCollectionDescription: tagCollections)
            leftLayerID = leftLayerID ?? map.leftLayerID
            rightLayerID = rightLayerID ?? map.rightLayerID
        }

        if leftLayerID != nil || rightLayerID != nil {
            print("""
            Spatial eye layer map parsed from track tag collections:
              leftLayerID: \(leftLayerID.map(String.init) ?? "nil")
              rightLayerID: \(rightLayerID.map(String.init) ?? "nil")
              source: printable CMTagCollection eyes/vlay fallback
            """)
        }

        return SpatialEyeLayerMap(
            leftLayerID: leftLayerID,
            rightLayerID: rightLayerID
        )
    }

    private static func eyeLayerMap(
        fromTagCollectionDescription description: String
    ) -> SpatialEyeLayerMap {
        var leftLayerID: Int?
        var rightLayerID: Int?
        let normalized = description
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")

        let chunks = normalized
            .split(separator: "{")
            .map(String.init)

        for chunk in chunks {
            guard chunk.contains("category:'eyes'"),
                  chunk.contains("category:'vlay'"),
                  let eyeValue = tagValue(
                    forCategory: "eyes",
                    in: chunk
                  ),
                  let layerID = tagValue(
                    forCategory: "vlay",
                    in: chunk
                  ) else {
                continue
            }

            switch eyeValue {
            case 0x1:
                leftLayerID = layerID
            case 0x2:
                rightLayerID = layerID
            default:
                continue
            }
        }

        return SpatialEyeLayerMap(
            leftLayerID: leftLayerID,
            rightLayerID: rightLayerID
        )
    }

    private static func tagValue(
        forCategory category: String,
        in text: String
    ) -> Int? {
        guard let categoryRange = text.range(of: "category:'\(category)'"),
              let valueRange = text[categoryRange.upperBound...].range(of: "value:") else {
            return nil
        }

        let afterValue = text[valueRange.upperBound...]
        let token = afterValue
            .split(whereSeparator: { $0 == " " || $0 == "," || $0 == "}" || $0 == ")" })
            .first
            .map(String.init)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "{}(),"))

        guard let token else {
            return nil
        }

        if token.lowercased().hasPrefix("0x") {
            return Int(token.dropFirst(2), radix: 16)
        }

        return Int(token)
    }

    private static func copyTagCollections(
        from formatDescription: CMFormatDescription
    ) -> String? {
        var tagCollections: CFArray?
        let status = bridgedCMVideoFormatDescriptionCopyTagCollectionArray(
            formatDescription,
            &tagCollections
        )

        guard status == noErr,
              let tagCollections else {
            return nil
        }

        return String(describing: tagCollections)
    }

    private static func formatDescriptionSummary(
        _ formatDescription: CMFormatDescription,
        trackIndex: Int,
        formatIndex: Int
    ) -> String {
        let subtype = CMFormatDescriptionGetMediaSubType(formatDescription)
        let extensions = extensionDictionary(from: formatDescription)

        let extensionLines = extensions.keys.sorted().map { key in
            "    \(key): \(String(describing: extensions[key] ?? ""))"
        }

        return """
        track \(trackIndex) format \(formatIndex):
          media subtype: \(fourCharCodeString(subtype))
          extension keys: \(extensions.keys.sorted().joined(separator: ", "))
          extension values:
        \(extensionLines.isEmpty ? "    none" : extensionLines.joined(separator: "\n"))
        """
    }

    private static func extensionDictionary(
        from formatDescription: CMFormatDescription
    ) -> [String: Any] {
        guard let extensions = CMFormatDescriptionGetExtensions(formatDescription) as NSDictionary? else {
            return [:]
        }

        var result: [String: Any] = [:]
        for (key, value) in extensions {
            result[String(describing: key)] = value
        }
        return result
    }
}

enum SpatialTaggedBufferExtractor {
    struct EyeBuffer {
        let pixelBuffer: CVPixelBuffer
        let layerIDs: [Int]
        let viewIDs: [Int]
        let semanticEye: StereoEye?
        let tagDescriptions: [String]
    }

    struct ExtractedEyes {
        let left: EyeBuffer?
        let right: EyeBuffer?
        let taggedBufferCount: Int
        let tagDescriptions: [String]
    }

    static func extractEyes(
        from sampleBuffer: CMSampleBuffer,
        requestedLayerIDs: [Int]?,
        eyeLayerMap: SpatialEyeLayerMap
    ) -> ExtractedEyes {
        var left: CVPixelBuffer?
        var right: CVPixelBuffer?
        var leftLayerIDs: [Int] = []
        var rightLayerIDs: [Int] = []
        var leftViewIDs: [Int] = []
        var rightViewIDs: [Int] = []
        var leftSemanticEye: StereoEye?
        var rightSemanticEye: StereoEye?
        var leftTagDescriptions: [String] = []
        var rightTagDescriptions: [String] = []
        var descriptions: [String] = []

        guard let taggedBuffers = sampleBuffer.taggedBuffers else {
            return ExtractedEyes(
                left: nil,
                right: nil,
                taggedBufferCount: 0,
                tagDescriptions: []
            )
        }

        for taggedBuffer in taggedBuffers {
            let tags = taggedBuffer.tags
            let tagDescriptions = tags.map(String.init(describing:))
            descriptions.append(tagDescriptions.joined(separator: ", "))

            guard let pixelBuffer = pixelBuffer(from: taggedBuffer) else {
                continue
            }

            let layerIDs = layerIDs(from: tags)
            let viewIDs = viewIDs(from: tags)
            let semanticEye = semanticEye(from: tags)

            if semanticEye == .left {
                left = pixelBuffer
                leftLayerIDs = layerIDs
                leftViewIDs = viewIDs
                leftSemanticEye = semanticEye
                leftTagDescriptions = tagDescriptions
            } else if semanticEye == .right {
                right = pixelBuffer
                rightLayerIDs = layerIDs
                rightViewIDs = viewIDs
                rightSemanticEye = semanticEye
                rightTagDescriptions = tagDescriptions
            } else if let leftLayerID = eyeLayerMap.leftLayerID,
                      layerIDs.contains(leftLayerID) {
                left = pixelBuffer
                leftLayerIDs = layerIDs
                leftViewIDs = viewIDs
                leftSemanticEye = semanticEye
                leftTagDescriptions = tagDescriptions
            } else if let rightLayerID = eyeLayerMap.rightLayerID,
                      layerIDs.contains(rightLayerID) {
                right = pixelBuffer
                rightLayerIDs = layerIDs
                rightViewIDs = viewIDs
                rightSemanticEye = semanticEye
                rightTagDescriptions = tagDescriptions
            }
        }

        return ExtractedEyes(
            left: left.map {
                EyeBuffer(
                    pixelBuffer: $0,
                    layerIDs: leftLayerIDs,
                    viewIDs: leftViewIDs,
                    semanticEye: leftSemanticEye,
                    tagDescriptions: leftTagDescriptions
                )
            },
            right: right.map {
                EyeBuffer(
                    pixelBuffer: $0,
                    layerIDs: rightLayerIDs,
                    viewIDs: rightViewIDs,
                    semanticEye: rightSemanticEye,
                    tagDescriptions: rightTagDescriptions
                )
            },
            taggedBufferCount: taggedBuffers.count,
            tagDescriptions: descriptions
        )
    }

    private static func pixelBuffer(
        from taggedBuffer: CMTaggedBuffer
    ) -> CVPixelBuffer? {
        switch taggedBuffer.buffer {
        case .pixelBuffer(let pixelBuffer):
            return pixelBuffer
        default:
            return nil
        }
    }

    private static func layerIDs(
        from tags: [CMTag]
    ) -> [Int] {
        uniqueIDs(
            tags
                .map(String.init(describing:))
                .filter { $0.contains("category:'vlay'") }
                .compactMap(intValueFromTagDescription)
        )
    }

    private static func viewIDs(
        from tags: [CMTag]
    ) -> [Int] {
        var ids: [Int] = []

        ids += tags
            .map(String.init(describing:))
            .filter { $0.contains("category:'eyes'") }
            .compactMap(intValueFromTagDescription)

        if tags.contains(.stereoView(.leftEye)) {
            ids.append(1)
        }

        if tags.contains(.stereoView(.rightEye)) {
            ids.append(2)
        }

        ids += tags
            .map(String.init(describing:))
            .filter { $0.lowercased().contains("view") }
            .compactMap(intValueFromTagDescription)

        return uniqueIDs(ids)
    }

    private static func semanticEye(
        from tags: [CMTag]
    ) -> StereoEye? {
        let eyeValues = tags
            .map(String.init(describing:))
            .filter { $0.contains("category:'eyes'") }
            .compactMap(intValueFromTagDescription)

        if eyeValues.contains(0x1) {
            return .left
        }

        if eyeValues.contains(0x2) {
            return .right
        }

        if tags.contains(.stereoView(.leftEye)) {
            return .left
        }

        if tags.contains(.stereoView(.rightEye)) {
            return .right
        }

        return nil
    }

    private static func intValueFromTagDescription(
        _ description: String
    ) -> Int? {
        guard let valueRange = description.range(of: "value:") else {
            return nil
        }

        let afterValue = description[valueRange.upperBound...]
        let token = afterValue
            .split(separator: " ")
            .first
            .map(String.init)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "{}"))

        guard let token else {
            return nil
        }

        if token.lowercased().hasPrefix("0x") {
            return Int(token.dropFirst(2), radix: 16)
        }

        return Int(token)
    }

    private static func uniqueIDs(
        _ values: [Int]
    ) -> [Int] {
        Array(Set(values)).sorted()
    }
}

enum SpatialVideoFrameDecoder {
    static func decodeLeftRightFrames(
        url: URL,
        maxFrames: Int = 0,
        maximumImageDimension: CGFloat = 1280,
        metadataOverride: SpatialVideoCameraMetadata? = nil
    ) async throws -> SpatialDecodedFrames {
        if #unavailable(macOS 14.0) {
            throw NSError(
                domain: "GravitasRotoMotion",
                code: 7301,
                userInfo: [NSLocalizedDescriptionKey: "MV-HEVC tagged-buffer decoding requires macOS 14 or newer."]
            )
        }

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)
        let tracks = try await asset.loadTracks(withMediaType: .video)

        guard let track = tracks.first else {
            throw SpatialVideoDecodeError.noVideoTrack
        }

        var report = try await SpatialVideoAssetProbe.inspect(asset: asset)
        print("""
        Spatial video format-description probe before MV-HEVC reader setup:
        \(report.description)
        """)

        var metadata = try await SpatialVideoMetadataReader.readMetadata(url: url)
        if let metadataOverride {
            metadata.baselineMeters = metadataOverride.baselineMeters ?? metadata.baselineMeters
            metadata.horizontalFOVDegrees = metadataOverride.horizontalFOVDegrees ?? metadata.horizontalFOVDegrees
            metadata.verticalFOVDegrees = metadataOverride.verticalFOVDegrees ?? metadata.verticalFOVDegrees
            metadata.disparityAdjustment = metadataOverride.disparityAdjustment ?? metadata.disparityAdjustment
        }

        let nominalFPS = Double(try await track.load(.nominalFrameRate))
        let formatDescriptions = try await track.load(.formatDescriptions)
        let eyeLayerMap = SpatialVideoAssetProbe.eyeLayerMap(
            in: formatDescriptions
        )
        let discoveredLayerIDs = Array(
            Set(
                formatDescriptions.flatMap {
                    SpatialVideoAssetProbe.findLayerIDsInFormatDescription($0)
                }
                + [
                    eyeLayerMap.leftLayerID,
                    eyeLayerMap.rightLayerID
                ].compactMap { $0 }
            )
        )
        .sorted()

        report.discoveredLayerIDs = discoveredLayerIDs
        report.eyeLayerMap = eyeLayerMap

        var candidateLayerIDPairs: [[Int]] = []

        if let leftLayerID = eyeLayerMap.leftLayerID,
           let rightLayerID = eyeLayerMap.rightLayerID {
            candidateLayerIDPairs.append([leftLayerID, rightLayerID])
            candidateLayerIDPairs.append([rightLayerID, leftLayerID])
            candidateLayerIDPairs.append(
                Array(Set([leftLayerID, rightLayerID])).sorted()
            )
        }

        if discoveredLayerIDs.count >= 2 {
            for i in 0..<discoveredLayerIDs.count {
                for j in 0..<discoveredLayerIDs.count where j != i {
                    candidateLayerIDPairs.append([
                        discoveredLayerIDs[i],
                        discoveredLayerIDs[j]
                    ])
                }
            }
        }

        candidateLayerIDPairs += [
            [0, 1],
            [1, 0],
            [1, 2],
            [2, 1],
            [0, 2],
            [2, 0]
        ]

        var seenCandidateKeys: Set<String> = []
        candidateLayerIDPairs = candidateLayerIDPairs.filter { ids in
            let key = SpatialVideoAssetProbeReport.key(for: ids)
            guard !seenCandidateKeys.contains(key) else {
                return false
            }

            seenCandidateKeys.insert(key)
            return true
        }

        var probeResults: [SpatialLayerProbeResult] = []
        var selectedProbe: SpatialLayerProbeResult?
        var triedLayerIDPairs: [[Int]] = []

        for pair in candidateLayerIDPairs {
            triedLayerIDPairs.append(pair)
            let probe: SpatialLayerProbeResult

            do {
                probe = try await probeLayerPair(
                    asset: asset,
                    videoTrack: track,
                    layerIDs: pair,
                    eyeLayerMap: eyeLayerMap,
                    maxSamples: 10
                )
            } catch {
                probe = SpatialLayerProbeResult(
                    layerIDs: pair,
                    sampleCount: 0,
                    taggedSampleCount: 0,
                    leftCount: 0,
                    rightCount: 0,
                    firstTagDescriptions: [],
                    startReaderError: error.localizedDescription
                )
            }
            probeResults.append(probe)

            if probe.leftCount > 0 && probe.rightCount > 0 {
                selectedProbe = probe
                break
            }
        }

        var diagnosticDefaultProbe: SpatialLayerProbeResult?
        if selectedProbe == nil {
            do {
                diagnosticDefaultProbe = try await probeLayerPair(
                    asset: asset,
                    videoTrack: track,
                    layerIDs: nil,
                    eyeLayerMap: eyeLayerMap,
                    maxSamples: 10
                )
            } catch {
                diagnosticDefaultProbe = SpatialLayerProbeResult(
                    layerIDs: nil,
                    sampleCount: 0,
                    taggedSampleCount: 0,
                    leftCount: 0,
                    rightCount: 0,
                    firstTagDescriptions: [],
                    startReaderError: error.localizedDescription
                )
            }

            if let diagnosticDefaultProbe,
               diagnosticDefaultProbe.leftCount > 0,
               diagnosticDefaultProbe.rightCount > 0 {
                selectedProbe = diagnosticDefaultProbe
            }
        }

        report.candidateLayerIDPairsTried = triedLayerIDPairs
        report.diagnosticDefaultLayerProbe = diagnosticDefaultProbe
        for probe in probeResults {
            guard let layerIDs = probe.layerIDs else {
                continue
            }

            let key = SpatialVideoAssetProbeReport.key(for: layerIDs)
            report.sampleCountByCandidate[key] = probe.sampleCount
            report.taggedSampleCountByCandidate[key] = probe.taggedSampleCount
            report.leftFrameCountByCandidate[key] = probe.leftCount
            report.rightFrameCountByCandidate[key] = probe.rightCount
            report.firstTagDescriptionsByCandidate[key] = probe.firstTagDescriptions
            if let startReaderError = probe.startReaderError {
                report.startReaderErrorByCandidate[key] = startReaderError
            }
        }

        guard let selectedProbe else {
            print(
                """
                Spatial video decode FAILED:
                  no fallback: true
                  active UI assignment: skipped
                \(report.description)
                """
            )
            throw SpatialVideoDecodeError.noMatchingLayerIDs(
                discoveredIDs: discoveredLayerIDs,
                probeResults: probeResults,
                defaultProbe: diagnosticDefaultProbe
            )
        }

        report.selectedLayerIDs = selectedProbe.layerIDs

        if let layerIDs = selectedProbe.layerIDs {
            print("""
            Spatial decode selected MV-HEVC layer IDs:
              requestedLayerIDs: \(layerIDs)
              semanticLeftLayerID: \(eyeLayerMap.leftLayerID.map(String.init) ?? "nil")
              semanticRightLayerID: \(eyeLayerMap.rightLayerID.map(String.init) ?? "nil")
            """)
        } else {
            print("""
            Spatial decode selected default MV-HEVC tagged output:
              requestedLayerIDs: none
            """)
        }

        let decoded = try await decodeFrames(
            asset: asset,
            videoTrack: track,
            layerIDs: selectedProbe.layerIDs,
            eyeLayerMap: eyeLayerMap,
            maxFrames: maxFrames,
            maximumImageDimension: maximumImageDimension,
            preferredTransform: try await track.load(.preferredTransform),
            cleanAperture: cleanAperture(from: formatDescriptions.first)
        )

        guard !decoded.leftFrames.isEmpty else {
            throw SpatialVideoDecodeError.noLeftEyeFrames(report)
        }

        guard !decoded.rightFrames.isEmpty else {
            throw SpatialVideoDecodeError.noRightEyeFrames(report)
        }

        if let firstDiagnostic = decoded.stereoDiagnostics.leftFrames.first?.diagnostic {
            metadata.imageWidth = max(firstDiagnostic.pixelWidth, 1)
            metadata.imageHeight = max(firstDiagnostic.pixelHeight, 1)
            print("""
            Spatial metadata image size corrected from decoded left-eye pixel buffer:
              imageWidth: \(metadata.imageWidth)
              imageHeight: \(metadata.imageHeight)
              source: decodedPixelBufferSize
            """)
        }

        print(
            """
            Spatial video decode SUCCESS:
              selectedLayerIDs: \(selectedProbe.layerIDs.map { "\($0)" } ?? "default")
              semanticLeftLayerID: \(eyeLayerMap.leftLayerID.map(String.init) ?? "nil")
              semanticRightLayerID: \(eyeLayerMap.rightLayerID.map(String.init) ?? "nil")
              sampleCount: \(decoded.sampleCount)
              taggedSampleCount: \(decoded.taggedSampleCount)
              leftFrames: \(decoded.leftFrames.count)
              rightFrames: \(decoded.rightFrames.count)
              firstTags: \(selectedProbe.firstTagDescriptions)
            """
        )

        return SpatialDecodedFrames(
            leftFrames: decoded.leftFrames,
            rightFrames: decoded.rightFrames,
            fps: nominalFPS.isFinite && nominalFPS > 0 ? nominalFPS : estimatedFPS(frames: decoded.leftFrames),
            duration: durationSeconds.isFinite ? durationSeconds : 0,
            metadata: metadata,
            stereoDiagnostics: decoded.stereoDiagnostics
        )
    }

    static func probeLayerPair(
        asset: AVURLAsset,
        videoTrack: AVAssetTrack,
        layerIDs: [Int]?,
        eyeLayerMap: SpatialEyeLayerMap,
        maxSamples: Int = 10
    ) async throws -> SpatialLayerProbeResult {
        let reader = try AVAssetReader(asset: asset)
        let output = makeTrackOutput(
            videoTrack: videoTrack,
            layerIDs: layerIDs
        )

        guard reader.canAdd(output) else {
            throw SpatialVideoDecodeError.cannotAddReaderOutput
        }

        reader.add(output)

        guard reader.startReading() else {
            throw SpatialVideoDecodeError.cannotStartReader(reader.error)
        }

        var sampleCount = 0
        var taggedSampleCount = 0
        var leftCount = 0
        var rightCount = 0
        var firstTagDescriptions: [String] = []

        while reader.status == .reading, sampleCount < maxSamples {
            guard let sampleBuffer = output.copyNextSampleBuffer() else {
                break
            }

            sampleCount += 1

            let eyes = SpatialTaggedBufferExtractor.extractEyes(
                from: sampleBuffer,
                requestedLayerIDs: layerIDs,
                eyeLayerMap: eyeLayerMap
            )

            if eyes.taggedBufferCount > 0 {
                taggedSampleCount += 1
            }

            if firstTagDescriptions.isEmpty, !eyes.tagDescriptions.isEmpty {
                firstTagDescriptions = eyes.tagDescriptions
            }

            if eyes.left != nil {
                leftCount += 1
            }

            if eyes.right != nil {
                rightCount += 1
            }
        }

        reader.cancelReading()

        if reader.status == .failed {
            throw SpatialVideoDecodeError.readerFailed(reader.error)
        }

        return SpatialLayerProbeResult(
            layerIDs: layerIDs,
            sampleCount: sampleCount,
            taggedSampleCount: taggedSampleCount,
            leftCount: leftCount,
            rightCount: rightCount,
            firstTagDescriptions: firstTagDescriptions,
            startReaderError: nil
        )
    }

    private static func decodeFrames(
        asset: AVURLAsset,
        videoTrack: AVAssetTrack,
        layerIDs: [Int]?,
        eyeLayerMap: SpatialEyeLayerMap,
        maxFrames: Int,
        maximumImageDimension: CGFloat,
        preferredTransform: CGAffineTransform,
        cleanAperture: CGSize?
    ) async throws -> (
        leftFrames: [VideoFrame],
        rightFrames: [VideoFrame],
        stereoDiagnostics: SpatialStereoDecodeResult,
        sampleCount: Int,
        taggedSampleCount: Int
    ) {
        let reader = try AVAssetReader(asset: asset)
        let output = makeTrackOutput(
            videoTrack: videoTrack,
            layerIDs: layerIDs
        )

        guard reader.canAdd(output) else {
            throw SpatialVideoDecodeError.cannotAddReaderOutput
        }

        reader.add(output)

        guard reader.startReading() else {
            throw SpatialVideoDecodeError.cannotStartReader(reader.error)
        }

        let converter = SpatialEyeImageConverter()
        let dumper = SpatialVideoDiagnosticDumper()
        let dumpDirectory = try dumper.makeDumpDirectory()
        var leftFrames: [VideoFrame] = []
        var rightFrames: [VideoFrame] = []
        var leftDiagnosticFrames: [SpatialDecodedEyeFrame] = []
        var rightDiagnosticFrames: [SpatialDecodedEyeFrame] = []
        var diagnostics: [SpatialEyeFrameDiagnostic] = []
        var frameIndex = 0
        var sampleCount = 0
        var taggedSampleCount = 0

        while reader.status == .reading {
            guard let sampleBuffer = output.copyNextSampleBuffer() else {
                break
            }

            sampleCount += 1

            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let timeSeconds = CMTimeGetSeconds(pts)

            guard timeSeconds.isFinite else {
                continue
            }

            let eyes = SpatialTaggedBufferExtractor.extractEyes(
                from: sampleBuffer,
                requestedLayerIDs: layerIDs,
                eyeLayerMap: eyeLayerMap
            )

            if eyes.taggedBufferCount > 0 {
                taggedSampleCount += 1
            }

            guard let leftEye = eyes.left,
                  let rightEye = eyes.right else {
                continue
            }

            if frameIndex == 0 {
                try validateEyeAssignment(
                    leftEye: leftEye,
                    rightEye: rightEye
                )
                logEyeAssignment(
                    leftEye: leftEye,
                    rightEye: rightEye
                )
            }

            let leftConverted = try converter.makeCGImage(
                from: leftEye.pixelBuffer,
                preferredTransform: preferredTransform
            )
            let rightConverted = try converter.makeCGImage(
                from: rightEye.pixelBuffer,
                preferredTransform: preferredTransform
            )

            let leftImage = makeImage(
                from: leftConverted.cgImage,
                maximumImageDimension: maximumImageDimension
            )
            let rightImage = makeImage(
                from: rightConverted.cgImage,
                maximumImageDimension: maximumImageDimension
            )

            leftFrames.append(
                VideoFrame(
                    id: frameIndex,
                    frameIndex: frameIndex,
                    timeSeconds: timeSeconds,
                    image: leftImage,
                    pixelBuffer: leftEye.pixelBuffer
                )
            )

            rightFrames.append(
                VideoFrame(
                    id: frameIndex,
                    frameIndex: frameIndex,
                    timeSeconds: timeSeconds,
                    image: rightImage,
                    pixelBuffer: rightEye.pixelBuffer
                )
            )

            let shouldDumpLeft = leftDiagnosticFrames.count < 5
            let decodedLeftEyeFrame = try makeDecodedEyeFrame(
                eye: .left,
                frameIndex: frameIndex,
                presentationTime: pts,
                eyeBuffer: leftEye,
                converted: leftConverted,
                preferredTransform: preferredTransform,
                cleanAperture: cleanAperture,
                dumpDirectory: dumpDirectory,
                dumper: dumper,
                dumpPNG: shouldDumpLeft
            )
            leftDiagnosticFrames.append(decodedLeftEyeFrame)

            if shouldDumpLeft {
                let decodedEyeFrame = decodedLeftEyeFrame
                diagnostics.append(decodedEyeFrame.diagnostic)
                logTaggedBufferSelection(decodedEyeFrame.diagnostic)
            }

            let shouldDumpRight = rightDiagnosticFrames.count < 5
            let decodedRightEyeFrame = try makeDecodedEyeFrame(
                eye: .right,
                frameIndex: frameIndex,
                presentationTime: pts,
                eyeBuffer: rightEye,
                converted: rightConverted,
                preferredTransform: preferredTransform,
                cleanAperture: cleanAperture,
                dumpDirectory: dumpDirectory,
                dumper: dumper,
                dumpPNG: shouldDumpRight
            )
            rightDiagnosticFrames.append(decodedRightEyeFrame)

            if shouldDumpRight {
                let decodedEyeFrame = decodedRightEyeFrame
                diagnostics.append(decodedEyeFrame.diagnostic)
                logTaggedBufferSelection(decodedEyeFrame.diagnostic)
            }

            frameIndex += 1

            if maxFrames > 0 && leftFrames.count >= maxFrames {
                break
            }
        }

        if reader.status == .failed {
            throw SpatialVideoDecodeError.readerFailed(reader.error)
        }

        return (
            leftFrames: leftFrames,
            rightFrames: rightFrames,
            stereoDiagnostics: SpatialStereoDecodeResult(
                leftFrames: leftDiagnosticFrames,
                rightFrames: rightDiagnosticFrames,
                diagnostics: diagnostics,
                dumpDirectory: dumpDirectory
            ),
            sampleCount: sampleCount,
            taggedSampleCount: taggedSampleCount
        )
    }

    private static func makeTrackOutput(
        videoTrack: AVAssetTrack,
        layerIDs: [Int]?
    ) -> AVAssetReaderTrackOutput {
        var decompressionProperties: [String: Any] = [:]

        if let layerIDs {
            decompressionProperties[
                kVTDecompressionPropertyKey_RequestedMVHEVCVideoLayerIDs as String
            ] = layerIDs
        }

        var outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]

        if !decompressionProperties.isEmpty {
            outputSettings[AVVideoDecompressionPropertiesKey] = decompressionProperties
        }

        let output = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: outputSettings
        )
        output.alwaysCopiesSampleData = false
        return output
    }

    private static func makeDecodedEyeFrame(
        eye: StereoEye,
        frameIndex: Int,
        presentationTime: CMTime,
        eyeBuffer: SpatialTaggedBufferExtractor.EyeBuffer,
        converted: (cgImage: CGImage, ciExtent: CGRect),
        preferredTransform: CGAffineTransform,
        cleanAperture: CGSize?,
        dumpDirectory: URL,
        dumper: SpatialVideoDiagnosticDumper,
        dumpPNG: Bool
    ) throws -> SpatialDecodedEyeFrame {
        let pngURL: URL?

        if dumpPNG {
            let url = dumpDirectory.appendingPathComponent(
                "frame_\(String(format: "%03d", frameIndex))_\(eye.rawValue).png"
            )
            try dumper.writePNG(converted.cgImage, to: url)
            pngURL = url
        } else {
            pngURL = nil
        }

        let diagnostic = SpatialEyeFrameDiagnostic(
            eye: eye,
            frameIndex: frameIndex,
            presentationTimeSeconds: CMTimeGetSeconds(presentationTime),
            layerIDs: eyeBuffer.layerIDs,
            viewIDs: eyeBuffer.viewIDs,
            pixelWidth: CVPixelBufferGetWidth(eyeBuffer.pixelBuffer),
            pixelHeight: CVPixelBufferGetHeight(eyeBuffer.pixelBuffer),
            pixelFormat: pixelFormatName(eyeBuffer.pixelBuffer),
            ciExtentX: Double(converted.ciExtent.origin.x),
            ciExtentY: Double(converted.ciExtent.origin.y),
            ciExtentWidth: Double(converted.ciExtent.width),
            ciExtentHeight: Double(converted.ciExtent.height),
            cgImageWidth: converted.cgImage.width,
            cgImageHeight: converted.cgImage.height,
            preferredTransformA: Double(preferredTransform.a),
            preferredTransformB: Double(preferredTransform.b),
            preferredTransformC: Double(preferredTransform.c),
            preferredTransformD: Double(preferredTransform.d),
            preferredTransformTX: Double(preferredTransform.tx),
            preferredTransformTY: Double(preferredTransform.ty),
            cleanApertureWidth: cleanAperture.map { Double($0.width) },
            cleanApertureHeight: cleanAperture.map { Double($0.height) },
            pngPath: pngURL?.path
        )

        return SpatialDecodedEyeFrame(
            eye: eye,
            frameIndex: frameIndex,
            presentationTime: presentationTime,
            cgImage: converted.cgImage,
            diagnostic: diagnostic
        )
    }

    private static func logTaggedBufferSelection(
        _ diagnostic: SpatialEyeFrameDiagnostic
    ) {
        print("""
        [SpatialStereoDecode]
          frame: \(diagnostic.frameIndex)
          time: \(String(format: "%.6f", diagnostic.presentationTimeSeconds))
          eye: \(diagnostic.eye.rawValue)
          layerIDs: \(diagnostic.layerIDs)
          viewIDs: \(diagnostic.viewIDs)
          pixel: \(diagnostic.pixelWidth)x\(diagnostic.pixelHeight) \(diagnostic.pixelFormat)
          ciExtent: (\(diagnostic.ciExtentX), \(diagnostic.ciExtentY), \(diagnostic.ciExtentWidth), \(diagnostic.ciExtentHeight))
          cgImage: \(diagnostic.cgImageWidth)x\(diagnostic.cgImageHeight)
          preferredTransform: [\(diagnostic.preferredTransformA), \(diagnostic.preferredTransformB), \(diagnostic.preferredTransformC), \(diagnostic.preferredTransformD), \(diagnostic.preferredTransformTX), \(diagnostic.preferredTransformTY)]
          cleanAperture: \(diagnostic.cleanApertureWidth.map { "\($0)" } ?? "nil")x\(diagnostic.cleanApertureHeight.map { "\($0)" } ?? "nil")
          png: \(diagnostic.pngPath ?? "nil")
        """)
    }

    private static func validateEyeAssignment(
        leftEye: SpatialTaggedBufferExtractor.EyeBuffer,
        rightEye: SpatialTaggedBufferExtractor.EyeBuffer
    ) throws {
        if leftEye.semanticEye == .right {
            throw SpatialVideoDecodeError.eyeAssignmentInverted(
                "Decoder assigned left from right-eye tag. left tags: \(leftEye.tagDescriptions.joined(separator: ", "))"
            )
        }

        if rightEye.semanticEye == .left {
            throw SpatialVideoDecodeError.eyeAssignmentInverted(
                "Decoder assigned right from left-eye tag. right tags: \(rightEye.tagDescriptions.joined(separator: ", "))"
            )
        }
    }

    private static func logEyeAssignment(
        leftEye: SpatialTaggedBufferExtractor.EyeBuffer,
        rightEye: SpatialTaggedBufferExtractor.EyeBuffer
    ) {
        print("""
        Spatial eye assignment:
          left source: eyesTag=\(eyeTagText(leftEye)) layerID=\(leftEye.layerIDs.map(String.init).joined(separator: ","))
          right source: eyesTag=\(eyeTagText(rightEye)) layerID=\(rightEye.layerIDs.map(String.init).joined(separator: ","))
        """)
    }

    private static func eyeTagText(
        _ eyeBuffer: SpatialTaggedBufferExtractor.EyeBuffer
    ) -> String {
        if eyeBuffer.viewIDs.contains(0x1) || eyeBuffer.semanticEye == .left {
            return "0x1"
        }

        if eyeBuffer.viewIDs.contains(0x2) || eyeBuffer.semanticEye == .right {
            return "0x2"
        }

        return "nil"
    }

    private static func makeImage(
        from cgImage: CGImage,
        maximumImageDimension: CGFloat
    ) -> NSImage {
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let maxDimension = max(width, height)
        let scale = maxDimension > maximumImageDimension
            ? maximumImageDimension / maxDimension
            : 1.0

        return NSImage(
            cgImage: cgImage,
            size: NSSize(
                width: width * scale,
                height: height * scale
            )
        )
    }

    private static func cleanAperture(
        from formatDescription: CMFormatDescription?
    ) -> CGSize? {
        guard let formatDescription else {
            return nil
        }

        let aperture = CMVideoFormatDescriptionGetCleanAperture(
            formatDescription,
            originIsAtTopLeft: false
        )

        guard aperture.width.isFinite,
              aperture.height.isFinite,
              aperture.width > 0,
              aperture.height > 0 else {
            return nil
        }

        return aperture.size
    }

    private static func pixelFormatName(
        _ pixelBuffer: CVPixelBuffer
    ) -> String {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)

        switch format {
        case kCVPixelFormatType_32BGRA:
            return "32BGRA"
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            return "420v"
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            return "420f"
        default:
            return "\(format)"
        }
    }

    private static func estimatedFPS(frames: [VideoFrame]) -> Double {
        guard let first = frames.first,
              let last = frames.last,
              frames.count > 1 else {
            return 0
        }

        let duration = max(last.timeSeconds - first.timeSeconds, 0.0001)
        return Double(frames.count - 1) / duration
    }
}

private func fourCharCodeString(_ code: FourCharCode) -> String {
    let scalars = [
        UInt8((code >> 24) & 0xff),
        UInt8((code >> 16) & 0xff),
        UInt8((code >> 8) & 0xff),
        UInt8(code & 0xff)
    ]

    let string = String(bytes: scalars, encoding: .macOSRoman) ?? "\(code)"
    return "\(string) (\(code))"
}
