import Foundation
import Logging

@main
enum AppMain {
    static func main() {
        LoggingSystem.bootstrap(StreamLogHandler.standardError)
        let logger = Logger(label: "slopoverlord.app.main")
        logger.info("App target placeholder. AdaUI client will mirror Dashboard capabilities.")
    }
}
