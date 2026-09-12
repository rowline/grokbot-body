import SwiftUI

/// Face customiser chips. Form + LazyVGrid + Button swallows taps on iOS,
/// and the default Picker in a Form pushes a page that covers the preview.
struct FaceChooser: View {
    @Binding var color: String
    @Binding var shape: String
    @Binding var rest: String
    @Binding var style: String
    var motion: MotionSense

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.black.opacity(0.88))
                OrbFaceView(
                    expression: "idle",
                    size: 108,
                    style: style,
                    color: color,
                    shape: shape,
                    rest: rest,
                    motion: motion,
                    touch: nil
                )
                .id("\(color)|\(shape)|\(rest)")
                .allowsHitTesting(false)
            }
            .frame(height: 132)
            .frame(maxWidth: .infinity)

            Text("形状")
                .font(.footnote)
                .foregroundStyle(.secondary)
            chipRows(BloubSkin.shapes, columns: 4) { item in
                chip(item.label, selected: shape == item.id) { shape = item.id }
            }

            Text("颜色")
                .font(.footnote)
                .foregroundStyle(.secondary)
            chipRows(BloubSkin.colors, columns: 6) { item in
                Button {
                    color = item.id
                    style = item.id == "encre" ? "dark" : "orb"
                } label: {
                    Circle()
                        .fill(Color(uiColor: BloubSkin.bodyUIColor(for: item.id)))
                        .frame(width: 28, height: 28)
                        .overlay(
                            Circle().stroke(
                                Color.primary.opacity(color == item.id ? 0.95 : 0.25),
                                lineWidth: color == item.id ? 2.5 : 1
                            )
                        )
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .accessibilityLabel(item.label)
            }

            Text("表情")
                .font(.footnote)
                .foregroundStyle(.secondary)
            chipRows(BloubSkin.faces, columns: 4) { item in
                chip(item.label, selected: rest == item.id) { rest = item.id }
            }

            Text("没在听、没在说时用这张脸。Bot 换脸会暂时盖过。思考仍绕彩带，出错仍变感叹号。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    selected ? Color.primary.opacity(0.16) : Color.primary.opacity(0.06),
                    in: Capsule()
                )
                .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
    }

    private func chipRows<Item: Identifiable>(
        _ items: [Item],
        columns: Int,
        @ViewBuilder content: @escaping (Item) -> some View
    ) -> some View {
        let rows = stride(from: 0, to: items.count, by: columns).map { start in
            Array(items[start..<min(start + columns, items.count)])
        }
        return VStack(spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    ForEach(row) { item in
                        content(item)
                    }
                    if row.count < columns {
                        ForEach(0..<(columns - row.count), id: \.self) { _ in
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
    }
}
