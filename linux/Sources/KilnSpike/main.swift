import Foundation

let arguments = CommandLine.arguments
let frames = arguments.firstIndex(of: "--frames").flatMap { Int(arguments[$0 + 1]) } ?? 300
let output = arguments.firstIndex(of: "--out").map { arguments[$0 + 1] } ?? FileManager.default.currentDirectoryPath
let spike = Spike(frameLimit: frames, outputDirectory: output)
do {
    try spike.run()
} catch {
    spike.report["error"] = "\(error)"
}
for key in spike.report.keys.sorted() {
    print("\(key)=\(spike.report[key]!)")
}
