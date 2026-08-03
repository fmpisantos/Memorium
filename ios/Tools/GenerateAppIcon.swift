#!/usr/bin/env swift
//
//  Draws the app icon -- two overlapping speech bubbles on an indigo/violet
//  gradient -- and writes every size AppIcon.appiconset needs, plus the
//  Contents.json that indexes them.
//
//  The artwork is vector, so each size is drawn from scratch rather than
//  resampled from the 1024: small sizes stay crisp instead of going mushy.
//
//  Run from the ios/ directory after changing anything here:
//
//      swift Tools/GenerateAppIcon.swift Memorium/Assets.xcassets/AppIcon.appiconset
//
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Geometry

/// A speech bubble in unit space: 0...1 across the icon, y pointing up.
struct Bubble {
    var rect: CGRect
    var radius: CGFloat
    /// Which bottom corner the tail hangs from.
    var tailLeft: Bool
    var tailLength: CGFloat
    var tailWidth: CGFloat
}

/// One closed subpath -- rounded rect with the tail spliced into the bottom
/// edge. Deliberately not a rounded rect plus a separate triangle: two
/// subpaths would need matching winding to union cleanly, and a seam across
/// the join shows up at the small sizes.
func bubblePath(_ b: Bubble, scale s: CGFloat) -> CGPath {
    let r = CGRect(x: b.rect.minX * s, y: b.rect.minY * s,
                   width: b.rect.width * s, height: b.rect.height * s)
    let rad = b.radius * s
    let tailLen = b.tailLength * s
    let tailW = b.tailWidth * s

    let p = CGMutablePath()
    p.move(to: CGPoint(x: r.minX + rad, y: r.maxY))
    p.addLine(to: CGPoint(x: r.maxX - rad, y: r.maxY))
    p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY),
             tangent2End: CGPoint(x: r.maxX, y: r.maxY - rad), radius: rad)
    p.addLine(to: CGPoint(x: r.maxX, y: r.minY + rad))
    p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY),
             tangent2End: CGPoint(x: r.maxX - rad, y: r.minY), radius: rad)

    // Travelling right-to-left along the bottom edge, detouring into the tail.
    if b.tailLeft {
        p.addLine(to: CGPoint(x: r.minX + rad + tailW, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + rad * 0.55, y: r.minY - tailLen))
    } else {
        p.addLine(to: CGPoint(x: r.maxX - rad * 0.55, y: r.minY - tailLen))
        p.addLine(to: CGPoint(x: r.maxX - rad - tailW, y: r.minY))
    }

    p.addLine(to: CGPoint(x: r.minX + rad, y: r.minY))
    p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY),
             tangent2End: CGPoint(x: r.minX, y: r.minY + rad), radius: rad)
    p.addLine(to: CGPoint(x: r.minX, y: r.maxY - rad))
    p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY),
             tangent2End: CGPoint(x: r.minX + rad, y: r.maxY), radius: rad)
    p.closeSubpath()
    return p
}

// MARK: - Drawing

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

let gradientTop = CGColor(colorSpace: sRGB, components: [0.302, 0.267, 0.898, 1])!   // #4D44E5
let gradientBottom = CGColor(colorSpace: sRGB, components: [0.584, 0.200, 0.918, 1])! // #9533EA

/// The listener, sitting behind and to the upper right.
let backBubble = Bubble(rect: CGRect(x: 0.395, y: 0.530, width: 0.455, height: 0.325),
                        radius: 0.105, tailLeft: false, tailLength: 0.072, tailWidth: 0.105)

/// The speaker, in front and to the lower left.
let frontBubble = Bubble(rect: CGRect(x: 0.150, y: 0.268, width: 0.470, height: 0.350),
                         radius: 0.115, tailLeft: true, tailLength: 0.078, tailWidth: 0.115)

/// Gap punched between the two bubbles so the back one reads as separate
/// rather than as one blob.
let separationGap: CGFloat = 0.042

func makeIcon(pixels: Int) -> CGImage {
    let s = CGFloat(pixels)
    guard let ctx = CGContext(data: nil, width: pixels, height: pixels,
                              bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("could not create a \(pixels)x\(pixels) context")
    }
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    let gradient = CGGradient(colorsSpace: sRGB,
                              colors: [gradientTop, gradientBottom] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0),
                           options: [])

    // Both bubbles go into one transparency layer: the gap is punched with
    // destinationOut, which clears the layer's own pixels only, leaving the
    // gradient underneath to show through.
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)

    ctx.addPath(bubblePath(backBubble, scale: s))
    ctx.setFillColor(CGColor(colorSpace: sRGB, components: [1, 1, 1, 0.45])!)
    ctx.fillPath()

    ctx.setBlendMode(.destinationOut)
    ctx.addPath(bubblePath(frontBubble, scale: s))
    ctx.setStrokeColor(CGColor(colorSpace: sRGB, components: [0, 0, 0, 1])!)
    ctx.setLineWidth(separationGap * s)
    ctx.setLineJoin(.round)
    ctx.strokePath()
    ctx.setBlendMode(.normal)

    ctx.addPath(bubblePath(frontBubble, scale: s))
    ctx.setFillColor(CGColor(colorSpace: sRGB, components: [1, 1, 1, 1])!)
    ctx.fillPath()

    ctx.endTransparencyLayer()

    guard let image = ctx.makeImage() else { fatalError("render failed") }
    return flattened(image)
}

/// App Store icons must not carry an alpha channel, even a fully opaque one,
/// so redraw into a context that has no alpha to give away.
func flattened(_ image: CGImage) -> CGImage {
    guard let ctx = CGContext(data: nil, width: image.width, height: image.height,
                              bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
        fatalError("could not create an opaque context")
    }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard let flat = ctx.makeImage() else { fatalError("could not drop the alpha channel") }
    return flat
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                     UTType.png.identifier as CFString, 1, nil) else {
        fatalError("could not open \(url.path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(url.path)") }
}

// MARK: - Catalog

struct Entry {
    let idiom: String
    /// Points, as the asset catalog spells it ("83.5" is a real one).
    let size: String
    let scale: Int

    var pixels: Int { Int((Double(size)! * Double(scale)).rounded()) }
    var filename: String { "icon-\(pixels).png" }
}

let entries: [Entry] = [
    .init(idiom: "iphone", size: "20", scale: 2),
    .init(idiom: "iphone", size: "20", scale: 3),
    .init(idiom: "iphone", size: "29", scale: 2),
    .init(idiom: "iphone", size: "29", scale: 3),
    .init(idiom: "iphone", size: "40", scale: 2),
    .init(idiom: "iphone", size: "40", scale: 3),
    .init(idiom: "iphone", size: "60", scale: 2),
    .init(idiom: "iphone", size: "60", scale: 3),
    .init(idiom: "ipad", size: "20", scale: 1),
    .init(idiom: "ipad", size: "20", scale: 2),
    .init(idiom: "ipad", size: "29", scale: 1),
    .init(idiom: "ipad", size: "29", scale: 2),
    .init(idiom: "ipad", size: "40", scale: 1),
    .init(idiom: "ipad", size: "40", scale: 2),
    .init(idiom: "ipad", size: "76", scale: 2),
    .init(idiom: "ipad", size: "83.5", scale: 2),
    .init(idiom: "ios-marketing", size: "1024", scale: 1),
]

let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Memorium/Assets.xcassets/AppIcon.appiconset"
let outputDir = URL(fileURLWithPath: outputPath)
try! FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

// Several entries land on the same pixel count (a 40pt @1x iPad icon and a
// 20pt @2x iPhone one are both 40px); draw each size once and let the
// catalog point more than one entry at the same file.
for pixels in Set(entries.map(\.pixels)).sorted() {
    let url = outputDir.appendingPathComponent("icon-\(pixels).png")
    writePNG(makeIcon(pixels: pixels), to: url)
    print("wrote \(url.lastPathComponent)")
}

let images = entries.map { entry in
    """
        {
          "filename" : "\(entry.filename)",
          "idiom" : "\(entry.idiom)",
          "scale" : "\(entry.scale)x",
          "size" : "\(entry.size)x\(entry.size)"
        }
    """
}

let contents = """
{
  "images" : [
\(images.joined(separator: ",\n"))
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}

"""
try! contents.write(to: outputDir.appendingPathComponent("Contents.json"),
                    atomically: true, encoding: .utf8)
print("wrote Contents.json (\(entries.count) entries)")
