//
//  PortalLiveView.swift
//  photobooth
//
//  Displays PortalEngine's latest composited frame in place of the raw
//  camera preview. Updates at the engine's throttled rate rather than full
//  video frame rate — a deliberate trade-off so segmentation/compositing
//  never blocks or backs up (see PortalEngine).
//

import SwiftUI

struct PortalLiveView: View {
    let image: UIImage?

    var body: some View {
        GeometryReader { proxy in
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
            } else {
                Theme.Palette.void
            }
        }
    }
}
