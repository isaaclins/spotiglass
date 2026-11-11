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

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write("resize_timing: \(message)\n".data(using: .utf8)!)
    exit(code)
}

let arguments = CommandLine.arguments
let usage = "usage: resize_timing <pid> [rounds >= 1] [steps >= 1] [max-ms-per-step]"
guard arguments.count >= 2, let pid = pid_t(arguments[1]) else { fail(usage, code: 2) }
func count(at index: Int, default value: Int) -> Int {
    guard arguments.count > index else { return value }
    guard let number = Int(arguments[index]), number >= 1 else { fail(usage, code: 2) }
    return number
}
let rounds = count(at: 2, default: 6)
let steps = count(at: 3, default: 12)
var budget: Double?
if arguments.count > 4 {
    guard let number = Double(arguments[4]), number > 0 else { fail(usage, code: 2) }
    budget = number
}

// The window a window manager acts on: the main window, not a floating one (the pop-out lyrics,
// Settings) that the app happens to list first.
let app = AXUIElementCreateApplication(pid)
var mainValue: CFTypeRef?
guard AXUIElementCopyAttributeValue(app, kAXMainWindowAttribute as CFString, &mainValue) == .success,
      let mainValue, CFGetTypeID(mainValue) == AXUIElementGetTypeID()
else { fail("no main window (is Accessibility allowed for this terminal, and is the app's main window open?)") }
let window = mainValue as! AXUIElement

func set(_ attribute: String, _ value: AXValue) {
    let result = AXUIElementSetAttributeValue(window, attribute as CFString, value)
    guard result == .success else { fail("setting \(attribute) failed (\(result.rawValue)); a full-screen window can't be resized") }
}

func setFrame(_ frame: CGRect) {
    var size = frame.size, origin = frame.origin
    set(kAXSizeAttribute, AXValueCreate(.cgSize, &size)!)
    set(kAXPositionAttribute, AXValueCreate(.cgPoint, &origin)!)
    set(kAXSizeAttribute, AXValueCreate(.cgSize, &size)!)
}

/// Fails when the window didn't take the size, so a run that resizes nothing can't pass.
func expectSize(_ expected: CGSize) {
    var value: CFTypeRef?
    var size = CGSize.zero
    guard AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &value) == .success,
          let value, AXValueGetValue(value as! AXValue, .cgSize, &size),
          abs(size.width - expected.width) <= 2, abs(size.height - expected.height) <= 2
    else { fail("the window is \(size.width)x\(size.height), not the \(expected.width)x\(expected.height) it was given") }
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

setFrame(narrow)
usleep(300_000)
expectSize(narrow.size)
setFrame(wide)
usleep(500_000)
expectSize(wide.size)
var single: [Double] = []
// Every timed resize reads the size back inside the timing. The read waits for the app like the
// window manager's next call does, so work the app puts off until after the set calls still
// counts, and a window that ignores or clamps a size can't make a run look fast.
for round in 0..<rounds {
    let target = round % 2 == 0 ? narrow : wide
    single.append(seconds {
        setFrame(target)
        expectSize(target.size)
    })
    usleep(300_000)
}
setFrame(wide)
usleep(500_000)
var animated: [Double] = []
for round in 0..<rounds {
    var total = 0.0
    for step in 1...steps {
        let progress = CGFloat(step) / CGFloat(steps)
        let target = between(round % 2 == 0 ? progress : 1 - progress)
        total += seconds {
            setFrame(target)
            expectSize(target.size)
        }
    }
    animated.append(total)
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
