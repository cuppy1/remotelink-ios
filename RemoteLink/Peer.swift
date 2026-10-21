import Foundation
import UIKit
import WebRTC

enum PeerError: Error { case noSDP }

enum IceServers {
    static func load() async -> [RTCIceServer] {
        var out = [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])]
        guard let url = URL(string: "https://\(Config.meteredApp).metered.live/api/v1/turn/credentials?apiKey=\(Config.meteredKey)") else { return out }
        guard let result = try? await URLSession.shared.data(from: url) else { return out }
        guard let list = try? JSONSerialization.jsonObject(with: result.0) as? [[String: Any]] else { return out }
        for s in list {
            var urls: [String] = []
            if let one = s["urls"] as? String { urls = [one] } else if let many = s["urls"] as? [String] { urls = many }
            out.append(RTCIceServer(urlStrings: urls, username: s["username"] as? String, credential: s["credential"] as? String))
        }
        return out
    }
}

// One connection to one remote device (the web dashboard or another phone).
// This iPhone always answers; the remote device starts the connection.
final class PeerSession: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate {
    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory()
    }()

    private let remoteId: String
    private let myId: String
    private let library: ShareLibrary
    private let deviceName: String
    private let onSignal: (SignalMessage) -> Void
    private let onState: (String) -> Void
    private var pc: RTCPeerConnection!
    private var channel: RTCDataChannel?
    private var items: [ShareItem] = []
    private var chain: Task<Void, Never>?
    private var pending: [RTCIceCandidate] = []
    private var hasRemote = false

    init(remoteId: String, myId: String, deviceName: String, library: ShareLibrary, ice: [RTCIceServer],
         onSignal: @escaping (SignalMessage) -> Void, onState: @escaping (String) -> Void) {
        self.remoteId = remoteId
        self.myId = myId
        self.deviceName = deviceName
        self.library = library
        self.onSignal = onSignal
        self.onState = onState
        super.init()
        let config = RTCConfiguration()
        config.iceServers = ice
        config.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        pc = PeerSession.factory.peerConnection(with: config, constraints: constraints, delegate: self)
    }

    func close() {
        channel?.close()
        pc.close()
    }

    func accept(offer: String) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pc.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: offer)) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
        hasRemote = true
        for c in pending { pc.add(c) { _ in } }
        pending.removeAll()

        let answer: RTCSessionDescription = try await withCheckedThrowingContinuation { cont in
            let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            pc.answer(for: constraints) { sdp, error in
                if let sdp { cont.resume(returning: sdp) } else { cont.resume(throwing: error ?? PeerError.noSDP) }
            }
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pc.setLocalDescription(answer) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
        onSignal(SignalMessage(type: "answer", from: myId, to: remoteId, sdp: SDPBody(type: "answer", sdp: answer.sdp)))
    }

    func add(candidate c: CandBody) {
        let cand = RTCIceCandidate(sdp: c.candidate, sdpMLineIndex: Int32(c.sdpMLineIndex ?? 0), sdpMid: c.sdpMid)
        if hasRemote { pc.add(cand) { _ in } } else { pending.append(cand) }
    }

    // MARK: RTCPeerConnectionDelegate

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        switch newState {
        case .failed: onState("Connection to remote device failed")
        case .disconnected: onState("Remote device disconnected")
        case .closed: onState("Connection closed")
        default: break
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        onSignal(SignalMessage(
            type: "ice", from: myId, to: remoteId,
            candidate: CandBody(candidate: candidate.sdp, sdpMid: candidate.sdpMid, sdpMLineIndex: Int(candidate.sdpMLineIndex))
        ))
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        channel = dataChannel
        dataChannel.delegate = self
    }

    // MARK: RTCDataChannelDelegate

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        if dataChannel.readyState == .open { onState("Remote device connected (encrypted)") }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard !buffer.isBinary,
              let obj = try? JSONSerialization.jsonObject(with: buffer.data) as? [String: Any],
              let type = obj["t"] as? String else { return }
        // Handle one request at a time so file chunks never interleave
        let previous = chain
        chain = Task { [weak self] in
            await previous?.value
            await self?.handle(type, obj)
        }
    }

    // MARK: Protocol shared with the web dashboard

    private func sendJSON(_ obj: [String: Any]) {
        guard let ch = channel, ch.readyState == .open,
              let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        ch.sendData(RTCDataBuffer(data: data, isBinary: false))
    }

    private func handle(_ type: String, _ obj: [String: Any]) async {
        switch type {
        case "ping":
            sendJSON(["t": "pong", "ts": obj["ts"] ?? 0])
        case "info-req":
            sendJSON(["t": "info", "info": await deviceInfo()])
        case "list-req":
            items = await library.listItems()
            let files: [[String: Any]] = items.enumerated().map {
                ["id": $0.offset, "name": $0.element.name, "size": $0.element.size, "type": $0.element.mime]
            }
            sendJSON(["t": "list", "files": files])
        case "thumb-req":
            guard let id = obj["id"] as? Int, items.indices.contains(id) else { return }
            if let data = await library.thumbnail(for: items[id]) {
                sendJSON(["t": "thumb", "id": id, "data": data.base64EncodedString()])
            } else {
                sendJSON(["t": "thumb", "id": id])
            }
        case "get":
            guard let id = obj["id"] as? Int, items.indices.contains(id) else {
                sendJSON(["t": "error", "msg": "That file is no longer available."])
                return
            }
            await sendFile(items[id], id: id)
        default:
            break
        }
    }

    private func deviceInfo() async -> [String: Any] {
        await MainActor.run {
            let device = UIDevice.current
            device.isBatteryMonitoringEnabled = true
            var battery = "unknown"
            if device.batteryLevel >= 0 {
                battery = "\(Int(device.batteryLevel * 100))%"
                if device.batteryState == .charging || device.batteryState == .full { battery += " (charging)" }
            }
            let bounds = UIScreen.main.bounds
            return [
                "device": deviceName,
                "browser": "RemoteLink iOS app \(device.systemVersion)",
                "screen": "\(Int(bounds.width))x\(Int(bounds.height))",
                "language": Locale.current.identifier,
                "online": true,
                "network": "native app",
                "sharedFiles": items.count,
                "battery": battery
            ]
        }
    }

    private func sendFile(_ item: ShareItem, id: Int) async {
        guard let ch = channel else { return }
        do {
            let (url, isTemp) = try await library.exportToTemp(item)
            defer { if isTemp { try? FileManager.default.removeItem(at: url) } }
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            sendJSON(["t": "file-start", "id": id, "name": item.name, "size": size, "type": item.mime])
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            while true {
                guard ch.readyState == .open else { return }
                while ch.bufferedAmount > 1_000_000 {
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
                let chunk = try handle.read(upToCount: 16384) ?? Data()
                if chunk.isEmpty { break }
                ch.sendData(RTCDataBuffer(data: chunk, isBinary: true))
            }
            sendJSON(["t": "file-end", "id": id])
        } catch {
            sendJSON(["t": "error", "msg": "Could not read that file: \(error.localizedDescription)"])
        }
    }
}
