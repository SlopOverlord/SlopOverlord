import Testing
@testable import Core

@Test
func parsesPickUpNumericReference() {
    let reference = TaskApprovalCommandParser.parse("pick up #3")
    #expect(reference == .index(3))
}

@Test
func parsesPickUpUUIDReference() {
    let uuid = "15B6E7A7-71C0-4DC4-83EF-8BA2A2A421E4"
    let reference = TaskApprovalCommandParser.parse("pickup #\(uuid)")
    #expect(reference == .taskID(uuid))
}

@Test
func rejectsUnsupportedText() {
    let reference = TaskApprovalCommandParser.parse("please pick this task")
    #expect(reference == nil)
}
