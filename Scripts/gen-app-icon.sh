#!/bin/bash
# Generates Resources/AppIcon.icns: a white SF "tree" on a green squircle.
# Re-run after changing the look. Requires swiftc + sips + iconutil (stock macOS).
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="Resources/AppIcon.icns"
mkdir -p Resources
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/gen.swift" <<'SWIFT'
import AppKit
let S = 1024.0
let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()
let full = NSRect(x: 0, y: 0, width: S, height: S)
let margin = S * 0.085
let body = full.insetBy(dx: margin, dy: margin)
let path = NSBezierPath(roundedRect: body, xRadius: body.width * 0.2237, yRadius: body.width * 0.2237)
NSGradient(colors: [NSColor(red: 0.24, green: 0.60, blue: 0.33, alpha: 1),
                    NSColor(red: 0.11, green: 0.37, blue: 0.20, alpha: 1)])!.draw(in: path, angle: -90)
let cfg = NSImage.SymbolConfiguration(pointSize: S * 0.46, weight: .semibold)
if let sym = NSImage(systemSymbolName: "tree.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(cfg) {
    let tinted = NSImage(size: sym.size)
    tinted.lockFocus()
    sym.draw(in: NSRect(origin: .zero, size: sym.size))
    NSColor.white.set()
    NSRect(origin: .zero, size: sym.size).fill(using: .sourceAtop)
    tinted.unlockFocus()
    let r = NSRect(x: (S - sym.size.width) / 2, y: (S - sym.size.height) / 2,
                   width: sym.size.width, height: sym.size.height)
    tinted.draw(in: r)
}
img.unlockFocus()
guard let tiff = img.tiffRepresentation, let bmp = NSBitmapImageRep(data: tiff),
      let png = bmp.representation(using: .png, properties: [:]) else { exit(1) }
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
SWIFT

swiftc "$TMP/gen.swift" -o "$TMP/gen"
"$TMP/gen" "$TMP/master.png"

SET="$TMP/AppIcon.iconset"
mkdir -p "$SET"
gen() { sips -z "$1" "$1" "$TMP/master.png" --out "$SET/$2" >/dev/null; }
gen 16   icon_16x16.png
gen 32   icon_16x16@2x.png
gen 32   icon_32x32.png
gen 64   icon_32x32@2x.png
gen 128  icon_128x128.png
gen 256  icon_128x128@2x.png
gen 256  icon_256x256.png
gen 512  icon_256x256@2x.png
gen 512  icon_512x512.png
cp "$TMP/master.png" "$SET/icon_512x512@2x.png"
iconutil -c icns "$SET" -o "$OUT"
echo "wrote $OUT"
