import SwiftUI

/// Lays children in rows, wrapping to the next line when the current row is
/// full. Replaces fixed-spacing HStacks that squeeze metric pills on narrow
/// screens.
struct FlowLayout: Layout {
    static let spacing: CGFloat = 10
    var spacing: CGFloat = FlowLayout.spacing

    /// Row-break positions for a set of child widths in a container of `width`.
    /// Returns the total (width, height) and each child's origin. Pure, so the
    /// self-check can exercise it without a render pass.
    static func arrange(sizes: [CGSize], in width: CGFloat, spacing: CGFloat)
        -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for s in sizes {
            if x > 0, x + s.width > width {           // wrap
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), origins)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.replacingUnspecifiedDimensions().width
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        return Self.arrange(sizes: sizes, in: width, spacing: spacing).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let origins = Self.arrange(sizes: sizes, in: bounds.width, spacing: spacing).origins
        for (subview, origin) in zip(subviews, origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                          proposal: .unspecified)
        }
    }

    static func selfCheck() {
        let pill = CGSize(width: 80, height: 24)
        // Three 80-wide pills (+10 spacing) need 260 > 200 → they wrap to ≥2 rows.
        let wrapped = arrange(sizes: Array(repeating: pill, count: 3), in: 200, spacing: 10)
        assert(wrapped.size.height > 24, "three wide pills should wrap past one row")
        assert(wrapped.origins.contains { $0.y > 0 }, "at least one pill on a second row")
        // The same three fit on one row when the container is wide.
        let flat = arrange(sizes: Array(repeating: pill, count: 3), in: 1000, spacing: 10)
        assert(abs(flat.size.height - 24) < 0.001, "wide container keeps one row")
        assert(flat.origins.allSatisfy { $0.y == 0 }, "no wrap when it all fits")
    }
}
