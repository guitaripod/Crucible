import CrucibleTV
import UIKit

@main
enum Entry {
    static func main() {
        _ = UIApplicationMain(
            CommandLine.argc,
            CommandLine.unsafeArgv,
            nil,
            NSStringFromClass(TVAppDelegate.self)
        )
    }
}
