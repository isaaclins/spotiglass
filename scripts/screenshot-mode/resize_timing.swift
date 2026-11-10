// Times window resizes made from code, the way a window manager makes them (#473).
//
// Hammerspoon's `win:setFrame`, Rectangle and Magnet set the window's size, then its position, then
// its size again through the Accessibility API, and wait for the app to answer each call. A window
// that is slow to lay out makes every snap slow, while a drag by hand hides it: AppKit drops the
// sizes the app can't keep up with.
//
// usage: resize_timing <pid> [rounds] [steps] [max-ms-per-step]
// Prints the time of one resize and of an animated resize of <steps> steps (Hammerspoon's default
// 0.2 s animation makes about 12). With max-ms-per-step, exits 1 when the median step is slower.
import ApplicationServices
import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 2, let pid = pid_t(arguments[1]) else {
    FileHandle.standardError.write("usage: resize_timing <pid> [rounds] [steps] [max-ms-per-step]\n".data(using: .utf8)!)
    exit(2)
}
let rounds = arguments.count > 2 ? Int(arguments[2]) ?? 6 : 6
let steps = arguments.count > 3 ? Int(arguments[3]) ?? 12 : 12
let budget = arguments.count > 4 ? Double(arguments[4]) : nil

let app = AXUIElementCreateApplication(pid)
var windowsValue: CFTypeRef?
guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsValue) == .success,
      let window = (windowsValue as? [AXUIElement])?.first
else {
    FileHandle.standardError.write("resize_timing: no window (is Accessibility allowed for this terminal?)\n".data(using: .utf8)!)
    exit(1)
}

func setFrame(_ frame: CGRect) {
    var size = frame.size, origin = frame.origin
    AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &size)!)
    AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &origin)!)
    AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &size)!)
}

func seconds(_ body: () -> Void) -> Double {
    let start = Date()
    body()
    return Date().timeIntervalSince(start)
}

let wide = CGRect(x: 40, y: 40, width: 1400, height: 900)
let narrow = CGRect(x: 40, y: 40, width: 900, height: 700)
func between(_ progress: CGFloat) -> CGRect {
    CGRect(
        x: wide.minX, y: wide.minY,
        width: wide.width + (narrow.width - wide.width) * progress,
        height: wide.height + (narrow.height - wide.height) * progress
    )
}

setFrame(wide)
usleep(500_000)
var single: [Double] = []
for round in 0..<rounds {
    single.append(seconds { setFrame(round % 2 == 0 ? narrow : wide) })
    usleep(300_000)
}
setFrame(wide)
usleep(500_000)
var animated: [Double] = []
for round in 0..<rounds {
    animated.append(seconds {
        for step in 1...steps {
            let progress = CGFloat(step) / CGFloat(steps)
            setFrame(between(round % 2 == 0 ? progress : 1 - progress))
        }
    })
    usleep(300_000)
}

func summary(_ values: [Double]) -> String {
    let sorted = values.sorted()
    return String(format: "%.3f to %.3f s (median %.3f)", sorted.first!, sorted.last!, sorted[sorted.count / 2])
}
print("one resize:              \(summary(single))")
print("animated (\(steps) steps):     \(summary(animated))")
let medianStepMs = animated.sorted()[animated.count / 2] / Double(steps) * 1000
print(String(format: "median per step:         %.1f ms", medianStepMs))
if let budget, medianStepMs > budget {
    print(String(format: "slower than the %.0f ms budget per step", budget))
    exit(1)
}
