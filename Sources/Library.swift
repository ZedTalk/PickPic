import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One photo. A RAW+JPEG pair (and any sidecar) counts as a single photo,
/// so its files are always rated, moved and trashed together.
struct PhotoItem: Identifiable {
    let id: String
    let name: String
    let display: URL
    let files: [URL]
    var rating: Rating?
    var date: Date?
    var burst: Int?
}

enum Mode { case single, compare, showdown }

enum Key: Equatable {
    case left, right, up, down, delete, escape, tab, space
    case char(Character)
}

final class ZoomState: ObservableObject {
    @Published var on = false
    @Published var center = CGPoint(x: 0.5, y: 0.5)
}

@MainActor
final class Library: ObservableObject {
    @Published var folder: URL?
    @Published var items: [PhotoItem] = []
    /// The photo in the left (or only) pane.
    @Published var index = 0
    /// The photo in the right pane while comparing.
    @Published var right: Int?
    @Published var activePane = 0
    @Published var mode: Mode = .single
    @Published var toast: String?
    @Published var showFinish = false
    @Published var showHelp = false
    /// Hide photos that already have a rating.
    @Published var unratedOnly = false
    /// Hide the bars and filmstrip so the photo fills the window.
    @Published var chromeHidden = false
    @Published var showInfo = UserDefaults.standard.object(forKey: "showInfo") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showInfo, forKey: "showInfo") }
    }

    let zoom = ZoomState()

    static weak var current: Library?
    init() { Library.current = self }

    // Pick-a-winner state
    private(set) var sdNext = 0
    private(set) var sdEnd = 0
    private(set) var champSlot = 0
    private var pendingAdvance: Int?

    private struct Snapshot {
        var mode: Mode, index: Int, right: Int?, activePane: Int
        var sdNext: Int, sdEnd: Int, champSlot: Int, pendingAdvance: Int?
    }
    private struct UndoEntry { let name: String; let snap: Snapshot; let revert: () -> Void }
    private var undoStack: [UndoEntry] = []

    private var generation = 0
    private var toastToken = 0
    private var monitor: Any?

    /// Replaceable so the self-test never touches the real Trash.
    var trasher: (URL) throws -> URL? = { url in
        var out: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &out)
        return out as URL?
    }

    static let editFolderName = "To Edit"

    var autoAdvance: Bool { UserDefaults.standard.object(forKey: "autoAdvance") as? Bool ?? true }
    var burstGap: Double {
        let v = UserDefaults.standard.double(forKey: "burstGap")
        return v > 0 ? v : 3
    }

    // MARK: Opening a folder

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Review Photos"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func reopenLast() {
        guard folder == nil, let path = UserDefaults.standard.string(forKey: "lastFolder") else { return }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            open(URL(fileURLWithPath: path))
        }
    }

    /// Accepts a folder, or a photo (opens its folder and jumps to it).
    func openDropped(_ url: URL) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
        if isDir.boolValue {
            open(url)
        } else {
            open(url.deletingLastPathComponent())
            let key = url.deletingPathExtension().lastPathComponent.lowercased()
            if let i = items.firstIndex(where: { $0.id == key }) { index = i }
        }
    }

    func open(_ url: URL, loadDatesInBackground: Bool = true) {
        generation += 1
        folder = url
        UserDefaults.standard.set(url.path, forKey: "lastFolder")
        items = Self.scan(url)
        mode = .single
        right = nil
        activePane = 0
        pendingAdvance = nil
        undoStack.removeAll()
        zoom.on = false
        // Pick up where you left off: the first photo with no rating yet.
        index = items.firstIndex(where: { $0.rating == nil }) ?? 0
        if loadDatesInBackground { loadDates() }
    }

    private static let sidecars: Set<String> = ["xmp", "aae"]
    private static let skipped: Set<String> = ["svg", "pdf", "ico", "icns"]

    nonisolated static func scan(_ folder: URL) -> [PhotoItem] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
        var kinds: [String: (image: Bool, raw: Bool)] = [:]
        func kind(_ ext: String) -> (image: Bool, raw: Bool) {
            if let k = kinds[ext] { return k }
            var k = (image: false, raw: false)
            if !skipped.contains(ext), let t = UTType(filenameExtension: ext), t.conforms(to: .image) {
                k = (true, t.conforms(to: .rawImage))
            }
            kinds[ext] = k
            return k
        }
        var groups: [String: [URL]] = [:]
        for u in urls {
            let ext = u.pathExtension.lowercased()
            guard kind(ext).image || sidecars.contains(ext) else { continue }
            groups[u.deletingPathExtension().lastPathComponent.lowercased(), default: []].append(u)
        }
        var out: [PhotoItem] = []
        for (key, files) in groups {
            let images = files.filter { kind($0.pathExtension.lowercased()).image }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            // Show the JPEG/HEIC of a pair when there is one: it loads faster.
            guard let display = images.first(where: { !kind($0.pathExtension.lowercased()).raw }) ?? images.first
            else { continue }
            let rating = FinderTags.rating(of: display) ?? images.lazy.compactMap { FinderTags.rating(of: $0) }.first
            let name = images.count > 1
                ? display.deletingPathExtension().lastPathComponent + " (" +
                    images.map { $0.pathExtension.uppercased() }.joined(separator: "+") + ")"
                : display.lastPathComponent
            out.append(PhotoItem(id: key, name: name, display: display, files: files, rating: rating))
        }
        return out.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    // MARK: Bursts (photos shot within a few seconds of each other)

    private func loadDates() {
        let gen = generation
        let list = items.map { ($0.id, $0.display) }
        Task.detached(priority: .utility) {
            let dates = Self.captureDates(list)
            await MainActor.run {
                guard gen == self.generation else { return }
                self.applyDates(dates)
            }
        }
    }

    nonisolated static func captureDates(_ list: [(String, URL)]) -> [String: Date] {
        var out: [String: Date] = [:]
        for (id, url) in list { if let d = ImageLoader.captureDate(url) { out[id] = d } }
        return out
    }

    func applyDates(_ dates: [String: Date]) {
        var copy = items
        for k in copy.indices {
            copy[k].date = dates[copy[k].id]
            copy[k].burst = nil
        }
        let gap = burstGap
        var id = 0, i = 0
        while i < copy.count {
            var j = i
            while j + 1 < copy.count, let a = copy[j].date, let b = copy[j + 1].date,
                  abs(b.timeIntervalSince(a)) <= gap { j += 1 }
            if j > i {
                id += 1
                for k in i...j { copy[k].burst = id }
            }
            i = j + 1
        }
        items = copy
    }

    func burstRange(at i: Int) -> ClosedRange<Int> {
        guard items.indices.contains(i), let b = items[i].burst else { return i...i }
        var lo = i, hi = i
        while lo > 0, items[lo - 1].burst == b { lo -= 1 }
        while hi + 1 < items.count, items[hi + 1].burst == b { hi += 1 }
        return lo...hi
    }

    // MARK: Counts

    var ratedCount: Int { items.reduce(0) { $0 + ($1.rating == nil ? 0 : 1) } }
    func count(_ r: Rating) -> Int { items.reduce(0) { $0 + ($1.rating == r ? 1 : 0) } }

    // MARK: Unrated-only filter

    var unratedCount: Int { items.count - ratedCount }

    private func allowed(_ i: Int) -> Bool { !unratedOnly || items[i].rating == nil }

    /// The next photo in that direction, skipping rated ones while the filter is on.
    private func nextAllowed(from i: Int, step d: Int, skipping other: Int? = nil) -> Int? {
        var t = i + d
        while items.indices.contains(t) {
            if t != other, allowed(t) { return t }
            t += d
        }
        return nil
    }

    func toggleUnratedOnly() {
        unratedOnly.toggle()
        guard unratedOnly else { say("Showing all photos"); return }
        guard unratedCount > 0 else { say("Everything here is rated."); return }
        if mode == .single, items.indices.contains(index), items[index].rating != nil {
            index = nextAllowed(from: index, step: 1) ?? nextAllowed(from: index, step: -1) ?? index
        }
        say("Showing only unrated photos: \(unratedCount) left")
    }

    // MARK: Undo

    private func snapshot() -> Snapshot {
        Snapshot(mode: mode, index: index, right: right, activePane: activePane,
                 sdNext: sdNext, sdEnd: sdEnd, champSlot: champSlot, pendingAdvance: pendingAdvance)
    }

    private func push(_ name: String, _ snap: Snapshot, _ revert: @escaping () -> Void) {
        undoStack.append(UndoEntry(name: name, snap: snap, revert: revert))
        if undoStack.count > 200 { undoStack.removeFirst() }
    }

    func undo() {
        guard let e = undoStack.popLast() else { say("Nothing to undo"); return }
        e.revert()
        let s = e.snap
        let last = max(items.count - 1, 0)
        mode = s.mode
        index = min(s.index, last)
        right = s.right.map { min($0, last) }
        activePane = s.activePane
        sdNext = s.sdNext; sdEnd = s.sdEnd; champSlot = s.champSlot
        pendingAdvance = s.pendingAdvance
        say("Undid: \(e.name)")
    }

    func say(_ text: String) {
        toast = text
        toastToken += 1
        let token = toastToken
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if token == self.toastToken { self.toast = nil }
        }
    }

    // MARK: Rating

    /// Writes the tag to every file of the photo. Returns false if the disk refused.
    @discardableResult
    private func apply(_ r: Rating?, to i: Int) -> Bool {
        var ok = true
        for f in items[i].files {
            do { try FinderTags.setRating(r, on: f) } catch { ok = false }
        }
        if ok { items[i].rating = r } else { say("Couldn't write the tag. Is this disk read-only?") }
        return ok
    }

    private func rate(_ r: Rating?, at i: Int) -> Bool {
        guard items.indices.contains(i) else { return false }
        let old = items[i].rating, id = items[i].id, snap = snapshot()
        guard apply(r, to: i) else { return false }
        push(r.map { "rated \($0.rawValue)" } ?? "cleared rating", snap) { [weak self] in
            guard let self, let j = self.items.firstIndex(where: { $0.id == id }) else { return }
            self.apply(old, to: j)
        }
        return true
    }

    private func rateCurrent(_ r: Rating?) {
        switch mode {
        case .single:
            guard rate(r, at: index), r != nil, autoAdvance else { return }
            let from = pendingAdvance.map { $0 - 1 } ?? index
            pendingAdvance = nil
            if let t = nextAllowed(from: from, step: 1) ?? (unratedOnly ? nextAllowed(from: -1, step: 1) : nil) {
                index = t
            } else {
                say(unratedOnly ? "Nothing left unrated. Finish with ⌘↩ when ready."
                                : "That was the last photo. Finish with ⌘↩ when ready.")
            }
        case .compare:
            _ = rate(r, at: activePane == 0 ? index : (right ?? index))
        case .showdown:
            break
        }
    }

    // MARK: Moving around

    func select(_ i: Int) {
        guard items.indices.contains(i) else { return }
        pendingAdvance = nil
        switch mode {
        case .single: index = i
        case .compare: if activePane == 0 { index = i } else { right = i }
        case .showdown: break
        }
    }

    private func step(_ d: Int) {
        pendingAdvance = nil
        switch mode {
        case .single:
            if let t = nextAllowed(from: index, step: d) { index = t }
            else if unratedOnly { say("No more unrated photos that way.") }
        case .compare:
            // Never show the same photo on both sides.
            let other = activePane == 0 ? (right ?? -1) : index
            let current = activePane == 0 ? index : (right ?? index)
            guard let t = nextAllowed(from: current, step: d, skipping: other) else { return }
            if activePane == 0 { index = t } else { right = t }
        case .showdown:
            break
        }
    }

    private func nextUnrated() {
        guard mode == .single else { return }
        let n = items.count
        for off in 1...n where items[(index + off) % n].rating == nil {
            index = (index + off) % n
            return
        }
        say("Everything here is rated.")
    }

    // MARK: Side-by-side compare

    func toggleCompare() {
        switch mode {
        case .compare:
            index = activePane == 0 ? index : (right ?? index)
            right = nil; activePane = 0; mode = .single
        case .single:
            guard items.count > 1 else { say("Need at least two photos to compare."); return }
            right = index + 1 < items.count ? index + 1 : index - 1
            activePane = 1
            mode = .compare
        case .showdown:
            break
        }
    }

    // MARK: Pick a winner

    /// Runs a head-to-head through the current burst (or onward from this
    /// photo if it isn't in one). Each round the loser is rated 1.
    func startShowdown() {
        guard mode == .single, items.indices.contains(index) else { return }
        let inBurst = items[index].burst != nil
        let range = inBurst ? burstRange(at: index) : index...(items.count - 1)
        guard range.count >= 2 else { say("No later photo to compare this one with."); return }
        pendingAdvance = nil
        index = range.lowerBound
        right = range.lowerBound + 1
        sdNext = range.lowerBound + 2
        sdEnd = range.upperBound
        champSlot = 0
        activePane = 0
        mode = .showdown
        say(inBurst ? "Picking the best of \(range.count). ← or → keeps that photo."
                    : "Not a burst, so this runs until you press Esc.")
    }

    var showdownRemaining: Int { max(sdEnd - sdNext + 1, 0) }

    private func pick(slot: Int) {
        guard mode == .showdown, let r = right else { return }
        let loser = slot == 0 ? r : index
        let old = items[loser].rating, id = items[loser].id, snap = snapshot()
        guard apply(.delete, to: loser) else { return }
        push("pick", snap) { [weak self] in
            guard let self, let j = self.items.firstIndex(where: { $0.id == id }) else { return }
            self.apply(old, to: j)
        }
        champSlot = slot
        advanceShowdown(replacing: 1 - slot)
    }

    /// Rates the outlined photo and takes it out of the contest; the other
    /// photo carries on against the next one.
    private func rateInShowdown(_ r: Rating) {
        guard mode == .showdown, let rt = right else { return }
        let slot = activePane
        let i = slot == 0 ? index : rt
        let old = items[i].rating, id = items[i].id, snap = snapshot()
        guard apply(r, to: i) else { return }
        push("rated \(r.rawValue)", snap) { [weak self] in
            guard let self, let j = self.items.firstIndex(where: { $0.id == id }) else { return }
            self.apply(old, to: j)
        }
        champSlot = 1 - slot
        advanceShowdown(replacing: slot)
    }

    private func keepBoth() {
        guard mode == .showdown else { return }
        push("keep both", snapshot()) {}
        advanceShowdown(replacing: 1 - champSlot)
    }

    private func advanceShowdown(replacing slot: Int) {
        guard sdNext <= sdEnd else { endShowdown(finished: true); return }
        if slot == 0 { index = sdNext } else { right = sdNext }
        sdNext += 1
    }

    private func endShowdown(finished: Bool) {
        let winner = champSlot == 0 ? index : (right ?? index)
        mode = .single
        index = winner
        right = nil
        activePane = 0
        if finished {
            pendingAdvance = sdEnd + 1
            say("Winner picked. Now rate it 2, 3 or 4.")
        }
    }

    // MARK: Trash right now

    private func trashCurrent() {
        guard mode == .single, items.indices.contains(index) else {
            say("Press 1 to mark it for deletion instead.")
            return
        }
        let item = items[index], i = index, snap = snapshot()
        var moved: [(from: URL, to: URL)] = []
        for f in item.files {
            do {
                if let out = try trasher(f) { moved.append((f, out)) }
            } catch {
                say("Couldn't move \(f.lastPathComponent) to the Trash.")
            }
        }
        guard !moved.isEmpty else { return }
        items.remove(at: i)
        index = min(i, max(items.count - 1, 0))
        push("moved to Trash", snap) { [weak self] in
            guard let self else { return }
            for m in moved { try? FileManager.default.moveItem(at: m.to, to: m.from) }
            self.items.insert(item, at: min(i, self.items.count))
        }
    }

    // MARK: Finish

    /// Trashes the 1s and moves the chosen ratings into "To Edit".
    func performFinish(trashOnes: Bool, move: Set<Rating>) {
        guard let folder else { return }
        if mode != .single { endShowdown(finished: false) }
        let fm = FileManager.default
        let dest = folder.appendingPathComponent(Self.editFolderName, isDirectory: true)
        var moved = 0, trashed = 0, failed = 0
        for item in items {
            guard let r = item.rating else { continue }
            if r == .delete, trashOnes {
                var ok = true
                for f in item.files { do { _ = try trasher(f) } catch { ok = false } }
                if ok { trashed += 1 } else { failed += 1 }
            } else if r != .delete, move.contains(r) {
                var ok = true
                do {
                    try fm.createDirectory(at: dest, withIntermediateDirectories: true)
                    for f in item.files { try fm.moveItem(at: f, to: Self.freeURL(dest.appendingPathComponent(f.lastPathComponent))) }
                } catch { ok = false }
                if ok { moved += 1 } else { failed += 1 }
            }
        }
        open(folder)
        var parts: [String] = []
        if moved > 0 { parts.append("moved \(moved) to “\(Self.editFolderName)”") }
        if trashed > 0 { parts.append("sent \(trashed) to the Trash") }
        if failed > 0 { parts.append("\(failed) could not be moved") }
        say(parts.isEmpty ? "Nothing to do." : "Done: " + parts.joined(separator: ", ") + ".")
    }

    private static func freeURL(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        for n in 2..<1000 {
            let candidate = url.deletingLastPathComponent()
                .appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }

    // MARK: Keyboard

    @discardableResult
    func handle(_ key: Key) -> Bool {
        if showHelp { showHelp = false; return true }
        guard !items.isEmpty else { return false }

        switch key {
        case .char("z"):
            zoom.on.toggle(); return true
        case .char("?"), .char("/"):
            showHelp = true; return true
        case .char("f"):
            toggleUnratedOnly(); return true
        case .char("i"):
            showInfo.toggle(); return true
        case .char("h"):
            chromeHidden.toggle()
            if chromeHidden { say("Bars hidden. Press H to bring them back.") }
            return true
        default: break
        }

        switch mode {
        case .single:
            switch key {
            case .left, .up: step(-1)
            case .right, .down, .space: step(1)
            case .char("1"): rateCurrent(.delete)
            case .char("2"): rateCurrent(.heavyEdit)
            case .char("3"): rateCurrent(.lightEdit)
            case .char("4"): rateCurrent(.great)
            case .char("0"): rateCurrent(nil)
            case .delete: trashCurrent()
            case .char("c"): toggleCompare()
            case .char("w"): startShowdown()
            case .char("u"): nextUnrated()
            case .escape:
                if zoom.on { zoom.on = false }
                else if chromeHidden { chromeHidden = false }
                else { return false }
            default: return false
            }
        case .compare:
            switch key {
            case .left, .up: step(-1)
            case .right, .down: step(1)
            case .tab, .space: activePane = 1 - activePane
            case .char("1"): rateCurrent(.delete)
            case .char("2"): rateCurrent(.heavyEdit)
            case .char("3"): rateCurrent(.lightEdit)
            case .char("4"): rateCurrent(.great)
            case .char("0"): rateCurrent(nil)
            case .char("c"), .escape: toggleCompare()
            case .delete: trashCurrent()
            default: return false
            }
        case .showdown:
            switch key {
            case .left: pick(slot: 0)
            case .right: pick(slot: 1)
            case .space, .down, .up: keepBoth()
            case .tab: activePane = 1 - activePane
            case .char("1"): rateInShowdown(.delete)
            case .char("2"): rateInShowdown(.heavyEdit)
            case .char("3"): rateInShowdown(.lightEdit)
            case .char("4"): rateInShowdown(.great)
            case .escape, .char("w"): endShowdown(finished: false)
            case .delete: trashCurrent()
            default: return false
            }
        }
        return true
    }

    func installKeyMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = event.window,
                  !(window is NSPanel), window.sheetParent == nil, window.attachedSheet == nil
            else { return event }
            let mods = event.modifierFlags.intersection([.command, .control, .option])
            let isDelete = event.keyCode == 51 || event.keyCode == 117
            if !mods.isEmpty && !(mods == .command && isDelete) { return event }
            let key: Key
            switch event.keyCode {
            case 123: key = .left
            case 124: key = .right
            case 125: key = .down
            case 126: key = .up
            case 51, 117: key = .delete
            case 53: key = .escape
            case 48: key = .tab
            case 49: key = .space
            default:
                guard let c = event.charactersIgnoringModifiers?.lowercased().first else { return event }
                key = .char(c)
            }
            let handled = MainActor.assumeIsolated { self.handle(key) }
            return handled ? nil : event
        }
    }
}
