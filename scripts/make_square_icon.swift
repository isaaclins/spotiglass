#!/usr/bin/env swift
import AppKit

guard CommandLine.arguments.count >= 3 else {
    FileHandle.standardError.write(Data("usage: make_square_icon.swift <input.png> <output.png> [side]\n".utf8))
    exit(1)
}
let input = CommandLine.arguments[1]
let outPath = CommandLine.arguments[2]
let side = CGFloat(Int(CommandLine.arguments[3]) ?? 1024)

guard let img = NSImage(contentsOfFile: input) else {
    FileHandle.standardError.write(Data("failed to read \(input)\n".utf8))
    exit(1)
}
guard let tiff = img.tiffRepresentation, let srcRep = NSBitmapImageRep(data: tiff) else {
    FileHandle.standardError.write(Data("bitmap rep failed\n".utf8))
    exit(1)
}

let w = CGFloat(srcRep.pixelsWide)
let h = CGFloat(srcRep.pixelsHigh)
let scale = min(side / w, side / h)
let nw = Int(w * scale)
let nh = Int(h * scale)

guard let canvas = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(side),
    pixelsHigh: Int(side),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    FileHandle.standardError.write(Data("canvas failed\n".utf8))
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
NSColor.clear.set()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: side, height: side)).fill()

let x = (side - CGFloat(nw)) / 2
let y = (side - CGFloat(nh)) / 2
img.draw(
    in: NSRect(x: x, y: y, width: CGFloat(nw), height: CGFloat(nh)),
    from: NSRect(origin: .zero, size: img.size),
    operation: .sourceOver,
    fraction: 1
)
NSGraphicsContext.restoreGraphicsState()

guard let png = canvas.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("png encode failed\n".utf8))
    exit(1)
}
do {
    try png.write(to: URL(fileURLWithPath: outPath))
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
