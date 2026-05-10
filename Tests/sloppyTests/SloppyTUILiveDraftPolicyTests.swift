import Testing
@testable import sloppy

@Test
func liveDraftPolicyInterpolatesShortPlainText() {
    #expect(SloppyTUILiveDraftPolicy.shouldInterpolate(current: "Hel", target: "Hello"))
}

@Test
func liveDraftPolicyDoesNotInterpolateMultilineMarkdown() {
    let target =
        """
        - H3: INCONCLUSIVE

        Reproduction steps:
        1. Rebuild the app.
        2. Answer the pending debug input request.
        """

    #expect(!SloppyTUILiveDraftPolicy.shouldInterpolate(current: "", target: target))
}

@Test
func liveDraftPolicyDoesNotInterpolateNumberedListPrefix() {
    #expect(!SloppyTUILiveDraftPolicy.shouldInterpolate(current: "", target: "5. Answer the pending debug input request."))
}
