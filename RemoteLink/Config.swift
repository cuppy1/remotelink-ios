import Foundation

enum Config {
    static let supabaseURL = URL(string: "https://uotffrnssxlikrmjcmtq.supabase.co")!
    static let supabaseKey = "sb_publishable_sXx2hsg_xPw8fKY_T6yCaQ_OsdRhJq_"
    static let meteredApp = "remotelink-2026"
    static let meteredKey = "20b03648bc4e8cfe71b35f6bb33dcb1251ad"
}

struct DeviceRow: Codable, Identifiable, Hashable {
    let id: Int
    let device_name: String
    let device_type: String
    let last_seen: String?
}

// Same JSON shapes the web dashboard sends over Supabase Realtime
struct SDPBody: Codable { let type: String; let sdp: String }
struct CandBody: Codable { let candidate: String; let sdpMid: String?; let sdpMLineIndex: Int? }
struct SignalMessage: Codable {
    var type: String
    var from: String?
    var to: String?
    var sdp: SDPBody?
    var candidate: CandBody?
}
struct SignalEnvelope: Decodable { let payload: SignalMessage? }
