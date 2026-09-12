import SwiftUI

struct OrbFaceView: View {
    let expression: String
    var size: CGFloat = 280
    var style: String = "orb"
    var color: String = "creme"
    var shape: String = "cercle"
    var rest: String = "idle"
    var motion: MotionSense
    var touch: CGPoint?

    var body: some View {
        GrokBotFaceView(
            expression: expression,
            size: size,
            light: color != "encre" && style != "dark",
            color: color,
            shape: shape,
            rest: rest,
            motion: motion,
            touch: touch
        )
        .frame(width: size, height: size)
    }
}
