import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var lib: Library

    var body: some View {
        VStack(spacing: 0) {
            if !lib.chromeHidden {
                TopBar()
                ProgressLine()
                if let folder = lib.folder { PathBar(folder: folder) }
            }
            if lib.items.indices.contains(lib.index) {
                if lib.mode == .showdown { ShowdownBanner() }
                HStack(spacing: 2) {
                    PhotoPane(item: lib.items[lib.index], slot: 0).id(lib.items[lib.index].id)
                    if let r = lib.right, lib.items.indices.contains(r) {
                        PhotoPane(item: lib.items[r], slot: 1).id(lib.items[r].id)
                    }
                }
                if !lib.chromeHidden {
                    Filmstrip()
                    HintBar()
                }
            } else {
                EmptyState()
            }
        }
        .background(Color.black)
        .overlay(alignment: .bottom) {
            if let toast = lib.toast {
                Text(toast)
                    .font(.title3.weight(.medium))
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 150)
                    .allowsHitTesting(false)
            }
        }
        .overlay { if lib.showHelp { HelpOverlay() } }
        .sheet(isPresented: $lib.showFinish) { FinishSheet() }
        .onAppear {
            lib.installKeyMonitor()
            lib.reopenLast()
        }
        .onChange(of: lib.index) { _ in prefetch() }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { lib.openDropped(url) }
            }
            return true
        }
        .navigationTitle(lib.folder.map { "PickPic — \($0.lastPathComponent)" } ?? "PickPic")
        .frame(minWidth: 1060, minHeight: 640)
        .preferredColorScheme(.dark)
    }

    private func prefetch() {
        for d in [1, 2, -1] {
            let i = lib.index + d
            if lib.items.indices.contains(i) { ImageLoader.shared.prefetch(lib.items[i].display) }
        }
    }
}

// MARK: - Top bar

struct TopBar: View {
    @EnvironmentObject var lib: Library

    var body: some View {
        HStack(spacing: 12) {
            Button("Open Folder…") { lib.chooseFolder() }
            if let folder = lib.folder {
                Text(folder.lastPathComponent).fontWeight(.semibold).lineLimit(1).truncationMode(.middle).layoutPriority(-1)
            }
            if !lib.items.isEmpty {
                Text("\(lib.index + 1) of \(lib.items.count)  ·  \(lib.ratedCount) rated")
                    .monospacedDigit().foregroundStyle(.secondary)
                    .lineLimit(1).fixedSize()
                ForEach(Rating.allCases) { r in
                    Text("\(r.rawValue): \(lib.count(r))")
                        .font(.callout.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(r.color.opacity(0.85), in: Capsule())
                        .foregroundStyle(.black)
                        .help(r.label)
                }
            }
            Spacer(minLength: 0).layoutPriority(-2)
            if !lib.items.isEmpty {
                Toggle("Unrated Only", isOn: Binding(get: { lib.unratedOnly },
                                                     set: { _ in lib.toggleUnratedOnly() }))
                    .toggleStyle(.button)
                    .help("Hide photos you've already rated (F)")
                Button(lib.mode == .compare ? "Exit Compare" : "Compare") { lib.toggleCompare() }
                    .disabled(lib.mode == .showdown)
                    .help("Two photos side by side (C)")
                Button("Pick Winner") { lib.startShowdown() }
                    .disabled(lib.mode != .single)
                    .help("Head-to-head through a burst (W)")
                Button("Finish…") { lib.showFinish = true }
                    .buttonStyle(.borderedProminent)
            }
            Button("?") { lib.showHelp.toggle() }
        }
        .focusable(false)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color(white: 0.12))
    }
}

/// A thin line that fills as the folder gets rated.
struct ProgressLine: View {
    @EnvironmentObject var lib: Library
    var body: some View {
        GeometryReader { geo in
            let done = lib.items.isEmpty ? 0 : CGFloat(lib.ratedCount) / CGFloat(lib.items.count)
            ZStack(alignment: .leading) {
                Color(white: 0.2)
                Color(white: 0.75).frame(width: geo.size.width * done)
            }
        }
        .frame(height: 2)
        .help("\(lib.ratedCount) of \(lib.items.count) rated")
    }
}

/// The full location of the folder being reviewed. Click to show it in Finder.
struct PathBar: View {
    let folder: URL
    var body: some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                Text((folder.path as NSString).abbreviatingWithTildeInPath
                        .replacingOccurrences(of: "/", with: "  ›  "))
                    .lineLimit(1).truncationMode(.head)
                Spacer()
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14).padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help("Show this folder in Finder")
        .background(Color(white: 0.09))
    }
}

struct EmptyState: View {
    @EnvironmentObject var lib: Library
    var body: some View {
        VStack(spacing: 16) {
            Text(lib.folder == nil ? "Open a folder of photos to start" : "No photos left in this folder")
                .font(.title2)
            Text("You can also drag a folder onto this window.")
                .foregroundStyle(.secondary)
            Button("Open Folder…") { lib.chooseFolder() }
                .controlSize(.large)
                .focusable(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Photo pane

struct PhotoPane: View {
    @EnvironmentObject var lib: Library
    @EnvironmentObject var zoom: ZoomState
    @Environment(\.displayScale) private var displayScale

    let item: PhotoItem
    let slot: Int

    @State private var image: CGImage?
    @State private var full: CGImage?
    @State private var fullSize: CGSize?
    @State private var failed = false
    @State private var inCloud = false
    @State private var info: String?
    @State private var dragStart: CGPoint?

    init(item: PhotoItem, slot: Int) {
        self.item = item
        self.slot = slot
        _image = State(initialValue: ImageLoader.shared.cachedPreview(item.display))
    }

    private var isActive: Bool { lib.mode != .single && lib.activePane == slot }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if let img = zoom.on ? (full ?? image) : image {
                    if zoom.on {
                        let size = zoomSize(img)
                        // 1:1: each photo pixel lands on one screen pixel, unsmoothed.
                        Image(decorative: img, scale: 1)
                            .resizable()
                            .interpolation(full != nil ? .none : .medium)
                            .frame(width: size.width, height: size.height)
                            .position(x: geo.size.width / 2 + (0.5 - zoom.center.x) * size.width,
                                      y: geo.size.height / 2 + (0.5 - zoom.center.y) * size.height)
                    } else {
                        Image(decorative: img, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                    }
                } else if inCloud {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Downloading from iCloud…").foregroundStyle(.secondary)
                    }
                } else if failed {
                    Text("Can't open this file").foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { v in
                        guard zoom.on, let img = full ?? image else { return }
                        let size = zoomSize(img)
                        let start = dragStart ?? zoom.center
                        dragStart = start
                        zoom.center = CGPoint(
                            x: min(max(start.x - v.translation.width / size.width, 0), 1),
                            y: min(max(start.y - v.translation.height / size.height, 0), 1))
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .simultaneousGesture(
                SpatialTapGesture(count: 2).onEnded { v in
                    if zoom.on { zoom.on = false; return }
                    guard let img = image else { return }
                    // Zoom in on the spot that was double-clicked.
                    let aspect = CGFloat(img.width) / CGFloat(img.height)
                    var w = geo.size.width, h = w / aspect
                    if h > geo.size.height { h = geo.size.height; w = h * aspect }
                    let x = (v.location.x - (geo.size.width - w) / 2) / w
                    let y = (v.location.y - (geo.size.height - h) / 2) / h
                    zoom.center = CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
                    zoom.on = true
                }
            )
            .simultaneousGesture(TapGesture().onEnded {
                if lib.mode != .single { lib.activePane = slot }
            })
        }
        .overlay(alignment: .topLeading) { nameLabel }
        .overlay(alignment: .topTrailing) { RatingBadge(rating: item.rating).padding(10) }
        .overlay(alignment: .bottom) {
            if lib.mode == .showdown {
                Text(slot == 0 ? "←  keep this one" : "keep this one  →")
                    .font(.title3.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(.black.opacity(0.6), in: Capsule())
                    .padding(.bottom, 12)
            }
        }
        .overlay {
            if isActive { Rectangle().strokeBorder(Color.accentColor, lineWidth: 3).allowsHitTesting(false) }
        }
        .task {
            if image == nil {
                // Wait for iCloud rather than showing a blank or broken photo.
                while ImageLoader.waitingOnCloud(item.display) {
                    inCloud = true
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if Task.isCancelled { return }
                }
                inCloud = false
                image = await ImageLoader.shared.preview(item.display)
                failed = image == nil
            }
            let url = item.display
            fullSize = await Task.detached { ImageLoader.pixelSize(url) }.value
            info = await Task.detached { ImageLoader.shotInfo(url) }.value
        }
        .task(id: zoom.on) {
            if zoom.on, full == nil { full = await ImageLoader.shared.full(item.display) }
        }
    }

    /// On-screen size at 100%: one photo pixel per screen pixel.
    private func zoomSize(_ img: CGImage) -> CGSize {
        let px = full.map { CGSize(width: $0.width, height: $0.height) }
            ?? fullSize ?? CGSize(width: img.width, height: img.height)
        return CGSize(width: px.width / displayScale, height: px.height / displayScale)
    }

    private var nameLabel: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(item.name)
                if item.burst != nil {
                    let i = lib.items.firstIndex(where: { $0.id == item.id }) ?? 0
                    let range = lib.burstRange(at: i)
                    Text("burst \(i - range.lowerBound + 1)/\(range.count)").foregroundStyle(.purple)
                }
                if zoom.on { Text(full == nil ? "loading 1:1…" : "1:1").foregroundStyle(.secondary) }
            }
            .font(.callout)
            if lib.showInfo, let info {
                Text(info).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
        .padding(10)
    }
}

struct RatingBadge: View {
    let rating: Rating?
    var body: some View {
        if let r = rating {
            HStack(spacing: 8) {
                Text("\(r.rawValue)").font(.system(size: 30, weight: .heavy, design: .rounded))
                Text(r.label).font(.headline)
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(r.color, in: RoundedRectangle(cornerRadius: 10))
        } else {
            Text("not rated")
                .font(.callout).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.black.opacity(0.55), in: Capsule())
        }
    }
}

struct ShowdownBanner: View {
    @EnvironmentObject var lib: Library
    var body: some View {
        Text("Which is better?  ←  or  →   ·   2 3 4 rates the outlined photo and moves on   ·   \(lib.showdownRemaining) more after this")
            .font(.headline)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(Color.accentColor)
    }
}

// MARK: - Filmstrip

struct Filmstrip: View {
    @EnvironmentObject var lib: Library

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 4) {
                    let shown = Array(lib.items.enumerated()).filter { i, item in
                        !lib.unratedOnly || item.rating == nil || i == lib.index || i == lib.right
                    }
                    ForEach(Array(shown.enumerated()), id: \.element.element.id) { k, entry in
                        let (i, item) = entry
                        ThumbCell(item: item,
                                  highlight: i == lib.index ? 1 : (i == lib.right ? 2 : 0),
                                  joinsPrevious: item.burst != nil && k > 0 && shown[k - 1].element.burst == item.burst)
                            .onTapGesture { lib.select(i) }
                    }
                }
                .padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 6)
            }
            .frame(height: 84)
            .background(Color(white: 0.08))
            .onChange(of: lib.index) { _ in scroll(proxy, to: lib.index) }
            .onChange(of: lib.right) { r in if let r { scroll(proxy, to: r) } }
            .onAppear { scroll(proxy, to: lib.index) }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, to i: Int) {
        guard lib.items.indices.contains(i) else { return }
        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(lib.items[i].id, anchor: .center) }
    }
}

struct ThumbCell: View {
    let item: PhotoItem
    let highlight: Int
    /// The photo before this one in the strip belongs to the same burst.
    let joinsPrevious: Bool
    @State private var img: CGImage?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let img {
                    Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color(white: 0.18)
                }
            }
            .frame(width: 96, height: 66)
            .clipped()
            .opacity(item.rating == .delete ? 0.4 : 1)

            if let r = item.rating {
                Text("\(r.rawValue)")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(r.color)
            }
        }
        .overlay {
            if highlight > 0 {
                Rectangle().strokeBorder(highlight == 1 ? Color.white : Color.accentColor, lineWidth: 3)
            }
        }
        // A purple bar just above the thumbnail joins photos from the same burst.
        // It bridges the gap between neighbours, so each burst reads as one line.
        .padding(.top, 6)
        .overlay(alignment: .top) {
            if item.burst != nil {
                Rectangle().fill(Color.purple).frame(height: 3)
                    .padding(.leading, joinsPrevious ? -4 : 0)
            }
        }
        .task {
            while ImageLoader.waitingOnCloud(item.display) {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { return }
            }
            img = await ImageLoader.shared.thumb(item.display)
        }
    }
}

struct HintBar: View {
    @EnvironmentObject var lib: Library
    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(Color(white: 0.12))
    }
    private var text: String {
        switch lib.mode {
        case .single:
            return "1 Delete   2 Heavy edit   3 Light edit   4 Great   0 Clear   ·   ← → Browse   Z Zoom 1:1   C Compare   W Pick winner   ⌘Z Undo   ? All keys"
        case .compare:
            return "← → Change the outlined photo   Tab Switch side   1–4 Rate it   Z Zoom both   Esc Back to one photo"
        case .showdown:
            return "← → Pick the better one   1–4 Rate the outlined one, carry on with the other   Tab Switch outline   Space Keep both   ⌘Z Undo   Esc Stop"
        }
    }
}

// MARK: - Finish

struct FinishSheet: View {
    @EnvironmentObject var lib: Library
    @AppStorage("finishTrash1") private var trash1 = true
    @AppStorage("finishMove4") private var move4 = true
    @AppStorage("finishMove3") private var move3 = true
    @AppStorage("finishMove2") private var move2 = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Finish this folder").font(.title2.bold())
            Toggle("Move \(lib.count(.great)) rated 4 (Great) to “\(Library.editFolderName)”", isOn: $move4)
            Toggle("Move \(lib.count(.lightEdit)) rated 3 (Light edit) to “\(Library.editFolderName)”", isOn: $move3)
            Toggle("Move \(lib.count(.heavyEdit)) rated 2 (Heavy edit) to “\(Library.editFolderName)”", isOn: $move2)
            Toggle("Send \(lib.count(.delete)) rated 1 (Delete) to the Trash", isOn: $trash1)
            Text("Photos you don't move stay where they are and keep their tags. Trashed photos can be put back from the Trash. This step can't be undone with ⌘Z.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { lib.showFinish = false }.keyboardShortcut(.cancelAction)
                Button("Do It") {
                    var move: Set<Rating> = []
                    if move4 { move.insert(.great) }
                    if move3 { move.insert(.lightEdit) }
                    if move2 { move.insert(.heavyEdit) }
                    lib.showFinish = false
                    lib.performFinish(trashOnes: trash1, move: move)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 460)
    }
}

// MARK: - Help and settings

struct HelpOverlay: View {
    @EnvironmentObject var lib: Library
    private let rows: [(String, String)] = [
        ("← →", "Previous / next photo"),
        ("1  2  3  4", "Delete · Heavy edit · Light edit · Great"),
        ("0", "Clear the rating"),
        ("U", "Jump to the next unrated photo"),
        ("Z or double-click", "Zoom to 1:1 pixels (drag to move around)"),
        ("F", "Show only unrated photos"),
        ("I", "Show or hide shot details"),
        ("H", "Hide or show the bars and filmstrip"),
        ("C", "Compare two photos side by side"),
        ("W", "Pick a winner from a burst"),
        ("   then 1–4", "Rate the outlined photo, carry on with the other"),
        ("Delete", "Move this photo to the Trash right now"),
        ("⌘Z", "Undo"),
        ("⌘↩", "Finish: move the keepers, trash the 1s"),
    ]
    var body: some View {
        ZStack {
            Color.black.opacity(0.7)
            VStack(alignment: .leading, spacing: 9) {
                Text("Keys").font(.title2.bold())
                ForEach(rows, id: \.0) { row in
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.0).font(.body.monospaced().weight(.semibold)).frame(width: 170, alignment: .leading)
                        Text(row.1)
                    }
                }
                Text("Press any key to close").foregroundStyle(.secondary).padding(.top, 6)
            }
            .padding(26)
            .background(Color(white: 0.15), in: RoundedRectangle(cornerRadius: 14))
        }
        .onTapGesture { lib.showHelp = false }
    }
}

struct SettingsView: View {
    @AppStorage("autoAdvance") private var autoAdvance = true
    @AppStorage("burstGap") private var burstGap = 3.0
    var body: some View {
        Form {
            Toggle("Go to the next photo after rating", isOn: $autoAdvance)
            Stepper("Photos within \(Int(burstGap)) s of each other count as a burst",
                    value: $burstGap, in: 1...60, step: 1)
            Text("The burst setting applies the next time you open a folder.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 440)
    }
}
