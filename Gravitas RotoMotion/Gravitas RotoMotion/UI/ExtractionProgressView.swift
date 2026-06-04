import SwiftUI

struct ExtractionProgressView: View {
    let isExtracting: Bool
    let progressText: String
    let logLines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if isExtracting {
                    ProgressView()
                        .controlSize(.small)
                }

                Text(progressText)
                    .font(.callout)
                    .lineLimit(2)
                    .foregroundStyle(.primary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(logLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
                .padding(8)
            }
            .frame(minHeight: 130)
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}
