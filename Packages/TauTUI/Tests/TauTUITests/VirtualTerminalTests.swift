import Testing
@testable import TauTUI
@testable import TauTUIInternal

@Suite("VirtualTerminal helpers")
struct VirtualTerminalTests {
    @Test
    func viewportTracksWrites() throws {
        let terminal = VirtualTerminal(columns: 10, rows: 3)
        terminal.write("one\n")
        terminal.write("two\n")
        let viewport = terminal.getViewport()
        #expect(viewport.suffix(2) == ["one", "two"])
    }

    @Test
    func scrollBufferIncludesPendingLine() throws {
        let terminal = VirtualTerminal(columns: 5, rows: 2)
        terminal.write("abc")
        let viewport = terminal.getViewport()
        #expect(viewport.last?.contains("abc") == true)
        #expect(terminal.getScrollBuffer().last == "abc")
    }

    @Test
    func clearSequenceResetsScrollback() throws {
        let terminal = VirtualTerminal(columns: 5, rows: 2)
        terminal.write("hello\n")
        terminal.write(ANSI.clearScrollbackAndScreen)
        terminal.write("world\n")
        #expect(terminal.getScrollBuffer() == ["world"])
    }
}
