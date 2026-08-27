import SwiftUI

/// Constants shared by both masonry layouts. The tile's own chrome
/// (padding around the artwork + title row + meta row) must be accounted
/// for so column widths and row heights match the artwork plus chrome
/// rather than collapsing the spacing the masonry's HStack/VStack adds.
enum TileChrome {
    /// Horizontal padding the EntryTile adds around its artwork.
    static let horizontal: CGFloat = 16
    /// Vertical chrome the EntryTile adds below the artwork (top + bottom
    /// padding + title baseline + meta row + inter-row spacing).
    static let vertical: CGFloat = 50
}

/// Which way an arrow key moves the selection.
enum MasonryDirection {
    case up, down, left, right
}

/// The placement maths behind both masonry layouts.
///
/// Kept out of the views because two callers need it. The views use it
/// to lay tiles out, and keyboard navigation uses it to answer "which
/// tile is above this one", which in a masonry is not simply index minus
/// the column count. Tiles have different heights, so columns fall out
/// of step with each other.
enum MasonryMath {

    // MARK: - Vertical (fixed columns, tiles flow into the shortest)

    static func columnCount(containerWidth: CGFloat,
                            targetColumnWidth: CGFloat,
                            spacing: CGFloat) -> Int {
        guard containerWidth > 0 else { return 1 }
        let stride = targetColumnWidth + spacing
        return max(1, Int((containerWidth + spacing) / stride))
    }

    static func columnWidth(containerWidth: CGFloat,
                            columnCount: Int,
                            targetColumnWidth: CGFloat,
                            spacing: CGFloat) -> CGFloat {
        guard columnCount > 0 else { return targetColumnWidth }
        let totalSpacing = CGFloat(columnCount - 1) * spacing
        return (containerWidth - totalSpacing) / CGFloat(columnCount)
    }

    struct VerticalPartition {
        /// Entry indices grouped by column, in flow order within a column.
        var columns: [[Int]]
        /// Vertical centre of each tile, indexed by entry index. Used to
        /// pick the nearest neighbour when moving between columns.
        var centers: [CGFloat]
    }

    /// Distributes entries into `columnCount` columns, each entry landing
    /// in whichever column is shortest at the time.
    static func verticalPartition(aspects: [CGFloat],
                                  columnCount: Int,
                                  artworkWidth: CGFloat,
                                  spacing: CGFloat) -> VerticalPartition {
        let n = max(1, columnCount)
        var columns: [[Int]] = Array(repeating: [], count: n)
        // This runs once per frame during a live resize, over every entry
        // in the system, so it stays free of incidental allocation:
        // capacity is reserved up front and the shortest column is found
        // with a plain scan rather than `enumerated()`.
        let expected = aspects.count / n + 1
        for i in columns.indices { columns[i].reserveCapacity(expected) }
        var heights = [CGFloat](repeating: 0, count: n)
        var centers = [CGFloat](repeating: 0, count: aspects.count)
        for index in aspects.indices {
            let aspect = max(aspects[index], 0.0001)
            let artworkHeight = artworkWidth / aspect
            let tileHeight = artworkHeight + TileChrome.vertical
            var shortest = 0
            for i in 1..<n where heights[i] < heights[shortest] { shortest = i }
            columns[shortest].append(index)
            centers[index] = heights[shortest] + tileHeight / 2
            heights[shortest] += tileHeight + spacing
        }
        return VerticalPartition(columns: columns, centers: centers)
    }

    // MARK: - Horizontal (target row height, rows stretch to fill)

    struct HorizontalPartition {
        /// Contiguous entry-index ranges, one per row.
        var rows: [Range<Int>]
        /// Artwork height for each row, parallel to `rows`.
        var rowHeights: [CGFloat]
        /// Horizontal centre of each tile, indexed by entry index. Used
        /// to pick the nearest neighbour when moving between rows.
        var centers: [CGFloat]
    }

    /// Breaks entries into rows at `targetRowHeight`, then solves each
    /// full row's height so it fills `containerWidth` exactly. The last
    /// row keeps the target height rather than stretching.
    static func horizontalPartition(aspects: [CGFloat],
                                    containerWidth: CGFloat,
                                    targetRowHeight: CGFloat,
                                    spacing: CGFloat) -> HorizontalPartition {
        var rows: [Range<Int>] = []
        var rowHeights: [CGFloat] = []
        var centers = [CGFloat](repeating: 0, count: aspects.count)
        guard containerWidth > 0, !aspects.isEmpty else {
            return HorizontalPartition(rows: [], rowHeights: [], centers: centers)
        }

        var start = 0
        var count = 0
        // Running total instead of re-reducing the pending aspects for
        // every entry, which made row breaking quadratic in row length.
        var aspectSum: CGFloat = 0

        /// Width of the pending row at a given artwork height. Includes
        /// per-tile chrome, since tile width is artwork plus chrome.
        func rowWidth(at artworkHeight: CGFloat) -> CGFloat {
            aspectSum * artworkHeight
                + CGFloat(count) * TileChrome.horizontal
                + CGFloat(max(0, count - 1)) * spacing
        }

        func finalize(end: Int, stretchToFill: Bool) {
            guard count > 0 else { return }
            let artworkHeight: CGFloat
            if stretchToFill {
                // Solve rowWidth(at: h) == containerWidth for h.
                let totalChrome = CGFloat(count) * TileChrome.horizontal
                let totalSpacing = CGFloat(max(0, count - 1)) * spacing
                let available = max(0, containerWidth - totalChrome - totalSpacing)
                artworkHeight = aspectSum > 0 ? available / aspectSum : targetRowHeight
            } else {
                artworkHeight = targetRowHeight
            }
            var x: CGFloat = 0
            for i in start..<end {
                let tileWidth = artworkHeight * max(aspects[i], 0.0001) + TileChrome.horizontal
                centers[i] = x + tileWidth / 2
                x += tileWidth + spacing
            }
            rows.append(start..<end)
            rowHeights.append(artworkHeight)
            start = end
            count = 0
            aspectSum = 0
        }

        for index in aspects.indices {
            let aspect = max(aspects[index], 0.0001)
            count += 1
            aspectSum += aspect
            if rowWidth(at: targetRowHeight) > containerWidth, count > 1 {
                count -= 1
                aspectSum -= aspect
                finalize(end: index, stretchToFill: true)
                count = 1
                aspectSum = aspect
            }
        }
        finalize(end: aspects.count, stretchToFill: false)
        return HorizontalPartition(rows: rows, rowHeights: rowHeights, centers: centers)
    }

    // MARK: - Keyboard navigation

    /// Index of the tile `direction` away from `index`, or nil at the
    /// edge. Up and down step within a column. Left and right jump to the
    /// adjacent column and land on whichever tile sits closest
    /// vertically, which is what makes the movement track what the eye
    /// sees in a ragged masonry.
    static func verticalNeighbor(of index: Int,
                                 direction: MasonryDirection,
                                 partition: VerticalPartition) -> Int? {
        guard let column = partition.columns.firstIndex(where: { $0.contains(index) }),
              let position = partition.columns[column].firstIndex(of: index)
        else { return nil }

        switch direction {
        case .up:
            let next = position - 1
            return next >= 0 ? partition.columns[column][next] : nil
        case .down:
            let next = position + 1
            return next < partition.columns[column].count
                ? partition.columns[column][next]
                : nil
        case .left, .right:
            let target = direction == .left ? column - 1 : column + 1
            guard partition.columns.indices.contains(target) else { return nil }
            return nearest(to: partition.centers[index],
                           among: partition.columns[target],
                           centers: partition.centers)
        }
    }

    /// Index of the tile `direction` away from `index`, or nil at the
    /// edge. Left and right walk flow order, which in this layout means
    /// walking the row and wrapping into the next one. Up and down jump a
    /// row and land on the closest tile horizontally.
    static func horizontalNeighbor(of index: Int,
                                   direction: MasonryDirection,
                                   partition: HorizontalPartition,
                                   entryCount: Int) -> Int? {
        switch direction {
        case .left:
            return index > 0 ? index - 1 : nil
        case .right:
            return index + 1 < entryCount ? index + 1 : nil
        case .up, .down:
            guard let row = partition.rows.firstIndex(where: { $0.contains(index) })
            else { return nil }
            let target = direction == .up ? row - 1 : row + 1
            guard partition.rows.indices.contains(target) else { return nil }
            return nearest(to: partition.centers[index],
                           among: Array(partition.rows[target]),
                           centers: partition.centers)
        }
    }

    private static func nearest(to center: CGFloat,
                                among candidates: [Int],
                                centers: [CGFloat]) -> Int? {
        var best: Int?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for candidate in candidates {
            let distance = abs(centers[candidate] - center)
            if distance < bestDistance {
                bestDistance = distance
                best = candidate
            }
        }
        return best
    }
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
        MasonryMath.columnCount(containerWidth: containerWidth,
                                targetColumnWidth: targetColumnWidth,
                                spacing: spacing)
    }

    private var columnWidth: CGFloat {
        MasonryMath.columnWidth(containerWidth: containerWidth,
                                columnCount: columnCount,
                                targetColumnWidth: targetColumnWidth,
                                spacing: spacing)
    }

    private func buildLayout() -> [[ColumnItem]] {
        let artworkWidth = max(0, columnWidth - TileChrome.horizontal)
        let aspects = entries.map { max(aspectRatio($0), 0.0001) }
        let partition = MasonryMath.verticalPartition(aspects: aspects,
                                                      columnCount: columnCount,
                                                      artworkWidth: artworkWidth,
                                                      spacing: spacing)
        return partition.columns.map { column in
            column.map { index in
                ColumnItem(entry: entries[index],
                           artworkSize: CGSize(width: artworkWidth,
                                               height: artworkWidth / aspects[index]))
            }
        }
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
        let aspects = entries.map { max(aspectRatio($0), 0.0001) }
        let partition = MasonryMath.horizontalPartition(aspects: aspects,
                                                        containerWidth: containerWidth,
                                                        targetRowHeight: targetRowHeight,
                                                        spacing: spacing)
        return partition.rows.indices.map { rowIndex in
            let artworkHeight = partition.rowHeights[rowIndex]
            return partition.rows[rowIndex].map { index in
                RowItem(entry: entries[index],
                        artworkSize: CGSize(width: artworkHeight * aspects[index],
                                            height: artworkHeight))
            }
        }
    }
}
