import ActivityKit
import Foundation

/// A companion at work, on the lock screen and in the Dynamic Island: who, what it is doing now, for how long.
struct TurnAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable, Hashable {
            case working, waiting, done, failed
        }

        /// 「搜索：重庆天气」, 「等你批准」, or at the end the first words of the reply.
        var doing: String
        var phase: Phase
        /// Tools used so far in this turn.
        var steps: Int
        var started: Date
        /// When it finished, to stop the clock.
        var ended: Date?
        /// The small ring in the Dynamic Island fills over a minute from here; moved on as the turn goes.
        var ring: Date?
    }

    /// The companion's name, or the gathering's.
    var name: String
    /// The conversation, for opening it: `clio://chat/<chat>`.
    var chat: String
    /// The companion's face, a tiny PNG (its pet's first frame, or its photo), for the Dynamic Island.
    var face: Data?
    /// Pure black dark mode preference synced from the app for the Lock Screen card.
    var oled: Bool?

    init(name: String, chat: String, face: Data? = nil, oled: Bool? = nil) {
        self.name = name
        self.chat = chat
        self.face = face
        self.oled = oled
    }
}
