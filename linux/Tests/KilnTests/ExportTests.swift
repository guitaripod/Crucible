import Foundation
import Testing
@testable import Kiln

@Suite("Saving and copying images")
struct ExportTests {
    @Test func aCaptureEncodesAsAPNGThatDecodesToTheSameSRGBPixels() throws {
        let linear: [Float] = [1, 0, 0, 1, 0, 1, 0, 1, 0.2140, 0.2140, 0.2140, 1, 4, -1, 0, 1]
        let png = try #require(PNGWriter.encode(linear: linear, width: 2, height: 2))
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        let image = try ImageDecoder.decode(png)
        #expect(image.width == 2 && image.height == 2)
        #expect(Array(image.pixels[0..<4]) == [255, 0, 0, 255])
        #expect(Array(image.pixels[4..<8]) == [0, 255, 0, 255])
        #expect(abs(Int(image.pixels[8]) - 128) <= 1)
        #expect(Array(image.pixels[12..<16]) == [255, 0, 0, 255])
    }

    @Test func theUserDirsFileNamesThePicturesFolder() {
        let file = """
        # This file is written by xdg-user-dirs-update
        XDG_DESKTOP_DIR="$HOME/Desktop"
        XDG_PICTURES_DIR="$HOME/Bilder"
        """
        #expect(PicturesFolder.picturesPath(in: file, home: "/home/maren") == "/home/maren/Bilder")
        #expect(PicturesFolder.picturesPath(in: "XDG_PICTURES_DIR=\"/srv/photos\"", home: "/home/maren") == "/srv/photos")
        #expect(PicturesFolder.picturesPath(in: "XDG_PICTURES_DIR=\"$HOME/\"", home: "/home/maren") == nil)
        #expect(PicturesFolder.picturesPath(in: "XDG_MUSIC_DIR=\"$HOME/Music\"", home: "/home/maren") == nil)
    }

    @Test func savingNeverReplacesAnEarlierFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-pictures-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try PicturesFolder.write(Data([1]), named: "My 2026 in Crucible (Story)", in: folder)
        let second = try PicturesFolder.write(Data([2]), named: "My 2026 in Crucible (Story)", in: folder)
        let slashed = try PicturesFolder.write(Data([3]), named: "AC/DC", in: folder)
        #expect(first.lastPathComponent == "My 2026 in Crucible (Story).png")
        #expect(second.lastPathComponent == "My 2026 in Crucible (Story) 2.png")
        #expect(slashed.lastPathComponent == "AC-DC.png")
        #expect(try Data(contentsOf: first) == Data([1]))
    }

    @Test @MainActor func aWindowWithoutADesktopKeepsTheImageItCopied() throws {
        let window = try Window(offscreen: Size(width: 64, height: 64), gpu: TestGPU.shared)
        window.copy(Data([0x89, 0x50]), mimeType: "image/png")
        #expect(window.copiedData?.mimeType == "image/png")
        #expect(window.copiedData?.data == Data([0x89, 0x50]))
        window.copy("Halcyon")
        #expect(window.copiedData == nil)
        #expect(window.pasteboardText() == "Halcyon")
    }
}
