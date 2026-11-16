import Foundation

/// The hosted aliases' instructions, bundled from `tools/ai/prompts` so the device's own model answers as they do.
package enum BundledPrompts {
    package static func text(_ alias: String) -> String? {
        guard let url = Bundle.module.url(forResource: alias, withExtension: "txt", subdirectory: "Prompts") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
