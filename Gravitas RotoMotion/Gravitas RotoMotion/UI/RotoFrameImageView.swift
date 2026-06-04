import AppKit
import SwiftUI

struct RotoFrameImageView: NSViewRepresentable {
    let image: NSImage

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.imageAlignment = .alignCenter
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        view.canDrawSubviewsIntoLayer = true

        print("[RotoMotion VideoDisplay] makeNSView")

        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        view.image = image
        view.needsDisplay = true
        view.layer?.setNeedsDisplay()

        print(
            """
            [RotoMotion VideoDisplay] updateNSView assigned image
              imageSize: \(image.size)
              viewBounds: \(view.bounds)
              window: \(view.window != nil)
            """
        )
    }
}
