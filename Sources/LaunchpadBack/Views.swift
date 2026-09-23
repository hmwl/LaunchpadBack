import AppKit
import SwiftUI

struct IconVisuals {
    var editing = false
    var pressedID: String?
    var selectedSlot: Int?
    var mergeTargetID: String?
    var time: Double = 0
    var glass = false
}

// MARK: - Root

struct LaunchpadRootView: View {
    static let space = "lp-root"

    @ObservedObject var model: LaunchpadModel
    @FocusState private var searchFocused: Bool
    @FocusState private var titleFocused: Bool

    var body: some View {
        GeometryReader { geo in
            content(size: geo.size)
        }
        .ignoresSafeArea()
        .onChange(of: model.focusSearchToken) { _, _ in searchFocused = true }
        .onChange(of: titleFocused) { _, v in model.folderNameEditing = v }
    }

    @ViewBuilder
    private func content(size: CGSize) -> some View {
        let m = GridMetrics.main(size: size, cols: model.columns, rows: model.rows)
        let folderOpen = model.openFolderID != nil && model.folderExpanded
        let glass = model.glassActive
        let layout = model.folderLayout(metrics: m, size: size)
        let mainCtx: Ctx = model.searchText.isEmpty ? .main : .search

        ZStack(alignment: .topLeading) {
            BackgroundView(image: model.wallpaper, dim: folderOpen && !glass)
                .frame(width: size.width, height: size.height)
                .clipped()
                .opacity(model.shown ? 1 : 0)

            // Main page: fades away entirely while a folder is open (as in Launchpad).
            Group {
                PagesView(model: model, ctx: mainCtx, metrics: m, size: size)
                PageDots(count: model.pageCount(mainCtx), current: model.activePage(for: mainCtx), dark: false)
                    .position(x: size.width / 2, y: size.height * LPRatio.dotsY)
            }
            .blur(radius: folderOpen && glass ? 22 : 0)
            .opacity(folderOpen ? (glass ? 0.5 : 0) : 1)
            .scaleEffect(folderOpen && glass ? 0.97 : 1)
            .scaleEffect(model.shown ? 1 : 1.1)
            .opacity(model.shown ? 1 : 0)
            .allowsHitTesting(false)

            SearchField(text: $model.searchText, focus: $searchFocused, scale: size.height / 982, active: model.searchEngaged, glass: glass)
                .position(x: size.width / 2, y: size.height * LPRatio.searchY)
                .opacity(folderOpen ? 0 : 1)
                .opacity(model.shown ? 1 : 0)
                .allowsHitTesting(!folderOpen)

            if let fid = model.openFolderID, let layout {
                FolderOverlayView(model: model, folderID: fid, layout: layout, size: size,
                                  glass: glass, expanded: model.folderExpanded, iconRect: model.folderIconRect)
                    .allowsHitTesting(false)
                    .transition(glass ? AnyTransition.identity
                                      : AnyTransition.scale(scale: 0.08, anchor: model.folderAnchor).combined(with: .opacity))

                TextField("", text: Binding(
                    get: { model.folder(fid)?.name ?? "" },
                    set: { model.renameFolder(fid, to: $0) }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: layout.titleFont, weight: .light))
                .foregroundStyle(Color.white.opacity(0.9))
                .multilineTextAlignment(.center)
                .focused($titleFocused)
                .focusEffectDisabled()
                .frame(width: layout.titleRect.width, height: layout.titleRect.height)
                .position(x: layout.titleRect.midX, y: layout.titleRect.midY)
                .opacity(model.folderExpanded ? 1 : 0)
                .transition(.opacity)
            }

            if let d = model.drag {
                let gm = layout?.grid ?? m
                IconCell(item: d.item, metrics: gm, visuals: IconVisuals(glass: glass), selected: false, showLabel: false)
                    .scaleEffect(d.mergingIn ? 0.3 : (d.dropping ? 1.0 : 1.08))
                    .opacity(d.mergingIn ? 0 : (d.dropping ? 1 : 0.92))
                    .position(x: d.location.x - d.grabOffset.width, y: d.location.y - d.grabOffset.height)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .coordinateSpace(.named(Self.space))
        .onAppear { model.viewSize = size }
        .onChange(of: size) { _, s in model.viewSize = s }
    }
}

// MARK: - Background

struct BackgroundView: View {
    let image: NSImage?
    let dim: Bool

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                VisualEffectBackground()
            }
            Color.black.opacity(dim ? 0.2 : 0.05)
        }
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .fullScreenUI
        v.blendingMode = .behindWindow
        v.state = .active
        v.appearance = NSAppearance(named: .darkAqua)
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Pages

struct PagesView: View {
    @ObservedObject var model: LaunchpadModel
    let ctx: Ctx
    let metrics: GridMetrics
    let size: CGSize

    var body: some View {
        let page = model.activePage(for: ctx)
        let count = model.pageCount(ctx)
        let offset = model.ctx == ctx ? model.pageOffset : 0
        let lo = max(0, page - 1)
        let hi = max(lo, min(count - 1, page + 1))

        TimelineView(.animation(minimumInterval: nil, paused: !model.isEditing)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            ZStack(alignment: .topLeading) {
                ForEach(Array(lo...hi), id: \.self) { p in
                    GridPageView(entries: model.displayEntries(ctx: ctx, page: p),
                                 metrics: metrics,
                                 visuals: model.visuals(ctx: ctx, page: p, time: t))
                        .offset(x: CGFloat(p - page) * size.width + offset)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
    }
}

struct GridPageView: View {
    let entries: [PlacedItem]
    let metrics: GridMetrics
    let visuals: IconVisuals

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(entries) { e in
                IconCell(item: e.item, metrics: metrics, visuals: visuals, selected: visuals.selectedSlot == e.slot)
                    .position(metrics.iconCenter(e.slot))
            }
        }
    }
}

// MARK: - Icon

/// The view is centred on the icon; the label hangs below at `labelOffset`, like Launchpad.
struct IconCell: View {
    let item: LPItem
    let metrics: GridMetrics
    let visuals: IconVisuals
    let selected: Bool
    var showLabel = true

    var body: some View {
        let s = metrics.iconSize
        let isMerge = visuals.mergeTargetID == item.id
        let angle: Double = visuals.editing ? sin(visuals.time * 21 + Self.phase(item.id)) * 1.5 : 0
        let deletable: Bool = {
            if case .app(let a) = item { return a.isAppStore }
            return false
        }()
        let labelColor = metrics.darkLabels ? Color.black.opacity(0.72) : Color.white

        ZStack {
            if selected {
                let h = s / 2 + metrics.labelOffset + metrics.labelHeight / 2 + 16
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(metrics.darkLabels ? Color.black.opacity(0.1) : Color.white.opacity(0.2))
                    .frame(width: min(metrics.cell.width - 4, s + 30), height: h)
                    .offset(y: (metrics.labelOffset + metrics.labelHeight / 2 - s / 2) / 2)
            }

            ZStack {
                if isMerge && !item.isFolder {
                    RoundedRectangle(cornerRadius: s * 0.81 * 0.225, style: .continuous)
                        .fill(Color.white.opacity(0.4))
                        .frame(width: s * 0.81, height: s * 0.81)
                        .scaleEffect(1.18)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
                ItemIconView(item: item, size: s, glass: visuals.glass, still: visuals.editing)
                    .scaleEffect(isMerge ? (item.isFolder ? 1.06 : 0.86) : 1)
                    .brightness(visuals.pressedID == item.id ? -0.3 : 0)
            }
            .frame(width: s, height: s)
            .overlay(alignment: .topLeading) {
                if visuals.editing && deletable {
                    DeleteBadge(size: metrics.badgeSize)
                        .offset(x: metrics.badgeOffset, y: metrics.badgeOffset)
                        .transition(.scale.combined(with: .opacity))
                }
            }

            if showLabel {
                Text(item.name)
                    .font(.system(size: metrics.labelFont))
                    .foregroundStyle(labelColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .shadow(color: .black.opacity(metrics.darkLabels ? 0 : 0.35), radius: 1, x: 0, y: 0.5)
                    .frame(width: max(10, metrics.cell.width - 10), height: metrics.labelHeight)
                    .offset(y: metrics.labelOffset)
            }
        }
        .frame(width: metrics.cell.width, height: metrics.itemHeight)
        .rotationEffect(.degrees(angle))
    }

    static func phase(_ id: String) -> Double {
        var h: UInt64 = 1469598103934665603
        for b in id.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return Double(h % 628) / 100
    }
}

struct ItemIconView: View {
    let item: LPItem
    let size: CGFloat
    var glass = false
    var still = false

    var body: some View {
        switch item {
        case .app(let a):
            AppIconImage(app: a, size: size)
        case .folder(let f):
            FolderIconView(folder: f, size: size, glass: glass, still: still)
        }
    }
}

struct AppIconImage: View {
    let app: AppEntry
    let size: CGFloat

    var body: some View {
        Image(nsImage: IconCache.shared.icon(for: app))
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .frame(width: size, height: size)
    }
}

/// Launchpad folder tile: frosted rounded square the size of an icon body, 3×3 mini icons laid out from the top-left.
struct FolderIconView: View {
    let folder: FolderEntry
    let size: CGFloat
    var glass = false
    /// Render without live glass (used while icons jiggle).
    var still = false

    var body: some View {
        let box = size * 0.805
        let pitch = box * 0.27
        let mini = box * 0.20 / 0.805   // mini icon frame (its glyph ≈ 0.2 × box)
        let apps = Array(folder.apps.prefix(9))

        ZStack {
            if glass && !still {
                GlassSurface(shape: RoundedRectangle(cornerRadius: box * 0.225, style: .continuous),
                             clear: true, tint: Color.white.opacity(0.02), fallbackOpacity: 0.25)
                    .frame(width: box, height: box)
            } else if glass {
                // Edit mode: live glass re-morphs every frame while rotating, which exaggerates the wobble.
                RoundedRectangle(cornerRadius: box * 0.225, style: .continuous)
                    .fill(Color.white.opacity(0.18))
                    .overlay(RoundedRectangle(cornerRadius: box * 0.225, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.35), lineWidth: 0.6))
                    .frame(width: box, height: box)
            } else {
                RoundedRectangle(cornerRadius: box * 0.225, style: .continuous)
                    .fill(Color.white.opacity(0.4))
                    .frame(width: box, height: box)
                    .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
            }
            ForEach(0..<apps.count, id: \.self) { i in
                AppIconImage(app: apps[i], size: mini)
                    .offset(x: CGFloat(i % 3 - 1) * pitch, y: CGFloat(i / 3 - 1) * pitch)
            }
        }
        .frame(width: size, height: size)
    }
}

/// Launchpad's delete button: light grey disc with a grey ✕.
struct DeleteBadge: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(Color(white: 0.93))
            Circle().strokeBorder(Color(white: 0.55), lineWidth: max(1, size * 0.07))
            Image(systemName: "xmark")
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(Color(white: 0.45))
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
    }
}

// MARK: - Search field

struct SearchField: View {
    @Binding var text: String
    var focus: FocusState<Bool>.Binding
    var scale: CGFloat = 1
    /// Clicked into / typing: brighter field, left-aligned placeholder and a visible caret.
    var active = false
    var glass = false

    var body: some View {
        let k = min(1.3, max(0.8, scale))
        let on = active || !text.isEmpty
        let shape = RoundedRectangle(cornerRadius: 5 * k, style: .continuous)
        ZStack(alignment: on ? .leading : .center) {
            if glass {
                GlassSurface(shape: shape, tint: Color.white.opacity(on ? 0.14 : 0.04), fallbackOpacity: on ? 0.2 : 0.1)
                shape.strokeBorder(Color.white.opacity(on ? 0.45 : 0), lineWidth: 1)
            } else {
                shape.fill(Color.white.opacity(on ? 0.2 : 0.1))
                shape.strokeBorder(Color.white.opacity(on ? 0.5 : 0.22), lineWidth: on ? 1 : 0.5)
            }

            // Placeholder: centred while idle, slides to the left once the field is active.
            if text.isEmpty {
                HStack(spacing: 4 * k) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10 * k, weight: .semibold))
                    Text(L10n.t("搜索", "Search"))
                        .font(.system(size: 12.5 * k))
                        .opacity(on ? 0.75 : 1)
                }
                .foregroundStyle(Color.white.opacity(on ? 0.6 : 0.5))
                .padding(.horizontal, on ? 7 * k : 0)
                .allowsHitTesting(false)
            }

            HStack(spacing: 4 * k) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10 * k, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .opacity(text.isEmpty ? 0 : 1)
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5 * k))
                    .foregroundStyle(Color.white)
                    .focused(focus)
                    .focusEffectDisabled()
                if !text.isEmpty {
                    Button {
                        text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11 * k))
                            .foregroundStyle(Color.white.opacity(0.55))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.leading, text.isEmpty ? 7 * k + 14 * k : 7 * k)   // caret sits after the glass icon
            .padding(.trailing, 7 * k)
            .opacity(on ? 1 : 0.001)   // idle: keep focus but hide the caret, like Launchpad
        }
        .frame(width: 250 * k, height: 24 * k)
        .shadow(color: Color.white.opacity(on ? 0.18 : 0), radius: 4)
    }
}

// MARK: - Page dots

struct PageDots: View {
    let count: Int
    let current: Int
    var dark = false
    var onSelect: ((Int) -> Void)?

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<max(count, 0), id: \.self) { i in
                Circle()
                    .fill(dotColor(i == current))
                    .frame(width: 7, height: 7)
                    .padding(3.5)
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect?(i) }
            }
        }
        .opacity(count > 1 ? 1 : 0)
        .animation(.easeOut(duration: 0.2), value: current)
    }

    private func dotColor(_ on: Bool) -> Color {
        if dark { return Color.black.opacity(on ? 0.55 : 0.18) }
        return Color.white.opacity(on ? 0.95 : 0.4)
    }
}

// MARK: - Folder overlay

struct FolderOverlayView: View {
    @ObservedObject var model: LaunchpadModel
    let folderID: String
    let layout: FolderLayout
    let size: CGSize
    var glass = false
    var expanded = true
    var iconRect: CGRect = .zero

    var body: some View {
        let ctx = Ctx.folder(folderID)
        let page = model.folderPage
        let count = model.pageCount(ctx)
        let offset = model.ctx == ctx ? model.pageOffset : 0
        let lo = max(0, page - 1)
        let hi = max(lo, min(count - 1, page + 1))
        let full = layout.panel
        // Glass mode morphs the panel out of / into the folder tile.
        let panel = (glass && !expanded && iconRect != .zero) ? iconRect : full
        let radius = (glass && !expanded) ? panel.width * 0.225 : layout.cornerRadius
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let fullShape = RoundedRectangle(cornerRadius: layout.cornerRadius, style: .continuous)
        let grid: GridMetrics = {
            var g = layout.grid
            g.darkLabels = !glass
            return g
        }()

        ZStack(alignment: .topLeading) {
            Group {
                if glass {
                    GlassSurface(shape: shape, clear: true, tint: Color.white.opacity(0.04), fallbackOpacity: 0.5)
                } else {
                    shape
                        .fill(Color.white.opacity(0.58))
                        .overlay(shape.strokeBorder(Color.white.opacity(0.35), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.18), radius: 20, y: 6)
                }
            }
            .frame(width: panel.width, height: panel.height)
            .position(x: panel.midX, y: panel.midY)

            TimelineView(.animation(minimumInterval: nil, paused: !model.isEditing)) { tl in
                let t = tl.date.timeIntervalSinceReferenceDate
                ZStack(alignment: .topLeading) {
                    ForEach(Array(lo...hi), id: \.self) { p in
                        GridPageView(entries: model.displayEntries(ctx: ctx, page: p),
                                     metrics: grid,
                                     visuals: model.visuals(ctx: ctx, page: p, time: t))
                            .offset(x: CGFloat(p - page) * full.width + offset)
                    }
                }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
            }
            .mask {
                ZStack(alignment: .topLeading) {
                    Color.clear
                    fullShape
                        .frame(width: full.width, height: full.height)
                        .position(x: full.midX, y: full.midY)
                }
                .frame(width: size.width, height: size.height)
            }
            // Glass: the panel does the morph; icons just fade/settle in once it has mostly opened.
            .scaleEffect(expanded ? 1 : (glass ? 0.96 : 0.3), anchor: model.folderAnchor)
            .opacity(expanded ? 1 : 0)
            .animation(glass ? (expanded ? .easeOut(duration: 0.2).delay(0.12) : .easeIn(duration: 0.1)) : nil,
                       value: expanded)

            PageDots(count: count, current: page, dark: !glass)
                .position(x: full.midX, y: full.maxY - size.height * 0.028)
                .opacity(expanded ? 1 : 0)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

// MARK: - Liquid Glass

/// Real Liquid Glass on macOS 26+ (when built with the 26+ SDK); a plain frosted fill otherwise.
struct GlassSurface<S: InsettableShape>: View {
    let shape: S
    /// `.clear` glass: the most see-through variant (the "通透" look).
    var clear = false
    var tint: Color = .clear
    var fallbackOpacity: Double = 0.4

    var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            Color.clear
                .glassEffect((clear ? Glass.clear : Glass.regular).tint(tint), in: shape)
        } else {
            fallback
        }
        #else
        fallback
        #endif
    }

    private var fallback: some View {
        shape.fill(Color.white.opacity(fallbackOpacity))
    }
}
