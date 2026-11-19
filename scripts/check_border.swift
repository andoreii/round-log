import AppKit

// Compare the solid stroke on four straight screen edges at native resolution.
for path in CommandLine.arguments.dropFirst() {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), let bitmap = NSBitmapImageRep(data: data) else { fatalError("Missing image: \(path)") }
    let width = bitmap.pixelsWide, height = bitmap.pixelsHigh
    func rgb(_ x: Int, _ y: Int) -> [CGFloat] {
        let color = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
        return [color.redComponent, color.greenComponent, color.blueComponent]
    }
    let stroke = rgb(1, height / 2)
    precondition(stroke[2] - stroke[0] > 0.3, "Use the blue fixture for border measurement")
    func thickness(_ sample: (Int) -> [CGFloat]) -> Int {
        var count = 0
        for distance in 0..<36 {
            if zip(sample(distance), stroke).allSatisfy({ abs($0 - $1) < 0.035 }) { count += 1 }
            else if count > 0 { break }
        }
        return count
    }
    let pixels = [thickness { rgb($0, height / 2) }, thickness { rgb(width - 1 - $0, height / 2) },
                  thickness { rgb(width / 4, $0) }, thickness { rgb(width / 4, height - 1 - $0) }]
    precondition(pixels.allSatisfy { $0 > 0 }, "A screen edge is missing its stroke: \(pixels)")
    precondition(pixels.max()! - pixels.min()! <= 1, "Uneven border: \(pixels)")
    print("\(URL(fileURLWithPath: path).lastPathComponent): left/right/top/bottom \(pixels) pixels (3×)")
}
