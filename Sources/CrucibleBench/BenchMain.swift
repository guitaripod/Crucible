import Foundation
import CrucibleCore

@main
struct BenchMain {
    static func main() async {
        let probes = Probes.all()
        var results: [(probe: Probe, failure: String?)] = []

        for probe in probes {
            results.append((probe, await probe.check()))
        }

        print(title)
        print("")
        var passed = 0
        for group in Probe.Group.allCases {
            let members = results.filter { $0.probe.group == group }
            guard !members.isEmpty else { continue }
            let groupPassed = members.filter { $0.failure == nil }.count
            passed += groupPassed
            print("\(group.rawValue)  \(groupPassed)/\(members.count)")
            for result in members {
                print("  \(result.failure == nil ? "PASS" : "FAIL")  \(result.probe.title)")
                if let failure = result.failure {
                    print("        \(failure)")
                }
            }
            print("")
        }

        let total = probes.count
        let percent = total > 0 ? Int((Double(passed) / Double(total) * 100).rounded()) : 0
        print("TOTAL  \(passed)/\(total)  \(percent)%")
        print("crucible-bench \(passed)/\(total) \(percent)%")
    }

    private static let title = """
    Crucible episode-flow benchmark
    Going from episode to episode and keeping watched and unwatched in step.
    Each line is one behaviour a viewer depends on; PASS means the app does it today.
    """
}
