import AppKit
import ImageIO
import UniformTypeIdentifiers

/// `PickPic --selftest <empty folder>` drives the review logic with made-up
/// photos and checks the results. Nothing goes to the real Trash.
@MainActor
enum SelfTest {
    static func run(in root: URL) -> Bool {
        let fm = FileManager.default
        let photos = root.appendingPathComponent("photos")
        let fakeTrash = root.appendingPathComponent("fake-trash")
        try? fm.removeItem(at: photos)
        try? fm.removeItem(at: fakeTrash)
        try! fm.createDirectory(at: photos, withIntermediateDirectories: true)
        try! fm.createDirectory(at: fakeTrash, withIntermediateDirectories: true)

        let shots: [(String, String)] = [
            ("a1", "2026:11:01 10:00:00"), ("a2", "2026:11:01 10:00:01"), ("a3", "2026:11:01 10:00:02"),
            ("b1", "2026:11:01 10:05:00"),
            ("c1", "2026:11:01 10:10:00"), ("c2", "2026:11:01 10:10:01"),
        ]
        for (n, (name, date)) in shots.enumerated() {
            makeJPEG(photos.appendingPathComponent(name + ".jpg"), date: date, gray: CGFloat(n) / 6)
        }
        // A RAW twin and a sidecar for a1: all three must travel together.
        try! Data("raw".utf8).write(to: photos.appendingPathComponent("a1.dng"))
        try! Data("xmp".utf8).write(to: photos.appendingPathComponent("a1.xmp"))

        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            print(ok ? "  ok    " : "  FAIL  ", what)
            if !ok { failures += 1 }
        }
        func finderTags(_ name: String, in dir: URL) -> [String] {
            (try? dir.appendingPathComponent(name).resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
        }

        let lib = Library()
        lib.trasher = { url in
            let dest = fakeTrash.appendingPathComponent(url.lastPathComponent)
            try fm.moveItem(at: url, to: dest)
            return dest
        }
        lib.open(photos, loadDatesInBackground: false)
        lib.applyDates(Library.captureDates(lib.items.map { ($0.id, $0.display) }))

        check(lib.items.map(\.id) == ["a1", "a2", "a3", "b1", "c1", "c2"], "six photos, in name order")
        check(lib.items[0].files.count == 3 && lib.items[0].display.pathExtension == "jpg", "RAW + JPEG + sidecar are one photo, shown as the JPEG")
        check(lib.items[0].burst != nil && lib.items[0].burst == lib.items[2].burst, "a1–a3 are one burst")
        check(lib.items[3].burst == nil, "b1 is not in a burst")
        check(lib.items[4].burst != nil && lib.items[4].burst != lib.items[0].burst, "c1–c2 are a second burst")

        lib.select(3)
        lib.handle(.char("3"))
        check(lib.items[3].rating == .lightEdit && lib.index == 4, "3 rates the photo and moves on")
        check(finderTags("b1.jpg", in: photos) == ["3 Light edit"], "Finder sees the tag “3 Light edit”")
        lib.undo()
        check(lib.items[3].rating == nil && lib.index == 3, "undo clears the rating and goes back")
        check(finderTags("b1.jpg", in: photos).isEmpty, "undo removes the Finder tag")

        lib.select(1)
        lib.handle(.char("w"))
        check(lib.mode == .showdown && lib.index == 0 && lib.right == 1, "W starts at the top of the burst")
        lib.handle(.right)
        check(lib.items[0].rating == .delete && lib.index == 2 && lib.right == 1, "→ rates the left photo 1 and brings in the next")
        check(["a1.jpg", "a1.dng", "a1.xmp"].allSatisfy { finderTags($0, in: photos) == ["1 Delete"] }, "all three a1 files got the tag")
        lib.undo()
        check(lib.items[0].rating == nil && lib.mode == .showdown && lib.index == 0, "undo steps back one round")
        lib.handle(.right)
        lib.handle(.left)
        check(lib.mode == .single && lib.index == 2 && lib.items[1].rating == .delete, "last round ends on the winner")
        lib.handle(.char("4"))
        check(lib.items[2].rating == .great && lib.index == 3, "rating the winner jumps past the burst")

        lib.handle(.char("c"))
        check(lib.mode == .compare && lib.index == 3 && lib.right == 4 && lib.activePane == 1, "C puts the next photo alongside")
        lib.handle(.char("2"))
        check(lib.items[4].rating == .heavyEdit && lib.right == 4, "rating in compare stays put")
        lib.handle(.right)
        check(lib.right == 5, "→ changes the outlined side only")
        lib.handle(.escape)
        check(lib.mode == .single && lib.index == 5, "Esc returns to one photo")

        lib.handle(.delete)
        check(lib.items.count == 5 && fm.fileExists(atPath: fakeTrash.appendingPathComponent("c2.jpg").path), "Delete trashes the photo")
        lib.undo()
        check(lib.items.count == 6 && fm.fileExists(atPath: photos.appendingPathComponent("c2.jpg").path), "undo brings it back")

        lib.select(4)
        lib.handle(.char("w"))
        lib.handle(.tab)
        lib.handle(.char("3"))
        check(lib.items[5].rating == .lightEdit && lib.mode == .single && lib.index == 4, "in pick-winner, Tab then 3 rates the right photo; the left one carries on")
        lib.undo()
        check(lib.items[5].rating == nil && lib.mode == .showdown && lib.activePane == 1, "undo puts that round back")
        lib.handle(.escape)

        lib.select(0)
        lib.handle(.char("f"))
        check(lib.unratedOnly && lib.index == 3, "F jumps to the first unrated photo")
        lib.handle(.right)
        check(lib.index == 5, "→ skips rated photos while the filter is on")
        lib.handle(.char("3"))
        check(lib.items[5].rating == .lightEdit && lib.index == 3, "rating wraps round to what is still unrated")
        lib.undo()
        lib.handle(.char("f"))
        check(!lib.unratedOnly && lib.items[5].rating == nil, "F again shows everything")

        lib.performFinish(trashOnes: true, move: [.great, .lightEdit])
        let edit = photos.appendingPathComponent(Library.editFolderName)
        check(fm.fileExists(atPath: edit.appendingPathComponent("a3.jpg").path), "Finish moved the 4 into “To Edit”")
        check(FinderTags.rating(of: edit.appendingPathComponent("a3.jpg")) == .great, "the tag moved with it")
        check(["a1.jpg", "a1.dng", "a1.xmp", "a2.jpg"].allSatisfy { fm.fileExists(atPath: fakeTrash.appendingPathComponent($0).path) }, "Finish trashed the 1s, RAW and sidecar included")
        check(lib.items.map(\.id) == ["b1", "c1", "c2"] && lib.items[1].rating == .heavyEdit, "the rest stayed, with ratings kept")

        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        return failures == 0
    }

    private static func makeJPEG(_ url: URL, date: String, gray: CGFloat) {
        let ctx = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(gray: gray, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        let props = [kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: date]] as CFDictionary
        CGImageDestinationAddImage(dest, ctx.makeImage()!, props)
        CGImageDestinationFinalize(dest)
    }
}
