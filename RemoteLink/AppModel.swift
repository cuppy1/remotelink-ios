import Foundation
import Supabase
import SwiftUI
import UIKit

@MainActor
final class AppModel: ObservableObject {
    let client = SupabaseClient(supabaseURL: Config.supabaseURL, supabaseKey: Config.supabaseKey)
    let library = ShareLibrary()

    @Published var signedInEmail: String?
    @Published var devices: [DeviceRow] = []
    @Published var thisDeviceId: Int? {
        didSet {
            if let id = thisDeviceId { UserDefaults.standard.set(id, forKey: "thisDeviceId") }
            else { UserDefaults.standard.removeObject(forKey: "thisDeviceId") }
            Task { await checkIn() }
        }
    }
    @Published var allowRemote: Bool {
        didSet { UserDefaults.standard.set(allowRemote, forKey: "allowRemote") }
    }
    @Published var signalStatus = "Signaling: not started"
    @Published var linkStatus = "No remote device connected"
    @Published var checkInStatus = "No check-in yet"
    @Published var message = ""
    @Published var photosStatusText = ""

    private var userId: String?
    private var sessions: [String: PeerSession] = [:]
    private var channel: RealtimeChannelV2?
    private var signalTask: Task<Void, Never>?
    private var checkInTask: Task<Void, Never>?

    init() {
        let saved = UserDefaults.standard.integer(forKey: "thisDeviceId")
        thisDeviceId = saved == 0 ? nil : saved
        allowRemote = UserDefaults.standard.bool(forKey: "allowRemote")
        refreshPhotosText()
    }

    // MARK: Account

    func restore() async {
        do {
            let session = try await client.auth.session
            await onSignedIn(session.user)
        } catch {
            signedInEmail = nil
        }
    }

    func signIn(email: String, password: String) async {
        message = "Signing in..."
        do {
            let session = try await client.auth.signIn(email: email, password: password)
            message = ""
            await onSignedIn(session.user)
        } catch {
            message = error.localizedDescription
        }
    }

    func signOut() async {
        try? await client.auth.signOut()
        checkInTask?.cancel()
        signalTask?.cancel()
        sessions.values.forEach { $0.close() }
        sessions = [:]
        signedInEmail = nil
        devices = []
    }

    private func onSignedIn(_ user: User) async {
        signedInEmail = user.email
        // Realtime topics are compared against auth.uid()::text, which is lowercase
        userId = user.id.uuidString.lowercased()
        await loadDevices()
        startCheckIn()
        await startSignaling()
    }

    func loadDevices() async {
        do {
            let rows: [DeviceRow] = try await client.from("devices")
                .select("id, device_name, device_type, last_seen")
                .order("created_at", ascending: true)
                .execute()
                .value
            devices = rows
        } catch {
            message = "Could not load devices: \(error.localizedDescription)"
        }
    }

    // MARK: Check-in (status shown on the dashboard)

    private func startCheckIn() {
        checkInTask?.cancel()
        checkInTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkIn()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    func checkIn() async {
        guard signedInEmail != nil, let id = thisDeviceId else { return }
        let now = ISO8601DateFormatter().string(from: Date())
        do {
            try await client.from("devices").update(["last_seen": now]).eq("id", value: id).execute()
            checkInStatus = "Last check-in: \(Date().formatted(date: .omitted, time: .standard))"
        } catch {
            checkInStatus = "Check-in failed: \(error.localizedDescription)"
        }
    }

    // MARK: Signaling over Supabase Realtime (same private channel as the web app)

    func startSignaling() async {
        guard let uid = userId else { return }
        signalTask?.cancel()
        if let old = channel { await client.realtimeV2.removeChannel(old) }

        let ch = client.realtimeV2.channel("signal:\(uid)") { $0.isPrivate = true }
        let stream = ch.broadcastStream(event: "signal")
        channel = ch
        await ch.subscribe()
        signalStatus = "Signaling: connected"

        signalTask = Task { [weak self] in
            for await message in stream {
                guard let data = try? JSONEncoder().encode(message) else { continue }
                let decoder = JSONDecoder()
                let signal = (try? decoder.decode(SignalEnvelope.self, from: data))?.payload
                    ?? (try? decoder.decode(SignalMessage.self, from: data))
                if let signal { await self?.handle(signal) }
            }
        }
    }

    private func send(_ message: SignalMessage) async {
        try? await channel?.broadcast(event: "signal", message: message)
    }

    private func handle(_ message: SignalMessage) async {
        guard let id = thisDeviceId, message.to == String(id), let from = message.from else { return }
        let myId = String(id)
        switch message.type {
        case "offer":
            guard allowRemote else {
                await send(SignalMessage(type: "denied", from: myId, to: from))
                linkStatus = "Refused a connection: remote access is switched off"
                return
            }
            guard let sdp = message.sdp else { return }
            sessions[from]?.close()
            let name = devices.first(where: { $0.id == id })?.device_name ?? "iPhone"
            let session = PeerSession(
                remoteId: from, myId: myId, deviceName: name, library: library,
                ice: await IceServers.load(),
                onSignal: { [weak self] out in Task { @MainActor in await self?.send(out) } },
                onState: { [weak self] text in Task { @MainActor in self?.linkStatus = text } }
            )
            sessions[from] = session
            linkStatus = "Incoming connection..."
            do {
                try await session.accept(offer: sdp.sdp)
            } catch {
                linkStatus = "Connection error: \(error.localizedDescription)"
            }
        case "ice":
            if let candidate = message.candidate { sessions[from]?.add(candidate: candidate) }
        default:
            break
        }
    }

    // MARK: Permissions

    func requestPhotos() async {
        _ = await library.requestPhotos()
        refreshPhotosText()
    }

    func refreshPhotosText() {
        switch library.photosStatus {
        case .authorized: photosStatusText = "Photos: full access granted"
        case .limited: photosStatusText = "Photos: limited access (change in Settings > RemoteLink > Photos)"
        case .denied, .restricted: photosStatusText = "Photos: denied (enable in Settings > RemoteLink > Photos)"
        default: photosStatusText = "Photos: not requested yet"
        }
    }

    func addFolder(_ url: URL) {
        do {
            try library.addFolder(url)
            message = "Folder added. Its files are now available remotely."
        } catch {
            message = "Could not save folder access: \(error.localizedDescription)"
        }
        objectWillChange.send()
    }

    func removeFolders() {
        library.removeFolders()
        objectWillChange.send()
    }
}
