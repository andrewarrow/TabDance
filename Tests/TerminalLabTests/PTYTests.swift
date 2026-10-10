import Darwin
import XCTest
import SwiftTerm

final class PTYTests: XCTestCase {
    func testInteractivePTYAndResizeDimensions() {
        let finished = expectation(description: "shell exited")
        let receivedReply = expectation(description: "shell echoed input")
        let delegate = Probe(finished: finished, receivedReply: receivedReply)
        let process = LocalProcess(delegate: delegate)
        delegate.process = process
        process.startProcess(
            executable: "/bin/sh",
            args: ["-c", "test -t 0 && printf 'TTY_OK\\n'; stty size; printf '\\033[31mRED\\033[0m\\nREADY\\n'; read reply; stty size; printf 'ECHO:%s\\n' \"$reply\""],
            currentDirectory: FileManager.default.homeDirectoryForCurrentUser.path
        )
        XCTAssertTrue(process.running)
        let pid = process.shellPid
        defer {
            process.terminate()
            if pid > 0 {
                // SwiftTerm can report process termination before a nonblocking wait reaps the child.
                var status: Int32 = 0
                _ = waitpid(pid, &status, WNOHANG)
            }
        }
        wait(for: [receivedReply, finished], timeout: 10)
        XCTAssertTrue(delegate.output.contains("TTY_OK"))
        XCTAssertTrue(delegate.output.contains("24 80"))
        XCTAssertTrue(delegate.output.contains("32 100"))
        XCTAssertTrue(delegate.output.contains("\u{1B}[31mRED\u{1B}[0m"))
        XCTAssertTrue(delegate.output.contains("ECHO:ping"))
        XCTAssertEqual(delegate.resizeStatus, 0)
        XCTAssertEqual(delegate.exitCode, 0)
    }

    func testCursorColorAndAlternateScreenParsing() {
        let sink = Sink()
        let terminal = Terminal(delegate: sink, options: TerminalOptions(cols: 80, rows: 24))
        terminal.feed(text: "hello\u{1B}[2DXY")
        XCTAssertTrue(String(decoding: terminal.getBufferAsData(), as: UTF8.self).contains("helXY"))

        terminal.feed(text: "\r\n\u{1B}[38;5;196mR")
        XCTAssertEqual(terminal.getCharData(col: 0, row: 1)?.attribute.fg, .ansi256(code: 196))

        terminal.feed(text: "\u{1B}[?1049hALT")
        XCTAssertTrue(String(decoding: terminal.getBufferAsData(), as: UTF8.self).contains("ALT"))
        XCTAssertFalse(String(decoding: terminal.getBufferAsData(kind: .normal), as: UTF8.self).contains("ALT"))
        terminal.feed(text: "\u{1B}[?1049l")
        XCTAssertTrue(String(decoding: terminal.getBufferAsData(), as: UTF8.self).contains("helXY"))
    }

    private final class Sink: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    private final class Probe: LocalProcessDelegate {
        weak var process: LocalProcess?
        let finished: XCTestExpectation
        let receivedReply: XCTestExpectation
        var output = ""
        var sentInput = false
        var resizeStatus: Int32 = -1
        var exitCode: Int32?
        var sawReply = false

        init(finished: XCTestExpectation, receivedReply: XCTestExpectation) {
            self.finished = finished
            self.receivedReply = receivedReply
        }

        func getWindowSize() -> winsize {
            winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        }

        func dataReceived(slice: ArraySlice<UInt8>) {
            output += String(decoding: slice, as: UTF8.self)
            if output.contains("READY") && !sentInput {
                sentInput = true
                var size = winsize(ws_row: 32, ws_col: 100, ws_xpixel: 0, ws_ypixel: 0)
                if let process {
                    resizeStatus = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: process.childfd, windowSize: &size)
                }
                let input = Array("ping\n".utf8)
                process?.send(data: input[...])
            }
            if output.contains("ECHO:ping") && !sawReply {
                sawReply = true
                receivedReply.fulfill()
            }
        }

        func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
            self.exitCode = exitCode
            finished.fulfill()
        }
    }
}
