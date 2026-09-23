import CoreGraphics
import Foundation

/// All proportions below were measured from Apple's own macOS 14/15 Launchpad screenshots
/// (support.apple.com "Use Launchpad", 1512×982 display) and are expressed as fractions of the
/// full screen width W / height H, so they hold on any display.
enum LPRatio {
    // Main grid (7 × 5)
    static let gridLeft: CGFloat = 0.100        // × W   first column cell edge
    static let gridWidth: CGFloat = 0.800       // × W   7 columns → pitch 0.1142 W
    static let gridTop: CGFloat = 0.0815        // × H   first row cell edge (icon centre 0.156 H)
    static let gridHeight: CGFloat = 0.745      // × H   5 rows → pitch 0.149 H
    static let iconFrame: CGFloat = 0.096       // × H   icon image frame (visible body ≈ 0.0774 H)
    static let labelOffset: CGFloat = 0.0588    // × H   icon centre → label centre
    static let labelFontAt982: CGFloat = 12     // pt at H = 982
    static let searchY: CGFloat = 0.070         // × H   search field centre
    static let dotsY: CGFloat = 0.876           // × H   page dots centre

    // Open folder
    static let panelX: CGFloat = 0.05, panelY: CGFloat = 0.0766
    static let panelW: CGFloat = 0.90, panelH: CGFloat = 0.833
    static let panelRadius: CGFloat = 0.026     // × W
    static let folderGridLeft: CGFloat = 0.0625 // × W   7 columns → pitch 0.125 W
    static let folderGridWidth: CGFloat = 0.875
    static let folderGridTop: CGFloat = 0.1025  // × H   first icon centre 0.179 H
    static let folderGridHeight: CGFloat = 0.765 // × H  5 rows → pitch 0.153 H
    static let folderTitleY: CGFloat = 0.039    // × H
    static let folderTitleFont: CGFloat = 0.030 // × H
    static let folderMaxRows = 4               // Launchpad folders show at most 4 rows per page
}

struct GridMetrics {
    var origin: CGPoint
    var cell: CGSize
    var cols: Int
    var rows: Int
    var iconSize: CGFloat
    var labelFont: CGFloat
    var labelOffset: CGFloat
    var darkLabels = false

    var capacity: Int { cols * rows }
    var gridRect: CGRect {
        CGRect(x: origin.x, y: origin.y, width: cell.width * CGFloat(cols), height: cell.height * CGFloat(rows))
    }
    var labelHeight: CGFloat { ceil(labelFont * 1.3) }
    /// Height of an icon cell view whose icon is vertically centred (label hangs below).
    var itemHeight: CGFloat { 2 * (labelOffset + labelHeight / 2) }
    var badgeSize: CGFloat { max(16, (iconSize * 0.25).rounded()) }
    /// Offset of the delete badge from the icon frame's top-left (icons carry ~10% transparent padding).
    var badgeOffset: CGFloat { iconSize * 0.1 - badgeSize * 0.4 }

    static func main(size: CGSize, cols: Int, rows: Int) -> GridMetrics {
        let W = max(size.width, 200), H = max(size.height, 200)
        let c = max(1, cols), r = max(1, rows)
        let pitchX = W * LPRatio.gridWidth / CGFloat(c)
        let pitchY = H * LPRatio.gridHeight / CGFloat(r)
        // Shrink icons when a denser grid than 7×5 is chosen.
        let scale = min(1, pitchY / (H * LPRatio.gridHeight / 5), pitchX / (W * LPRatio.gridWidth / 7))
        let icon = floor(min(H * LPRatio.iconFrame * scale, pitchX * 0.8))
        let font = min(14, max(10, ((LPRatio.labelFontAt982 * H / 982 * scale) * 2).rounded() / 2))
        return GridMetrics(origin: CGPoint(x: W * LPRatio.gridLeft, y: H * LPRatio.gridTop),
                           cell: CGSize(width: pitchX, height: pitchY),
                           cols: c, rows: r,
                           iconSize: icon, labelFont: font,
                           labelOffset: H * LPRatio.labelOffset * scale)
    }

    func cellCenter(_ slot: Int) -> CGPoint {
        let r = slot / cols, c = slot % cols
        return CGPoint(x: origin.x + cell.width * (CGFloat(c) + 0.5),
                       y: origin.y + cell.height * (CGFloat(r) + 0.5))
    }

    /// Icons sit exactly at the cell centre, as in Launchpad.
    func iconCenter(_ slot: Int) -> CGPoint { cellCenter(slot) }

    func iconRect(_ slot: Int) -> CGRect {
        let c = iconCenter(slot)
        return CGRect(x: c.x - iconSize / 2, y: c.y - iconSize / 2, width: iconSize, height: iconSize)
    }

    func hitRect(_ slot: Int) -> CGRect {
        let c = cellCenter(slot)
        let w = min(cell.width, iconSize + 20)
        let top = c.y - iconSize / 2 - 4
        let bottom = c.y + labelOffset + labelHeight / 2 + 4
        return CGRect(x: c.x - w / 2, y: top, width: w, height: bottom - top)
    }

    func deleteRect(_ slot: Int) -> CGRect {
        let r = iconRect(slot)
        return CGRect(x: r.minX + badgeOffset - 5, y: r.minY + badgeOffset - 5,
                      width: badgeSize + 10, height: badgeSize + 10)
    }

    func nearestSlot(to p: CGPoint) -> Int {
        let c = Int(floor((p.x - origin.x) / cell.width))
        let r = Int(floor((p.y - origin.y) / cell.height))
        let cc = min(cols - 1, max(0, c))
        let rr = min(rows - 1, max(0, r))
        return rr * cols + cc
    }
}

struct FolderLayout {
    var panel: CGRect
    var cornerRadius: CGFloat
    var grid: GridMetrics
    var titleRect: CGRect
    var titleFont: CGFloat
    var pageCount: Int

    /// Launchpad's open folder: frosted panel with the main grid's columns; its height shrinks to the
    /// number of rows actually used (full 5-row height only when the folder is full / paged).
    static func make(main m: GridMetrics, screen: CGSize, appCount: Int) -> FolderLayout {
        let W = max(screen.width, 200), H = max(screen.height, 200)
        let cell = CGSize(width: W * LPRatio.folderGridWidth / CGFloat(m.cols),
                          height: H * LPRatio.folderGridHeight / CGFloat(max(5, m.rows)))
        let rows = min(LPRatio.folderMaxRows, m.rows)
        let cap = max(1, m.cols * rows)
        let pageCount = max(1, (appCount + cap - 1) / cap)
        let rowsShown = pageCount > 1 ? rows : max(1, min(rows, (max(appCount, 1) + m.cols - 1) / m.cols))

        let padTop = H * (LPRatio.folderGridTop - LPRatio.panelY)          // ≈ 0.026 H
        let padBottom = padTop + (pageCount > 1 ? H * 0.028 : 0)             // room for dots
        let panelH = padTop + cell.height * CGFloat(rowsShown) + padBottom
        let fullCenterY = H * (LPRatio.panelY + LPRatio.panelH / 2)          // panel stays centred
        let panel = CGRect(x: W * LPRatio.panelX, y: fullCenterY - panelH / 2,
                           width: W * LPRatio.panelW, height: panelH)

        let grid = GridMetrics(origin: CGPoint(x: W * LPRatio.folderGridLeft, y: panel.minY + padTop),
                               cell: cell, cols: m.cols, rows: rows,
                               iconSize: m.iconSize, labelFont: m.labelFont, labelOffset: m.labelOffset,
                               darkLabels: true)
        let titleFont = (H * LPRatio.folderTitleFont).rounded()
        let titleCenterY = panel.minY - H * (LPRatio.panelY - LPRatio.folderTitleY)
        let titleRect = CGRect(x: W * 0.25, y: titleCenterY - titleFont * 0.75,
                               width: W * 0.5, height: titleFont * 1.5)
        return FolderLayout(panel: panel, cornerRadius: (W * LPRatio.panelRadius).rounded(),
                            grid: grid, titleRect: titleRect, titleFont: titleFont, pageCount: pageCount)
    }
}
