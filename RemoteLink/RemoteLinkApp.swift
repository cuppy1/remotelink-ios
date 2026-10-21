import SwiftUI
import UniformTypeIdentifiers

@main
struct RemoteLinkApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                if model.signedInEmail == nil { LoginView() } else { HomeView() }
            }
            .environmentObject(model)
            .task {
                UIApplication.shared.isIdleTimerDisabled = true
                await model.restore()
            }
            .onChange(of: scenePhase) { phase in
                if phase == .active {
                    UIApplication.shared.isIdleTimerDisabled = true
                    Task {
                        await model.checkIn()
                        if model.signedInEmail != nil { await model.startSignaling() }
                    }
                }
            }
        }
    }
}

struct LoginView: View {
    @EnvironmentObject var model: AppModel
    @State private var email = ""
    @State private var password = ""

    var body: some View {
        Form {
            Section("RemoteLink account") {
                TextField("Email", text: $email)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                Button("Sign in") { Task { await model.signIn(email: email, password: password) } }
            }
            if !model.message.isEmpty { Text(model.message).foregroundColor(.red) }
        }
        .navigationTitle("RemoteLink")
    }
}

struct HomeView: View {
    @EnvironmentObject var model: AppModel
    @State private var showFolderPicker = false

    var body: some View {
        Form {
            Section("Account") {
                Text(model.signedInEmail ?? "")
                Button("Sign out", role: .destructive) { Task { await model.signOut() } }
            }
            Section("This iPhone") {
                Picker("This device is", selection: $model.thisDeviceId) {
                    Text("Choose...").tag(Int?.none)
                    ForEach(model.devices) { Text($0.device_name).tag(Int?.some($0.id)) }
                }
                Text(model.checkInStatus).font(.footnote)
            }
            Section("Remote access (one-time permission)") {
                Toggle("Allow my other devices to access this iPhone", isOn: $model.allowRemote)
                Button("Allow access to Photos") { Task { await model.requestPhotos() } }
                Text(model.photosStatusText).font(.footnote)
                Button("Add a folder from Files") { showFolderPicker = true }
                Text("Folders added: \(model.library.folderCount)").font(.footnote)
                if model.library.folderCount > 0 {
                    Button("Remove added folders", role: .destructive) { model.removeFolders() }
                }
            }
            Section("Status (build 4)") {
                Text(model.signalStatus)
                Button("Reconnect signaling") { Task { await model.startSignaling() } }
                Text(model.linkStatus)
                Text("Messages received: \(model.received)").font(.footnote)
                Text("Last: \(model.lastSignal)").font(.footnote)
                if !model.message.isEmpty { Text(model.message).font(.footnote) }
            }
            Section {
                Text("Keep this app open, on charge, with Auto-Lock set to Never. iOS suspends apps that are closed or locked, and then this iPhone shows as offline.")
                    .font(.footnote)
            }
        }
        .navigationTitle("RemoteLink")
        .sheet(isPresented: $showFolderPicker) {
            FolderPicker { url in model.addFolder(url) }
        }
    }
}

struct FolderPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(_ onPick: @escaping (URL) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(url) }
        }
    }
}
