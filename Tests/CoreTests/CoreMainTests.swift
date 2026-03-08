import Foundation
import Testing
@testable import Core

@Test
func bootstrapBulletinDefaultsToVisorConfig() {
    var config = CoreConfig.default
    config.visor.bootstrapBulletin = false
    #expect(!shouldBootstrapVisorBulletin(cliOverride: nil, config: config))

    config.visor.bootstrapBulletin = true
    #expect(shouldBootstrapVisorBulletin(cliOverride: nil, config: config))
}

@Test
func bootstrapBulletinCliOverrideWinsOverConfig() {
    var config = CoreConfig.default
    config.visor.bootstrapBulletin = false
    #expect(shouldBootstrapVisorBulletin(cliOverride: true, config: config))

    config.visor.bootstrapBulletin = true
    #expect(!shouldBootstrapVisorBulletin(cliOverride: false, config: config))
}
