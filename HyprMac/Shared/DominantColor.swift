// Dominant-accent extraction for wallpaper images: pick the hue that
// dominates the picture and return it as a saturated, border-ready
// accent color.

import Cocoa

extension NSImage {

    /// A good accent color guessed from the image's content.
    ///
    /// Downsamples to a small bitmap, buckets sufficiently colorful
    /// pixels by hue (weighted by saturation × brightness so vivid areas
    /// dominate over large washed-out ones), then averages the winning
    /// bucket and lifts saturation/brightness into accent range. Returns
    /// nil for effectively monochrome images — callers keep their
    /// default accent in that case.
    func dominantAccentColor() -> NSColor? {
        let sample = 64
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        guard let ctx = CGContext(data: nil, width: sample, height: sample,
                                  bitsPerComponent: 8, bytesPerRow: sample * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: sample, height: sample))
        guard let data = ctx.data else { return nil }
        let px = data.bindMemory(to: UInt8.self, capacity: sample * sample * 4)

        let buckets = 24
        var weight = [Double](repeating: 0, count: buckets)
        var hueSum = [Double](repeating: 0, count: buckets)
        var satSum = [Double](repeating: 0, count: buckets)
        var briSum = [Double](repeating: 0, count: buckets)
        var count = [Int](repeating: 0, count: buckets)

        for i in stride(from: 0, to: sample * sample * 4, by: 4) {
            let r = CGFloat(px[i]) / 255, g = CGFloat(px[i + 1]) / 255, b = CGFloat(px[i + 2]) / 255
            var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0
            NSColor(red: r, green: g, blue: b, alpha: 1).getHue(&h, saturation: &s, brightness: &v, alpha: nil)
            // skip near-grays and near-black/white — they make muddy accents
            guard s > 0.2, v > 0.15, v < 0.98 else { continue }
            let bucket = min(buckets - 1, Int(h * CGFloat(buckets)))
            let w = Double(s * v)
            weight[bucket] += w
            hueSum[bucket] += Double(h) * w
            satSum[bucket] += Double(s) * w
            briSum[bucket] += Double(v) * w
            count[bucket] += 1
        }

        guard let best = weight.indices.max(by: { weight[$0] < weight[$1] }),
              weight[best] > 0, count[best] >= 8 else { return nil }

        let hue = hueSum[best] / weight[best]
        // lift into accent range: vivid enough to read as a border color
        // even when the source area is pastel or dim
        let sat = max(0.55, min(0.95, satSum[best] / weight[best] * 1.3))
        let bri = max(0.65, min(0.95, briSum[best] / weight[best] * 1.2))
        return NSColor(hue: hue, saturation: sat, brightness: bri, alpha: 1)
    }
}
