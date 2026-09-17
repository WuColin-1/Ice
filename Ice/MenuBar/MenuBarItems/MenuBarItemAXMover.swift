//
//  MenuBarItemAXMover.swift
//  Ice
//

import Cocoa

/// Di chuyển menu bar item bằng cách giả lập Command-drag của người dùng.
///
/// Pipeline move cũ của Ice cần CGS window (windowID, ownerPID, frame change)
/// nên không còn hoạt động trên macOS 27. Cách này chỉ cần vị trí icon trên
/// màn hình (đọc từ AX) và quyền Accessibility — đúng thao tác mà người dùng
/// vẫn làm bằng tay, nên hệ thống vẫn nhận.
enum MenuBarItemAXMover {
    /// Kéo từ `source` tới `destination` trong khi giữ Command.
    ///
    /// Tọa độ Cocoa (origin bottom-left). Chạy nền, mất khoảng 1 giây.
    /// Không trả chuột về chỗ cũ — giống hệt người dùng kéo thật.
    static func commandDrag(from source: CGPoint, to destination: CGPoint) async {
        await Task.detached(priority: .userInitiated) {
            guard let eventSource = CGEventSource(stateID: .hidSystemState) else {
                return
            }

            // Đưa chuột tới icon trước để hệ thống "thấy" điểm bắt đầu.
            guard
                let mouseMoved = CGEvent(
                    mouseEventSource: eventSource,
                    mouseType: .mouseMoved,
                    mouseCursorPosition: source,
                    mouseButton: .left
                )
            else {
                return
            }
            mouseMoved.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.2)

            // Nhấn Command (flagsChanged) như người dùng giữ phím.
            guard
                let commandDown = CGEvent(
                    mouseEventSource: eventSource,
                    mouseType: .flagsChanged,
                    mouseCursorPosition: source,
                    mouseButton: .left
                )
            else {
                return
            }
            commandDown.flags = .maskCommand
            commandDown.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.15)

            guard
                let mouseDown = CGEvent(
                    mouseEventSource: eventSource,
                    mouseType: .leftMouseDown,
                    mouseCursorPosition: source,
                    mouseButton: .left
                )
            else {
                return
            }
            mouseDown.flags = .maskCommand
            mouseDown.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.2)

            let steps = 30
            for index in 1...steps {
                let progress = CGFloat(index) / CGFloat(steps)
                let point = CGPoint(
                    x: source.x + (destination.x - source.x) * progress,
                    y: source.y + (destination.y - source.y) * progress
                )
                guard
                    let drag = CGEvent(
                        mouseEventSource: eventSource,
                        mouseType: .leftMouseDragged,
                        mouseCursorPosition: point,
                        mouseButton: .left
                    )
                else {
                    break
                }
                drag.flags = .maskCommand
                drag.post(tap: .cghidEventTap)
                Thread.sleep(forTimeInterval: 0.02)
            }

            guard
                let mouseUp = CGEvent(
                    mouseEventSource: eventSource,
                    mouseType: .leftMouseUp,
                    mouseCursorPosition: destination,
                    mouseButton: .left
                )
            else {
                return
            }
            mouseUp.flags = .maskCommand
            mouseUp.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.2)

            // Nhả Command.
            guard
                let commandUp = CGEvent(
                    mouseEventSource: eventSource,
                    mouseType: .flagsChanged,
                    mouseCursorPosition: destination,
                    mouseButton: .left
                )
            else {
                return
            }
            commandUp.flags = []
            commandUp.post(tap: .cghidEventTap)
            // Đợi hệ thống commit vị trí mới trước khi trả về.
            Thread.sleep(forTimeInterval: 0.8)
        }.value
    }
}
