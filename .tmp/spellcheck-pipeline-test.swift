// Two-arm test:
//   1. Does AppKit's continuous spell-check pass WRITE .spellingState to the
//      NSTextLayoutManager on macOS 15.7.7? We read renderingAttributes back.
//   2. If we MANUALLY write .spellingState via addRenderingAttribute, does
//      the underline appear? This is the viability test for EdgeMark's
//      Option A (manual driver) regardless of question 1.
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

func analyze(_ rep: NSBitmapImageRep, label: String) {
    var red = 0
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            let r = c.redComponent, g = c.greenComponent, b = c.blueComponent
            if r > 0.55 && g < 0.5 && b < 0.5 { red += 1 }
        }
    }
    print("\(label): red=\(red)")
}

func countSystemSpellingStates(_ tlm: NSTextLayoutManager, label: String) {
    let documentRange = tlm.documentRange
    var states: [(NSRange, Int)] = []
    tlm.enumerateRenderingAttributes(from: documentRange.location, reverse: false) { (tlm2, attrs, range) -> Bool in
        if let s = attrs[.spellingState] as? Int {
            let loc = tlm2.offset(from: documentRange.location, to: range.location)
            let len = tlm2.offset(from: range.location, to: range.endLocation)
            let nsRange = NSRange(location: loc, length: len)
            states.append((nsRange, s))
        }
        return true
    }
    print("\(label): system-wrote .spellingState entries = \(states.count)")
    for (r, v) in states { print("  range=\(r.location)+\(r.length) value=\(v)") }
}

func run(label: String, insertManual: Bool) {
    let storage = NSTextContentStorage()
    let tlm = NSTextLayoutManager()
    let container = NSTextContainer(size: CGSize(width: 400, height: 200))
    tlm.textContainer = container
    storage.addTextLayoutManager(tlm)

    let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
    tv.isEditable = true
    tv.isContinuousSpellCheckingEnabled = true
    tv.backgroundColor = .white
    tv.textColor = .black
    tv.font = NSFont.systemFont(ofSize: 16)

    let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 400, height: 200),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = tv
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(tv)
    tv.insertText("helllo wrold misspeled", replacementRange: NSRange(location: 0, length: 0))

    // Give continuous spell-check time to run.
    RunLoop.current.run(until: Date().addingTimeInterval(3.0))
    tv.needsDisplay = true
    tv.displayIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))

    // Question 1: did the system write .spellingState?
    countSystemSpellingStates(tlm, label: "\(label) [after system pass]")

    // Question 2: manually write .spellingState on the first misspelled word.
    if insertManual {
        let docRange = tlm.documentRange
        // "helllo" is at offset 0, length 6.
        let endLoc = tlm.location(docRange.location, offsetBy: 6)!
        let manualRange = NSTextRange(location: docRange.location, end: endLoc)!
        tlm.addRenderingAttribute(.spellingState, value: 1, for: manualRange)
        print("\(label): manually wrote .spellingState:1 on 0..<6")
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    tv.needsDisplay = true
    tv.displayIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))

    guard let rep = tv.bitmapImageRepForCachingDisplay(in: tv.bounds) else {
        print("\(label): no bitmap")
        window.orderOut(nil)
        return
    }
    tv.cacheDisplay(in: tv.bounds, to: rep)
    analyze(rep, label: label)
    if let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: "/tmp/spellcheck_\(label).png"))
    }
    window.orderOut(nil)
}

// Arm A: system pass only (question 1 only)
run(label: "A_systemOnly", insertManual: false)
// Arm B: system pass + manual write (questions 1 + 2)
run(label: "B_withManual", insertManual: true)
