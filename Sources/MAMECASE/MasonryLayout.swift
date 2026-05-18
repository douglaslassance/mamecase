import SwiftUI

/// Vertical masonry: fixed number of columns whose width derives from
/// `containerWidth`, tiles flow into the shortest-running column.
/// Tile heights are computed from each tile's intrinsic aspect ratio,
/// so different ratios pack cleanly without a forced grid cell shape.
struct VerticalMasonryView<TileContent: View>: View {
    let entries: [Entry]
    let containerWidth: CGFloat
    let targetColumnWidth: CGFloat
    let spacing: CGFloat
    let aspectRatio: (Entry) -> CGFloat
    let tile: (Entry, CGSize) -> TileContent

    private struct ColumnItem {
        let entry: Entry
        let size: CGSize
    }

    var body: some View {
        let layout = buildLayout()
        HStack(alignment: .top, spacing: spacing) {
            ForEach(layout.indices, id: \.self) { col in
                LazyVStack(alignment: .leading, spacing: spacing) {
                    ForEach(layout[col], id: \.entry.id) { item in
                        tile(item.entry, item.size)
                    }
                }
                .frame(width: layout[col].first.map { $0.size.width } ?? columnWidth)
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
        let w = columnWidth
        var columns: [[ColumnItem]] = Array(repeating: [], count: n)
        var heights: [CGFloat] = Array(repeating: 0, count: n)
        // Reserve a fixed allowance under the artwork for title + meta.
        let metaHeight: CGFloat = 38
        for entry in entries {
            let aspect = max(aspectRatio(entry), 0.0001)
            let imageHeight = w / aspect
            let tileHeight = imageHeight + metaHeight
            let shortest = heights.enumerated().min { $0.element < $1.element }?.offset ?? 0
            columns[shortest].append(ColumnItem(entry: entry,
                                                size: CGSize(width: w, height: tileHeight)))
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
        let size: CGSize
    }

    var body: some View {
        let rows = buildRows()
        LazyVStack(alignment: .leading, spacing: spacing) {
            ForEach(rows.indices, id: \.self) { rowIndex in
                let isLast = rowIndex == rows.indices.last
                HStack(alignment: .top, spacing: spacing) {
                    ForEach(rows[rowIndex], id: \.entry.id) { item in
                        tile(item.entry, item.size)
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
        let metaHeight: CGFloat = 38

        func finalize(stretchToFill: Bool) {
            guard !pendingEntries.isEmpty else { return }
            let imageHeight: CGFloat
            if stretchToFill {
                let totalSpacing = CGFloat(pendingEntries.count - 1) * spacing
                let totalAspect = pendingAspects.reduce(0, +)
                imageHeight = (containerWidth - totalSpacing) / totalAspect
            } else {
                imageHeight = targetRowHeight
            }
            let items = zip(pendingEntries, pendingAspects).map { entry, aspect in
                RowItem(entry: entry,
                        size: CGSize(width: imageHeight * aspect,
                                     height: imageHeight + metaHeight))
            }
            rows.append(items)
            pendingEntries = []
            pendingAspects = []
        }

        for entry in entries {
            let aspect = max(aspectRatio(entry), 0.0001)
            pendingEntries.append(entry)
            pendingAspects.append(aspect)
            let totalSpacing = CGFloat(pendingEntries.count - 1) * spacing
            let totalWidth = pendingAspects.reduce(0, +) * targetRowHeight + totalSpacing
            if totalWidth > containerWidth, pendingEntries.count > 1 {
                pendingEntries.removeLast()
                pendingAspects.removeLast()
                finalize(stretchToFill: true)
                pendingEntries = [entry]
                pendingAspects = [aspect]
            }
        }
        finalize(stretchToFill: false)
        return rows
    }
}
