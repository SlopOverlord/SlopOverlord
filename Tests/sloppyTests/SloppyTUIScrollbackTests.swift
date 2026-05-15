import Foundation
import Testing
@testable import sloppy

@Test
func tuiStateDecodesScrollbackDefaultsForLegacyState() throws {
    let data = Data("""
    {
      "drafts": {},
      "petEnabled": true,
      "selections": {},
      "sessionDirectories": {},
      "welcomeTipCursor": 0
    }
    """.utf8)

    let state = try JSONDecoder().decode(SloppyTUIState.self, from: data)

    #expect(state.scrollbackMode == .auto)
    #expect(state.scrollbackLineLimit == 2_000)
}

@Test
func tuiStatePersistsScrollbackSettings() throws {
    let state = SloppyTUIState(
        scrollbackMode: .limited,
        scrollbackLineLimit: 640
    )
    let data = try JSONEncoder().encode(state)
    let decoded = try JSONDecoder().decode(SloppyTUIState.self, from: data)

    #expect(decoded.scrollbackMode == .limited)
    #expect(decoded.scrollbackLineLimit == 640)
}

@Test
func scrollbackPolicyKeepsNativeRenderingForAutoBelowLimit() {
    let behavior = SloppyTUIScrollbackPolicy.behavior(
        mode: .auto,
        lineLimit: 2_000,
        totalLineCount: 1_999
    )

    #expect(behavior == .native(limit: 2_000))
}

@Test
func scrollbackPolicySwitchesAutoToViewportAboveLimit() {
    let behavior = SloppyTUIScrollbackPolicy.behavior(
        mode: .auto,
        lineLimit: 2_000,
        totalLineCount: 2_001
    )

    #expect(behavior == .viewport)
}

@Test
func scrollbackPolicySupportsExplicitModes() {
    #expect(SloppyTUIScrollbackPolicy.behavior(mode: .viewport, lineLimit: 5, totalLineCount: 1) == .viewport)
    #expect(SloppyTUIScrollbackPolicy.behavior(mode: .limited, lineLimit: 5, totalLineCount: 20) == .native(limit: 5))
    #expect(SloppyTUIScrollbackPolicy.behavior(mode: .full, lineLimit: 5, totalLineCount: 20) == .native(limit: nil))
}

@Test
func scrollbackPolicyCapsLimitedNativeRange() throws {
    let behavior = SloppyTUIScrollbackPolicy.behavior(
        mode: .limited,
        lineLimit: 5,
        totalLineCount: 20
    )
    let range = try #require(SloppyTUIScrollbackPolicy.nativeLineRange(
        behavior: behavior,
        totalLineCount: 20
    ))

    #expect(range == 15..<20)
}

@Test
func scrollbackPolicyKeepsFullNativeRangeUncapped() throws {
    let behavior = SloppyTUIScrollbackPolicy.behavior(
        mode: .full,
        lineLimit: 5,
        totalLineCount: 20
    )
    let range = try #require(SloppyTUIScrollbackPolicy.nativeLineRange(
        behavior: behavior,
        totalLineCount: 20
    ))

    #expect(range == 0..<20)
}

@Test
func scrollbackPolicyDoesNotExposeNativeRangeForViewport() {
    let range = SloppyTUIScrollbackPolicy.nativeLineRange(
        behavior: .viewport,
        totalLineCount: 20
    )

    #expect(range == nil)
}

@Test
func scrollbackCommandParsesStatusAndValidUpdates() {
    #expect(SloppyTUIScrollbackCommand.parse([]) == .status)
    #expect(SloppyTUIScrollbackCommand.parse(["status"]) == .status)
    #expect(SloppyTUIScrollbackCommand.parse(["auto"]) == .update(mode: .auto, lineLimit: nil))
    #expect(SloppyTUIScrollbackCommand.parse(["auto", "1200"]) == .update(mode: .auto, lineLimit: 1200))
    #expect(SloppyTUIScrollbackCommand.parse(["viewport"]) == .update(mode: .viewport, lineLimit: nil))
    #expect(SloppyTUIScrollbackCommand.parse(["limited", "500"]) == .update(mode: .limited, lineLimit: 500))
    #expect(SloppyTUIScrollbackCommand.parse(["full"]) == .update(mode: .full, lineLimit: nil))
}

@Test
func scrollbackCommandRejectsInvalidUpdates() {
    guard case .failure = SloppyTUIScrollbackCommand.parse(["limited"]) else {
        Issue.record("limited without a line limit should fail")
        return
    }
    guard case .failure = SloppyTUIScrollbackCommand.parse(["limited", "0"]) else {
        Issue.record("zero line limit should fail")
        return
    }
    guard case .failure = SloppyTUIScrollbackCommand.parse(["viewport", "100"]) else {
        Issue.record("viewport should not accept a line limit")
        return
    }
}
