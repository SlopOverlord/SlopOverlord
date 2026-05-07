import Testing
@testable import sloppy

@Test
func welcomeScreenStaysHiddenWhenAutoDismissLeavesSessionContent() {
    let shouldRender = SloppyTUIWelcomeVisibility.shouldRender(
        welcomeDismissed: false,
        hasSessionCards: true,
        hasLiveAssistantDraft: false,
        hasQueuedMessages: false,
        hasLocalCards: false,
        hasTransientNotice: false
    )

    #expect(!shouldRender)
}

@Test
func welcomeScreenRendersOnlyBeforeAnyTimelineContent() {
    let shouldRender = SloppyTUIWelcomeVisibility.shouldRender(
        welcomeDismissed: false,
        hasSessionCards: false,
        hasLiveAssistantDraft: false,
        hasQueuedMessages: false,
        hasLocalCards: false,
        hasTransientNotice: false
    )

    #expect(shouldRender)
}
