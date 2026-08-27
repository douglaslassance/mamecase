import SwiftUI

/// Constants shared by both masonry layouts. The tile's own chrome
/// (padding around the artwork + title row + meta row) must be accounted
/// for so column widths and row heights match the artwork plus chrome
/// rather than collapsing the spacing the masonry's HStack/VStack adds.
private enum TileChrome {
    /// Horizontal padding the EntryTile adds around its artwork.
    static let horizontal: CGFloat = 16
    /// Vertical chrome the EntryTile adds below the artwork (top + bottom
    /// padding + title baseline + meta row + inter-row spacing).
    static let vertical: CGFloat = 50
}

/// Vertical masonry: fixed number of columns whose width derives from
/// `containerWidth`. Tiles flow into the shortest column.
///
/// `tile` receives the artwork's intended size (not the whole tile size)
/// — the rest of the tile (padding + title + meta) is rendered by
/// `EntryTile` itself at its natural height.
struct VerticalMasonryView<TileContent: View>: View {
    let entries: [Entry]
    let containerWidth: CGFloat
    let targetColumnWidth: CGFloat
    let spacing: CGFloat
    let aspectRatio: (Entry) -> CGFloat
    let tile: (Entry, CGSize) -> TileContent

    private struct ColumnItem {
        let entry: Entry
        let artworkSize: CGSize
    }

    var body: some View {
        let layout = buildLayout()
        HStack(alignment: .top, spacing: spacing) {
            ForEach(layout.indices, id: \.self) { col in
                LazyVStack(alignment: .leading, spacing: spacing) {
                    ForEach(layout[col], id: \.entry.id) { item in
                        tile(item.entry, item.artworkSize)
                    }
                }
                .frame(width: columnWidth)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var columnCount: Int {
        guard containerWidth > 0 else { return 1 }
        let stride = targetColumnWidth + spacing
        return max(1, Int((containerWidth + spacing) / stride))
    }

    private var columnWidth: CGFloat {
        guard columnCount > 0 else { return targetColumnWidth }
        let totalSpacing = CGFloat(columnCount - 1) * spacing
        return (containerWidth - totalSpacing) / CGFloat(columnCount)
    }

    private func buildLayout() -> [[ColumnItem]] {
        let n = columnCount
        let tileWidth = columnWidth
        let artworkWidth = max(0, tileWidth - TileChrome.horizontal)
        var columns: [[ColumnItem]] = Array(repeating: [], count: n)
        // This runs once per frame during a live resize, over every
        // entry in the system, so it stays free of incidental
        // allocation: capacity is reserved up front and the shortest
        // column is found with a plain scan rather than `enumerated()`.
        let expected = entries.count / n + 1
        for i in columns.indices { columns[i].reserveCapacity(expected) }
        var heights: [CGFloat] = Array(repeating: 0, count: n)
        for entry in entries {
            let aspect = max(aspectRatio(entry), 0.0001)
            let artworkHeight = artworkWidth / aspect
            let tileHeight = artworkHeight + TileChrome.vertical
            var shortest = 0
            for i in 1..<n where heights[i] < heights[shortest] { shortest = i }
            columns[shortest].append(ColumnItem(entry: entry,
                                                artworkSize: CGSize(width: artworkWidth,
                                                                    height: artworkHeight)))
            heights[shortest] += tileHeight + spacing
        }
        return columns
    }
}

/// Horizontal masonry: target row height, tiles vary in width to match
/// their aspect ratios. Each row except the last is stretched so the
/// row fills `containerWidth` exactly.
struct HorizontalMasonryView<TileContent: View>: View {
    let entries: [Entry]
    let containerWidth: CGFloat
    let targetRowHeight: CGFloat
    let spacing: CGFloat
    let aspectRatio: (Entry) -> CGFloat
    let tile: (Entry, CGSize) -> TileContent

    private struct RowItem {
        let entry: Entry
        let artworkSize: CGSize
    }

    var body: some View {
        let rows = buildRows()
        LazyVStack(alignment: .leading, spacing: spacing) {
            ForEach(rows.indices, id: \.self) { rowIndex in
                let isLast = rowIndex == rows.indices.last
                HStack(alignment: .top, spacing: spacing) {
                    ForEach(rows[rowIndex], id: \.entry.id) { item in
                        tile(item.entry, item.artworkSize)
                    }
                    if isLast { Spacer(minLength: 0) }
                }
            }
        }
    }

    private func buildRows() -> [[RowItem]] {
        guard containerWidth > 0 else { return [] }
        var rows: [[RowItem]] = []
        var pendingEntries: [Entry] = []
        var pendingAspects: [CGFloat] = []
        // Running total instead of re-reducing `pendingAspects` for every
        // entry. Row breaking re-runs on every frame of a live resize, and
        // the reduce made it quadratic in the length of each row.
        var pendingAspectSum: CGFloat = 0

        /// Width contribution PER TILE for a row at a given artwork height.
        /// Includes the per-tile chrome since tile_width = artwork + chrome.
        func rowWidth(at artworkHeight: CGFloat) -> CGFloat {
            let count = pendingEntries.count
            let totalArtwork = pendingAspectSum * artworkHeight
            let totalChrome = CGFloat(count) * TileChrome.horizontal
            let totalSpacing = CGFloat(max(0, count - 1)) * spacing
            return totalArtwork + totalChrome + totalSpacing
        }

        func finalize(stretchToFill: Bool) {
            guard !pendingEntries.isEmpty else { return }
            let artworkHeight: CGFloat
            if stretchToFill {
                // Solve: rowWidth(at: h) == containerWidth for h.
                let count = pendingEntries.count
                let totalChrome = CGFloat(count) * TileChrome.horizontal
                let totalSpacing = CGFloat(max(0, count - 1)) * spacing
                let availableArtwork = max(0, containerWidth - totalChrome - totalSpacing)
                artworkHeight = pendingAspectSum > 0
                    ? availableArtwork / pendingAspectSum
                    : targetRowHeight
            } else {
                artworkHeight = targetRowHeight
            }
            let items = zip(pendingEntries, pendingAspects).map { entry, aspect in
                RowItem(entry: entry,
                        artworkSize: CGSize(width: artworkHeight * aspect,
                                            height: artworkHeight))
            }
            rows.append(items)
            pendingEntries.removeAll(keepingCapacity: true)
            pendingAspects.removeAll(keepingCapacity: true)
            pendingAspectSum = 0
        }

        for entry in entries {
            let aspect = max(aspectRatio(entry), 0.0001)
            pendingEntries.append(entry)
            pendingAspects.append(aspect)
            pendingAspectSum += aspect
            if rowWidth(at: targetRowHeight) > containerWidth, pendingEntries.count > 1 {
                pendingEntries.removeLast()
                pendingAspects.removeLast()
                pendingAspectSum -= aspect
                finalize(stretchToFill: true)
                pendingEntries.append(entry)
                pendingAspects.append(aspect)
                pendingAspectSum = aspect
            }
        }
        finalize(stretchToFill: false)
        return rows
    }
}
