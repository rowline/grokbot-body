import SwiftUI

struct OrbFaceView: View {
    let expression: String
    var size: CGFloat = 280
    var style: String = "orb"
    var motion: MotionSense

    var body: some View {
        GrokBotFaceView(
            expression: expression,
            size: size,
            light: style != "dark",
            motion: motion
        )
        .frame(width: size, height: size)
    }
}
