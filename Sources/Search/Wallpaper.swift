import SwiftUI
import AppKit
import CoreImage
import UniformTypeIdentifiers

// A picture of your own behind the empty tab, and, if you like, behind the
// tabs too.
//
// The pictures are copied into Wallpapers/ beside everything else Search
// keeps, so moving or deleting the original never leaves a blank window. One
// is chosen at a time; the rest wait in Settings › Wallpaper.
//
// The chrome over a picture changes to suit it: over a light picture the tabs
// are dark ink on a pale frost, over a dark one light ink on a dark frost. The
// picture is measured once when chosen, where the column and the strip lie
// over it, rather than every time something is drawn.

@MainActor
final class Wallpaper: ObservableObject {
    static let shared = Wallpaper()

    private let store = Store.settings
    private static let folder = Store.folder.appendingPathComponent("Wallpapers", isDirectory: true)
    private static let kinds: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "gif", "webp", "bmp"]

    /// Every picture added, oldest first.
    @Published private(set) var pictures: [URL] = []
    /// The one on show, if any.
    @Published private(set) var chosen: URL?
    /// The chosen picture, and the same softened for under the tabs.
    @Published private(set) var picture: NSImage?
    @Published private(set) var frosted: NSImage?

    /// Behind the tabs as well as the empty tab.
    @Published var onTabs: Bool {
        didSet { store.set(onTabs, forKey: "wallpaper.tabs") }
    }
    /// How much the picture is darkened, nought to three quarters.
    @Published var dim: Double {
        didSet {
            store.set(dim, forKey: "wallpaper.dim")
            judge()
        }
    }

    /// Whether each part of the picture reads as light once dimmed — where
    /// the column lies, and where the strip lies.
    @Published private(set) var sideLight = false
    @Published private(set) var topLight = false
    private var measured: (side: Double, top: Double) = (0, 0)

    /// The tabs sit on the picture.
    var onChrome: Bool { picture != nil && onTabs }

    private init() {
        onTabs = store.object(forKey: "wallpaper.tabs") as? Bool ?? true
        dim = store.object(forKey: "wallpaper.dim") as? Double ?? 0.1
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        pictures = files
            .filter { Self.kinds.contains($0.pathExtension.lowercased()) }
            .sorted { Self.made($0) < Self.made($1) }
        if let name = store.string(forKey: "wallpaper.chosen"),
           let url = pictures.first(where: { $0.lastPathComponent == name }) {
            show(url)
        }
    }

    private static func made(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }

    // MARK: - adding, choosing, removing

    /// Asks for one or more pictures, adds them, and shows the last.
    func pick() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Add"
        panel.message = "Choose pictures for the new tab page"
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    func add(_ urls: [URL]) {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        var last: URL?
        for url in urls where NSImage(contentsOf: url) != nil {
            let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension.lowercased()
            let copy = Self.folder.appendingPathComponent("\(UUID().uuidString).\(ext)")
            guard (try? FileManager.default.copyItem(at: url, to: copy)) != nil else { continue }
            pictures.append(copy)
            last = copy
        }
        if let last { choose(last) }
    }

    /// Nil puts the plain ground back.
    func choose(_ url: URL?) {
        guard let url else {
            chosen = nil
            picture = nil
            frosted = nil
            store.removeObject(forKey: "wallpaper.chosen")
            return
        }
        store.set(url.lastPathComponent, forKey: "wallpaper.chosen")
        show(url)
    }

    func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        pictures.removeAll { $0 == url }
        if chosen == url { choose(pictures.last) }
    }

    /// A small copy for the gallery in Settings.
    func thumbnail(_ url: URL) -> NSImage? {
        if let kept = thumbs[url] { return kept }
        guard let image = NSImage(contentsOf: url) else { return nil }
        let small = Self.scaled(image, longest: 240)
        thumbs[url] = small
        return small
    }
    private var thumbs: [URL: NSImage] = [:]

    // MARK: - reading the picture

    private func show(_ url: URL) {
        guard let image = NSImage(contentsOf: url) else { return }
        chosen = url
        // Big enough for a Retina window, no bigger: a 6K photo held at full
        // size is a hundred megabytes of memory for a background.
        let shown = Self.scaled(image, longest: 3200)
        picture = shown
        frosted = Self.frost(shown)
        measured = Self.measure(shown)
        judge()
    }

    private func judge() {
        let keep = 1 - dim
        sideLight = measured.side * keep > 0.58
        topLight = measured.top * keep > 0.58
    }

    private static func scaled(_ image: NSImage, longest: CGFloat) -> NSImage {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let factor = min(1, longest / max(w, h))
        guard factor < 1 else { return NSImage(cgImage: cg, size: NSSize(width: w, height: h)) }
        let size = NSSize(width: (w * factor).rounded(), height: (h * factor).rounded())
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }
        context.interpolationQuality = .high
        context.draw(cg, in: CGRect(origin: .zero, size: size))
        guard let out = context.makeImage() else { return image }
        return NSImage(cgImage: out, size: size)
    }

    /// Blurred once here, so the column never blurs anything as it draws.
    private static func frost(_ image: NSImage) -> NSImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let input = CIImage(cgImage: cg)
        let radius = max(CGFloat(cg.width), CGFloat(cg.height)) / 60
        guard let blurred = input.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: input.extent) as CIImage?,
              let out = CIContext().createCGImage(blurred, from: input.extent)
        else { return nil }
        return NSImage(cgImage: out, size: image.size)
    }

    /// The lightness of the picture where the column and the strip lie,
    /// drawn down to a few pixels and averaged.
    private static func measure(_ image: NSImage) -> (side: Double, top: Double) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return (0, 0) }
        let n = 24
        var pixels = [UInt8](repeating: 0, count: n * n * 4)
        guard let context = CGContext(data: &pixels, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return (0, 0) }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
        func light(columns: Range<Int>, rows: Range<Int>) -> Double {
            var total = 0.0
            for y in rows {
                for x in columns {
                    let i = (y * n + x) * 4
                    total += (0.2126 * Double(pixels[i]) + 0.7152 * Double(pixels[i + 1]) + 0.0722 * Double(pixels[i + 2])) / 255
                }
            }
            return total / Double(columns.count * rows.count)
        }
        // Rows run from the top in the bitmap's memory.
        return (light(columns: 0..<5, rows: 0..<n),
                light(columns: 0..<n, rows: 0..<3))
    }
}

// MARK: - drawing it

/// Where the picture lies, in the window's own coordinates: centred on the
/// address field and just big enough to cover the window from there. Handed
/// down so each piece of the window draws its own part of the one picture.
private struct CanvasKey: EnvironmentKey {
    static let defaultValue: CGRect = .zero
}

/// True for chrome drawn over the picture: its greys become see-through.
private struct GlassKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var canvas: CGRect {
        get { self[CanvasKey.self] }
        set { self[CanvasKey.self] = newValue }
    }
    var glass: Bool {
        get { self[GlassKey.self] }
        set { self[GlassKey.self] = newValue }
    }
}

extension Palette {
    /// The live tab's grey, and the one under the pointer — solid on the
    /// plain ground, a veil of ink over a picture.
    static func wash(_ glass: Bool) -> Color { glass ? ink.opacity(0.14) : wash }
    static func hover(_ glass: Bool) -> Color { glass ? ink.opacity(0.08) : hover }
}

/// The part of the picture that lies under this view, as though the picture
/// were laid across the whole window and this view were a hole in whatever
/// covers it — so the column, the strip and the empty tab line up exactly.
struct WallpaperFill: View {
    @ObservedObject private var wallpaper = Wallpaper.shared
    @Environment(\.canvas) private var canvas
    var frosted = false

    var body: some View {
        GeometryReader { geo in
            if let image = frosted ? (wallpaper.frosted ?? wallpaper.picture) : wallpaper.picture {
                let at = geo.frame(in: .global)
                let area = canvas == .zero ? at : canvas
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: area.width, height: area.height)
                    .clipped()
                    .overlay(Color.black.opacity(wallpaper.dim))
                    .offset(x: area.minX - at.minX, y: area.minY - at.minY)
            }
        }
        .clipped()
        .allowsHitTesting(false)
    }
}

/// The ground of the column or the strip over the picture: the picture,
/// frosted, under a thin wash of the colour its ink is to stand on.
struct GlassGround: View {
    var body: some View {
        ZStack {
            WallpaperFill(frosted: true)
            Palette.ground.opacity(0.28)
        }
    }
}

/// Puts a piece of chrome on the picture: see-through greys, and ink that
/// reads against the part of the picture it lies over.
struct OnWallpaper: ViewModifier {
    @ObservedObject private var wallpaper = Wallpaper.shared
    @Environment(\.colorScheme) private var scheme
    /// The column, rather than the strip.
    let side: Bool

    func body(content: Content) -> some View {
        let on = wallpaper.onChrome
        let light = side ? wallpaper.sideLight : wallpaper.topLight
        content
            .environment(\.glass, on)
            .environment(\.colorScheme, on ? (light ? .light : .dark) : scheme)
    }
}

/// Settings › Wallpaper.
struct WallpaperPage: View {
    @ObservedObject private var wallpaper = Wallpaper.shared

    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 140), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Card {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                    Tile(image: nil, on: wallpaper.chosen == nil) { wallpaper.choose(nil) }
                    ForEach(wallpaper.pictures, id: \.self) { url in
                        Tile(image: wallpaper.thumbnail(url), on: wallpaper.chosen == url) { wallpaper.choose(url) }
                            .contextMenu {
                                Button("Remove") { wallpaper.remove(url) }
                            }
                    }
                    AddTile { wallpaper.pick() }
                }
                .padding(14)
            }
            Card {
                Line("Behind the tabs too", "The picture runs under the tabs, frosted, and they turn light or dark to suit it") {
                    Switch(on: $wallpaper.onTabs)
                }
                Rule()
                Line("Dim", "Darken the picture so the field and the tabs stand out") {
                    Slider(value: $wallpaper.dim, in: 0...0.75)
                        .frame(width: 140)
                        .controlSize(.small)
                }
            }
            Text("Right-click a picture to remove it. The pictures are copied into Search's own folder, so the originals can go.")
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.muted)
                .padding(.horizontal, 4)
        }
    }

    private struct Tile: View {
        let image: NSImage?
        let on: Bool
        let act: () -> Void

        @State private var hovering = false

        var body: some View {
            ZStack {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Palette.ground
                    Text("None")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                }
            }
            .frame(height: 68)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(on ? Palette.ink : (hovering ? Palette.faint : Palette.hairline), lineWidth: on ? 2 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .onTapGesture(perform: act)
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
            .animation(Motion.quick, value: on)
        }
    }

    private struct AddTile: View {
        let act: () -> Void
        @State private var hovering = false

        var body: some View {
            VStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .medium))
                Text("Add pictures…")
                    .font(.system(size: 11))
            }
            .foregroundStyle(hovering ? Palette.ink : Palette.muted)
            .frame(height: 68)
            .frame(maxWidth: .infinity)
            .background(hovering ? Palette.hover : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Palette.faint, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .onTapGesture(perform: act)
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
        }
    }
}
