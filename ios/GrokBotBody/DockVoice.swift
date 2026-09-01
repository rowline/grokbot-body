import Foundation

enum DockVoice {
    enum Command: Equatable {
        case action(String)
        case tracking(Bool)
        case stop
    }

    struct Result {
        var command: Command?
        var forward: String?
    }

    static func interpret(_ raw: String) -> Result {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let n = normalize(trimmed)
        guard !n.isEmpty else { return Result() }
        for (phrase, command) in rules {
            if n == phrase {
                return Result(command: command, forward: nil)
            }
            if n.hasPrefix(phrase) {
                let rest = String(n.dropFirst(phrase.count))
                if rest.isEmpty || isFiller(rest) {
                    return Result(command: command, forward: nil)
                }
                return Result(command: command, forward: trimmed)
            }
        }
        return Result(command: nil, forward: trimmed)
    }

    private static let rules: [(String, Command)] = [
        ("不要跟着我", .tracking(false)),
        ("别跟着我", .tracking(false)),
        ("停止跟随", .tracking(false)),
        ("停止追踪", .tracking(false)),
        ("关掉追踪", .tracking(false)),
        ("不要跟着", .tracking(false)),
        ("别跟着", .tracking(false)),
        ("别盯着", .tracking(false)),
        ("stoptracking", .tracking(false)),
        ("跟着我", .tracking(true)),
        ("看着我", .tracking(true)),
        ("盯着我", .tracking(true)),
        ("跟着人", .tracking(true)),
        ("跟着脸", .tracking(true)),
        ("人脸追踪", .tracking(true)),
        ("开始追踪", .tracking(true)),
        ("开始跟随", .tracking(true)),
        ("lookatme", .tracking(true)),
        ("followme", .tracking(true)),
        ("向左转", .action("turn_left")),
        ("往左转", .action("turn_left")),
        ("转左边", .action("turn_left")),
        ("看左边", .action("turn_left")),
        ("向左看", .action("turn_left")),
        ("turnleft", .action("turn_left")),
        ("向右转", .action("turn_right")),
        ("往右转", .action("turn_right")),
        ("转右边", .action("turn_right")),
        ("看右边", .action("turn_right")),
        ("向右看", .action("turn_right")),
        ("turnright", .action("turn_right")),
        ("左转", .action("turn_left")),
        ("右转", .action("turn_right")),
        ("转一圈", .action("spin")),
        ("转个圈", .action("spin")),
        ("转圈", .action("spin")),
        ("点点头", .action("nod")),
        ("点个头", .action("nod")),
        ("点头", .action("nod")),
        ("摇摇头", .action("shake")),
        ("摇个头", .action("shake")),
        ("摇头", .action("shake")),
        ("抬抬头", .action("head_up")),
        ("抬起头", .action("head_up")),
        ("抬头", .action("head_up")),
        ("低低头", .action("head_down")),
        ("低下头", .action("head_down")),
        ("低头", .action("head_down")),
        ("停下来", .stop),
        ("停下", .stop),
        ("别转了", .stop),
        ("stop", .stop),
    ]

    private static func normalize(_ text: String) -> String {
        var s = text.lowercased()
        let strip: [Character] = [" ", "，", ",", "。", ".", "！", "!", "？", "?", "、", "～", "~"]
        s.removeAll { strip.contains($0) }
        let particles = ["请你", "请", "帮我", "给我", "一下", "一点", "吧", "啊", "呀", "嘛", "呢", "咯", "啦", "哦", "嗯"]
        for p in particles {
            if s.hasPrefix(p) { s = String(s.dropFirst(p.count)) }
            if s.hasSuffix(p) { s = String(s.dropLast(p.count)) }
        }
        if s.hasSuffix("了") { s = String(s.dropLast()) }
        return s
    }

    private static func isFiller(_ text: String) -> Bool {
        let fillers: Set<String> = ["", "呀", "啊", "吧", "嘛", "呢", "哦", "嗯", "哈", "看", "看看"]
        return fillers.contains(text)
    }
}
