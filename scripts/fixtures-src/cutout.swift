// Writes Tests/Fixtures/fox-cutout.png: the fox photo with an elliptical alpha (opaque inside, transparent outside, a
// soft edge between), a picture that is already cut out (MES Mesh §1.10). swift scripts/fixtures-src/cutout.swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let src = CGImageSourceCreateWithURL(root.appending(path: "Tests/Fixtures/fox.png") as CFURL, nil)!
let image = CGImageSourceCreateImageAtIndex(src, 0, nil)!
let (w, h) = (image.width, image.height)
var px = [UInt8](repeating: 0, count: w * h * 4)
let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
for y in 0..<h {
    for x in 0..<w {
        let dx = (Double(x) - Double(w) / 2) / (Double(w) * 0.36), dy = (Double(y) - Double(h) * 0.55) / (Double(h) * 0.40)
        let r = sqrt(dx * dx + dy * dy)
        let a = max(0, min(1, (1.05 - r) / 0.1))
        let i = (y * w + x) * 4
        for k in 0..<4 { px[i + k] = UInt8((Double(px[i + k]) * a).rounded()) }
    }
}
let out = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: CGDataProvider(data: Data(px) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
let dest = CGImageDestinationCreateWithURL(root.appending(path: "Tests/Fixtures/fox-cutout.png") as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, out, nil)
CGImageDestinationFinalize(dest)
