import Testing
@testable import sloppy

@Test
func desktopNotificationServiceDedupesRepeatedAttentionKeys() async {
    let service = DesktopNotificationService(
        driver: NoopDesktopNotificationDriver(),
        dedupeWindow: 60
    )

    let first = await service.notify(
        category: "input_required",
        title: "Input required",
        metadata: ["sessionId": "session-1"]
    )
    let second = await service.notify(
        category: "input_required",
        title: "Input required",
        metadata: ["sessionId": "session-1"]
    )

    #expect(first == true)
    #expect(second == false)
}

#if os(macOS)
@Test
func macOSDesktopNotificationEscapesAppleScriptLiteral() {
    let request = DesktopNotificationRequest(
        category: "test",
        title: #"Sloppy "quoted""#,
        body: "Line 1\nLine 2 \\ path"
    )
    let arguments = MacOSDesktopNotificationDriver.arguments(for: request)

    #expect(arguments.first == "-e")
    let script = arguments.dropFirst().first ?? ""
    #expect(script.contains(#"\"quoted\""#))
    #expect(script.contains(#"Line 1\nLine 2 \\ path"#))
    #expect(!script.contains("Line 1\nLine 2"))
}
#endif
