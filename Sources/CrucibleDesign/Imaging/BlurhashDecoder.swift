@preconcurrency import UIKit

enum BlurhashDecoder {
    private nonisolated(unsafe) static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 200
        return c
    }()

    private static let characters: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~")

    private static let characterMap: [Character: Int] = {
        var map = [Character: Int]()
        for (i, c) in characters.enumerated() { map[c] = i }
        return map
    }()

    static func decode(_ blurhash: String, width: Int = 32, height: Int = 32) -> UIImage? {
        let key = blurhash as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let chars = Array(blurhash)
        guard chars.count >= 6 else { return nil }

        guard let sizeFlag = decodeBase83(chars, from: 0, length: 1) else { return nil }
        let numY = (sizeFlag / 9) + 1
        let numX = (sizeFlag % 9) + 1
        let expectedLength = 4 + 2 * numX * numY
        guard chars.count == expectedLength else { return nil }

        guard let quantisedMaximumValue = decodeBase83(chars, from: 1, length: 1) else { return nil }
        let maximumValue = Double(quantisedMaximumValue + 1) / 166.0

        var colors = [(Double, Double, Double)]()
        guard let dcValue = decodeBase83(chars, from: 2, length: 4) else { return nil }
        colors.append(decodeDC(dcValue))

        for i in 1 ..< numX * numY {
            guard let acValue = decodeBase83(chars, from: 4 + 2 * (i - 1), length: 2) else { return nil }
            colors.append(decodeAC(acValue, maximumValue: maximumValue))
        }

        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)

        for y in 0 ..< height {
            for x in 0 ..< width {
                var r = 0.0, g = 0.0, b = 0.0
                for j in 0 ..< numY {
                    for i in 0 ..< numX {
                        let basis = cos(Double.pi * Double(i) * Double(x) / Double(width))
                            * cos(Double.pi * Double(j) * Double(y) / Double(height))
                        let color = colors[j * numX + i]
                        r += color.0 * basis
                        g += color.1 * basis
                        b += color.2 * basis
                    }
                }
                let offset = y * bytesPerRow + x * 4
                pixels[offset] = UInt8(linearToSRGB(r))
                pixels[offset + 1] = UInt8(linearToSRGB(g))
                pixels[offset + 2] = UInt8(linearToSRGB(b))
                pixels[offset + 3] = 255
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let cgImage = context.makeImage() else {
            return nil
        }

        let image = UIImage(cgImage: cgImage)
        cache.setObject(image, forKey: key)
        return image
    }

    private static func decodeBase83(_ chars: [Character], from index: Int, length: Int) -> Int? {
        var value = 0
        for i in index ..< index + length {
            guard i < chars.count, let digit = characterMap[chars[i]] else { return nil }
            value = value * 83 + digit
        }
        return value
    }

    private static func decodeDC(_ value: Int) -> (Double, Double, Double) {
        let r = value >> 16
        let g = (value >> 8) & 255
        let b = value & 255
        return (sRGBToLinear(r), sRGBToLinear(g), sRGBToLinear(b))
    }

    private static func decodeAC(_ value: Int, maximumValue: Double) -> (Double, Double, Double) {
        let quantR = value / (19 * 19)
        let quantG = (value / 19) % 19
        let quantB = value % 19
        return (
            signPow((Double(quantR) - 9) / 9, 2) * maximumValue,
            signPow((Double(quantG) - 9) / 9, 2) * maximumValue,
            signPow((Double(quantB) - 9) / 9, 2) * maximumValue
        )
    }

    private static func sRGBToLinear(_ value: Int) -> Double {
        let v = Double(value) / 255
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    private static func linearToSRGB(_ value: Double) -> Int {
        let v = max(0, min(1, value))
        let srgb = v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
        return max(0, min(255, Int(srgb * 255 + 0.5)))
    }

    private static func signPow(_ value: Double, _ exp: Double) -> Double {
        copysign(pow(abs(value), exp), value)
    }
}
