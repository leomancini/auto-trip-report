import SwiftUI

/// Justified photo rows: photos keep roughly their shape, every row fills the
/// full width, and rows hold about `columns` photos each (never just one,
/// unless the block only has one).
struct JustifiedLayout: Layout {
    /// Roughly how many photos sit side by side in a row.
    var columns: CGFloat
    var spacing: CGFloat

    struct Aspect: LayoutValueKey {
        static let defaultValue: CGFloat = 1
    }

    private struct Row {
        var range: Range<Int>
        var widths: [CGFloat]
        var height: CGFloat
    }

    private func rows(width: CGFloat, subviews: Subviews) -> [Row] {
        let width = max(width, 80)
        let rowHeight = (width - spacing * (columns - 1)) / columns
        let basis = subviews.map { min(2.6, max(0.4, $0[Aspect.self])) * rowHeight }

        // greedy fill
        var ranges: [Range<Int>] = []
        var start = 0
        while start < basis.count {
            var end = start
            var sum: CGFloat = 0
            while end < basis.count {
                let gaps = CGFloat(end - start) * spacing
                if end > start && sum + basis[end] + gaps > width { break }
                sum += basis[end]
                end += 1
            }
            ranges.append(start..<end)
            start = end
        }
        // no lone photos: a single-photo row joins its neighbor if that keeps
        // the row to three, otherwise it takes one photo from it
        var i = 0
        while i < ranges.count {
            guard ranges[i].count == 1, ranges.count > 1 else { i += 1; continue }
            let j = i > 0 ? i - 1 : i + 1
            let (first, second) = (min(i, j), max(i, j))
            if ranges[j].count <= 2 {
                ranges[first] = ranges[first].lowerBound..<ranges[second].upperBound
                ranges.remove(at: second)
                i = first + 1
            } else if j < i {
                let split = ranges[j].upperBound - 1
                ranges[j] = ranges[j].lowerBound..<split
                ranges[i] = split..<ranges[i].upperBound
                i += 1
            } else {
                let split = ranges[j].lowerBound + 1
                ranges[i] = ranges[i].lowerBound..<split
                ranges[j] = split..<ranges[j].upperBound
                i += 1
            }
        }

        return ranges.map { range in
            let sum = basis[range].reduce(0, +)
            let available = width - CGFloat(range.count - 1) * spacing
            // every row stretches (or shrinks) to the full width; height follows
            // up to a point so photos aren't cropped much
            let scale = available / sum
            return Row(range: range, widths: basis[range].map { $0 * scale },
                       height: rowHeight * min(scale, 1.5))
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 900
        let rows = rows(width: width, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + CGFloat(max(rows.count - 1, 0)) * spacing
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for (offset, index) in row.range.enumerated() {
                let w = row.widths[offset]
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                      proposal: ProposedViewSize(width: w, height: row.height))
                x += w + spacing
            }
            y += row.height + spacing
        }
    }
}
