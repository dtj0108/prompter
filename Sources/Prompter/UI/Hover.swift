import SwiftUI
import AppKit

/// Row wrapper that exposes its hover state to the content (for reveal-on-hover
/// controls like delete buttons) and paints a soft highlight behind it.
struct HoverRow<Content: View>: View {
    var cornerRadius: CGFloat = 8
    @ViewBuilder var content: (Bool) -> Content
    @State private var hovered = false

    var body: some View {
        content(hovered)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.primary.opacity(hovered ? 0.06 : 0))
            )
            .contentShape(Rectangle())
            .onHover { inside in
                withAnimation(.easeOut(duration: 0.12)) { hovered = inside }
            }
    }
}

/// Hover highlight + optional pointing-hand cursor for clickable cards.
struct HoverEffect: ViewModifier {
    var cornerRadius: CGFloat = 12
    var baseOpacity: Double = 0.07
    var hoverOpacity: Double = 0.12
    var pointer: Bool = true
    @State private var hovered = false
    @State private var cursorPushed = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.secondary.opacity(hovered ? hoverOpacity : baseOpacity))
            )
            .scaleEffect(hovered ? 1.012 : 1.0)
            .onHover { inside in
                withAnimation(.easeOut(duration: 0.14)) { hovered = inside }
                guard pointer else { return }
                if inside, !cursorPushed {
                    NSCursor.pointingHand.push()
                    cursorPushed = true
                } else if !inside, cursorPushed {
                    NSCursor.pop()
                    cursorPushed = false
                }
            }
            .onDisappear {
                if cursorPushed {
                    NSCursor.pop()
                    cursorPushed = false
                }
            }
    }
}

extension View {
    func hoverCard(cornerRadius: CGFloat = 12, pointer: Bool = true) -> some View {
        modifier(HoverEffect(cornerRadius: cornerRadius, pointer: pointer))
    }
}
