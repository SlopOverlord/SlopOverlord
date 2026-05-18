import Testing
@testable import sloppy

@Test
func sendProgressShowsPreparationDetailsForLargeMessage() {
    let progress = SloppyTUISendProgress(
        stage: .preparing,
        attachmentCount: 2,
        inlineReferenceCount: 3,
        contentCharacters: 12_345
    )

    #expect(progress.statusLine == "Preparing message (2 attachments, 3 @paths, 12345 chars)...")
}

@Test
func sendProgressUsesSimpleBusyLineWhenNoDetailsAreKnown() {
    let progress = SloppyTUISendProgress(stage: .sending)

    #expect(progress.statusLine == "Sending request...")
}

@Test
func sendProgressPluralizesSingleAttachmentAndPath() {
    let progress = SloppyTUISendProgress(
        stage: .refreshing,
        attachmentCount: 1,
        inlineReferenceCount: 1,
        contentCharacters: nil
    )

    #expect(progress.statusLine == "Refreshing session (1 attachment, 1 @path)...")
}
