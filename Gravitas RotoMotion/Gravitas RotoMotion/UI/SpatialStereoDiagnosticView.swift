import AppKit
import SwiftUI

struct SpatialStereoDiagnosticView: View {
    let leftImage: NSImage?
    let rightImage: NSImage?
    let leftCount: Int
    let rightCount: Int
    let dumpDirectory: String
    let diagnostics: [SpatialEyeFrameDiagnostic]

    var body: some View {
        GroupBox("Spatial Stereo Diagnostics") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    eyePreview(
                        title: "Left Eye",
                        image: leftImage,
                        frameCount: leftCount
                    )

                    eyePreview(
                        title: "Right Eye",
                        image: rightImage,
                        frameCount: rightCount
                    )
                }

                Text("Dump folder: \(dumpDirectory.isEmpty ? "none" : dumpDirectory)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(diagnostics.prefix(10)) { item in
                            diagnosticRow(item)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 180, maxHeight: 260)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func eyePreview(
        title: String,
        image: NSImage?,
        frameCount: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)

            ZStack {
                Rectangle()
                    .fill(Color.black.opacity(0.8))

                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    Text("No image")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(4.0 / 3.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Text("Frames: \(frameCount)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func diagnosticRow(
        _ item: SpatialEyeFrameDiagnostic
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(item.eye.rawValue.capitalized) frame \(item.frameIndex) @ \(String(format: "%.3f", item.presentationTimeSeconds))s")
                .font(.caption)
                .fontWeight(.semibold)

            Text("Layer IDs: \(item.layerIDs.map(String.init).joined(separator: ", ")) | View IDs: \(item.viewIDs.map(String.init).joined(separator: ", "))")
                .font(.caption2)

            Text("Pixel: \(item.pixelWidth)x\(item.pixelHeight) \(item.pixelFormat)")
                .font(.caption2)

            Text("CI extent: (\(item.ciExtentX), \(item.ciExtentY), \(item.ciExtentWidth), \(item.ciExtentHeight))")
                .font(.caption2)

            Text("CGImage: \(item.cgImageWidth)x\(item.cgImageHeight)")
                .font(.caption2)

            Text(
                "Transform: [\(item.preferredTransformA), \(item.preferredTransformB), \(item.preferredTransformC), \(item.preferredTransformD), \(item.preferredTransformTX), \(item.preferredTransformTY)]"
            )
            .font(.caption2)

            if let pngPath = item.pngPath {
                Text("PNG: \(pngPath)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(6)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }
}
