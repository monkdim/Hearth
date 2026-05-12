#!/usr/bin/env swift
// Generates Ember's app icon at 1024×1024 as PNG. Pipe the output through
// `sips` to produce smaller resolutions for the .appiconset.
//
// Usage: swift generate-icon.swift /path/to/output_1024.png

import AppKit
import CoreGraphics
import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    print("Usage: generate-icon.swift <output.png>")
    exit(1)
}
let outputPath = arguments[1]

let size: CGFloat = 1024

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(size),
    pixelsHigh: Int(size),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 32
) else {
    print("Failed to create bitmap rep")
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
guard let ctx = NSGraphicsContext.current?.cgContext else {
    print("No CG context")
    exit(1)
}

let rgb = CGColorSpaceCreateDeviceRGB()
let canvas = CGRect(x: 0, y: 0, width: size, height: size)

// MARK: - Squircle background

let cornerRadius: CGFloat = size * 0.225
let bodyInset: CGFloat = 0 // full-bleed; macOS Big Sur+ wants the developer to provide the rounded shape
let bodyRect = canvas.insetBy(dx: bodyInset, dy: bodyInset)
let bodyPath = CGPath(roundedRect: bodyRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

ctx.saveGState()
ctx.addPath(bodyPath)
ctx.clip()

// Layered dark background — a deep mahogany base with a subtle radial glow
// in the lower-middle area, hinting that warmth comes from the flame.
let bgGradient = CGGradient(
    colorsSpace: rgb,
    colors: [
        CGColor(red: 0.20, green: 0.07, blue: 0.02, alpha: 1.0), // warm core
        CGColor(red: 0.10, green: 0.03, blue: 0.01, alpha: 1.0),
        CGColor(red: 0.04, green: 0.01, blue: 0.00, alpha: 1.0), // edges
    ] as CFArray,
    locations: [0.0, 0.55, 1.0]
)!
ctx.drawRadialGradient(
    bgGradient,
    startCenter: CGPoint(x: size * 0.5, y: size * 0.35),
    startRadius: 0,
    endCenter: CGPoint(x: size * 0.5, y: size * 0.35),
    endRadius: size * 0.72,
    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
)

// MARK: - Glow halo behind the flame

let haloGradient = CGGradient(
    colorsSpace: rgb,
    colors: [
        CGColor(red: 1.0, green: 0.55, blue: 0.1, alpha: 0.35),
        CGColor(red: 1.0, green: 0.35, blue: 0.0, alpha: 0.18),
        CGColor(red: 1.0, green: 0.20, blue: 0.0, alpha: 0.0),
    ] as CFArray,
    locations: [0.0, 0.45, 1.0]
)!
ctx.drawRadialGradient(
    haloGradient,
    startCenter: CGPoint(x: size * 0.5, y: size * 0.46),
    startRadius: 0,
    endCenter: CGPoint(x: size * 0.5, y: size * 0.46),
    endRadius: size * 0.45,
    options: []
)

// MARK: - Flame paths

/// Builds a teardrop-like flame path: narrow base, wide belly, sharp tip.
func flamePath(centerX: CGFloat, baseY: CGFloat, tipY: CGFloat, halfWidth: CGFloat,
               bellyOffset: CGFloat = 0.34) -> CGPath {
    let height = tipY - baseY
    let path = CGMutablePath()
    path.move(to: CGPoint(x: centerX, y: baseY))
    // Right side: belly out then taper to tip.
    path.addCurve(
        to: CGPoint(x: centerX, y: tipY),
        control1: CGPoint(x: centerX + halfWidth * 1.55, y: baseY + height * bellyOffset),
        control2: CGPoint(x: centerX + halfWidth * 0.30, y: tipY - height * 0.04)
    )
    // Left side: mirrored.
    path.addCurve(
        to: CGPoint(x: centerX, y: baseY),
        control1: CGPoint(x: centerX - halfWidth * 0.30, y: tipY - height * 0.04),
        control2: CGPoint(x: centerX - halfWidth * 1.55, y: baseY + height * bellyOffset)
    )
    path.closeSubpath()
    return path
}

let cx = size * 0.5
let baseY = size * 0.22
let tipY = size * 0.82
let halfW = size * 0.22

// MARK: - Outer flame (deep red → orange)

let outer = flamePath(centerX: cx, baseY: baseY, tipY: tipY, halfWidth: halfW)
ctx.saveGState()
ctx.addPath(outer)
ctx.clip()
let outerGradient = CGGradient(
    colorsSpace: rgb,
    colors: [
        CGColor(red: 1.00, green: 0.85, blue: 0.30, alpha: 1.0), // tip — yellow
        CGColor(red: 1.00, green: 0.55, blue: 0.08, alpha: 1.0), // mid — orange
        CGColor(red: 0.85, green: 0.18, blue: 0.04, alpha: 1.0), // base — deep red
    ] as CFArray,
    locations: [0.0, 0.45, 1.0]
)!
ctx.drawLinearGradient(
    outerGradient,
    start: CGPoint(x: cx, y: tipY),
    end: CGPoint(x: cx, y: baseY),
    options: []
)
ctx.restoreGState()

// MARK: - Inner flame (bright yellow core, smaller and lower)

let innerBase = baseY + (tipY - baseY) * 0.10
let innerTip = baseY + (tipY - baseY) * 0.72
let inner = flamePath(
    centerX: cx,
    baseY: innerBase,
    tipY: innerTip,
    halfWidth: halfW * 0.55,
    bellyOffset: 0.38
)
ctx.saveGState()
ctx.addPath(inner)
ctx.clip()
let innerGradient = CGGradient(
    colorsSpace: rgb,
    colors: [
        CGColor(red: 1.00, green: 0.99, blue: 0.85, alpha: 1.0), // white-yellow tip
        CGColor(red: 1.00, green: 0.85, blue: 0.30, alpha: 1.0), // bright yellow
        CGColor(red: 1.00, green: 0.55, blue: 0.08, alpha: 0.0), // fade out
    ] as CFArray,
    locations: [0.0, 0.55, 1.0]
)!
ctx.drawLinearGradient(
    innerGradient,
    start: CGPoint(x: cx, y: innerTip),
    end: CGPoint(x: cx, y: innerBase),
    options: []
)
ctx.restoreGState()

// MARK: - Subtle highlight on the body (top edge sheen)

ctx.saveGState()
ctx.addPath(bodyPath)
ctx.clip()
let sheen = CGGradient(
    colorsSpace: rgb,
    colors: [
        CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.05),
        CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.0),
    ] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(
    sheen,
    start: CGPoint(x: cx, y: size),
    end: CGPoint(x: cx, y: size * 0.55),
    options: []
)
ctx.restoreGState()

ctx.restoreGState()
NSGraphicsContext.restoreGraphicsState()

// MARK: - Save

guard let data = rep.representation(using: .png, properties: [:]) else {
    print("Failed to encode PNG")
    exit(1)
}
do {
    try data.write(to: URL(fileURLWithPath: outputPath))
    print("✓ wrote \(outputPath)")
} catch {
    print("Failed to write: \(error)")
    exit(1)
}
