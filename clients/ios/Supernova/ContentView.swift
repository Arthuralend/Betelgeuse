import SwiftUI

struct ContentView: View {
    @ObservedObject var service: MeshService
    @State private var text = ""
    @State private var showSettings = false
    @State private var showFriendPrompt = false
    @State private var friendName = ""
    @State private var showFriends = false

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.03, green: 0.02, blue: 0.10),
                             Color(red: 0.12, green: 0.02, blue: 0.18),
                             Color.black],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ).ignoresSafeArea()

                VStack(spacing: 0) {
                    header
                    if let name = service.connectedName {
                        chat(name: name)
                    } else {
                        discovery
                    }
                }
            }
            .navigationTitle("Бетельгейзе")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 12) {
                        Button { showSettings = true } label: {
                            Image(systemName: "person.crop.circle")
                        }
                        Button { showFriends = true } label: {
                            Image(systemName: "person.2")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if service.connectedName != nil {
                        HStack(spacing: 10) {
                            Button {
                                friendName = service.connectedName ?? ""
                                showFriendPrompt = true
                            } label: {
                                Image(systemName: service.isFriend(service.connectedIdentityId) ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.plus")
                            }
                            Button("Отключиться") { service.disconnect() }
                                .font(.caption)
                        }
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(service: service)
            }
            .sheet(isPresented: $showFriends) {
                FriendsView(service: service)
            }
            .fullScreenCover(item: $service.call) { call in
                CallView(service: service, call: call)
            }
            .alert("Сохранить в друзья", isPresented: $showFriendPrompt) {
                TextField("Имя", text: $friendName)
                Button("Сохранить") { service.addFriend(name: friendName) }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Это имя будет показываться только на этом iPhone.")
            }
        }
        .onAppear {
            LocalNotifications.requestPermission()
            service.start()
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Color.purple.opacity(0.18)).frame(width: 46, height: 46)
                    Image(systemName: "sparkles")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.purple, .cyan)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(service.connectedName ?? "Рядом")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(service.status)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.58))
                }
                Spacer()
                if service.connectedName != nil && service.call == nil {
                    Button { service.startCall() } label: {
                        Image(systemName: "phone.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(Color.green.opacity(0.75))
                            .clipShape(Circle())
                    }
                }
                Circle()
                    .fill(service.connectedName == nil ? Color.orange : Color.green)
                    .frame(width: 8, height: 8)
            }
            if let fingerprint = service.fingerprint {
                HStack(spacing: 8) {
                    Text("Отпечаток: \(fingerprint)")
                    if service.isFriend(service.connectedIdentityId) {
                        Label("друг", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green.opacity(0.9))
                    }
                }
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.cyan.opacity(0.8))
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    private var discovery: some View {
        VStack(spacing: 0) {
            if service.nearby.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    ProgressView().tint(.purple)
                    Text("Ищу Бетельгейзе рядом")
                        .font(.title3.weight(.semibold))
                    Text("Оба приложения должны быть открыты.\nРаботает по Wi-Fi или Bluetooth без сервера.")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.58))
                }
                .padding(30)
                Spacer()
            } else {
                List(service.nearby) { peer in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(peer.name).font(.headline)
                            Text("устройство рядом").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Подключиться") { service.invite(peer) }
                            .buttonStyle(.borderedProminent)
                            .tint(.purple)
                    }
                    .listRowBackground(Color.white.opacity(0.04))
                }
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func chat(name: String) -> some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(service.messages) { message in
                            HStack {
                                if message.mine { Spacer(minLength: 50) }
                                Text(message.text)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                    .background(message.mine ? Color.purple.opacity(0.85) : Color.white.opacity(0.09))
                                    .foregroundStyle(.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                    .id(message.id)
                                if !message.mine { Spacer(minLength: 50) }
                            }
                        }
                    }
                    .padding(16)
                }
                .onChange(of: service.messages.count) { _ in
                    service.clearUnread()
                    if let last = service.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
                .onAppear { service.clearUnread() }
            }

            HStack(spacing: 10) {
                TextField("Сообщение", text: $text, axis: .vertical)
                    .lineLimit(1...4)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .foregroundStyle(.white)
                Button {
                    service.send(text)
                    text = ""
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(Color.purple)
                        .clipShape(Circle())
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(12)
            .background(.black.opacity(0.35))
        }
    }
}

struct CallView: View {
    @ObservedObject var service: MeshService
    let call: ActiveCall
    @State private var now = Date()

    private var current: ActiveCall { service.call ?? call }

    private var elapsed: String {
        let seconds = max(0, Int(now.timeIntervalSince(current.startedAt)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.02, green: 0.08, blue: 0.08),
                         Color(red: 0.03, green: 0.02, blue: 0.10),
                         Color.black],
                startPoint: .top, endPoint: .bottom
            ).ignoresSafeArea()

            VStack(spacing: 22) {
                Spacer()
                ZStack {
                    Circle().fill(Color.cyan.opacity(0.12)).frame(width: 170, height: 170)
                    Circle().stroke(Color.cyan.opacity(0.25), lineWidth: 1).frame(width: 210, height: 210)
                    Image(systemName: "waveform")
                        .font(.system(size: 58, weight: .light))
                        .foregroundStyle(.cyan)
                }
                Text(current.peerName)
                    .font(.largeTitle.weight(.semibold))
                    .foregroundStyle(.white)
                Text(current.phase == .incoming ? "Входящий звонок" : current.phase == .outgoing ? "Вызов…" : "Аудиозвонок · \(elapsed)")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.65))
                if let error = service.callError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
                Spacer()

                if current.phase == .incoming {
                    HStack(spacing: 70) {
                        callButton(title: "Отклонить", icon: "phone.down.fill", color: .red) {
                            service.rejectCall()
                        }
                        callButton(title: "Принять", icon: "phone.fill", color: .green) {
                            service.acceptCall()
                        }
                    }
                } else {
                    HStack(spacing: 34) {
                        callButton(title: current.muted ? "Микрофон" : "Без звука", icon: current.muted ? "mic.slash.fill" : "mic.fill", color: .white.opacity(0.16)) {
                            service.toggleMute()
                        }
                        callButton(title: "Завершить", icon: "phone.down.fill", color: .red) {
                            service.hangUp()
                        }
                        callButton(title: current.speaker ? "Динамик" : "Телефон", icon: current.speaker ? "speaker.wave.2.fill" : "ear", color: .white.opacity(0.16)) {
                            service.toggleSpeaker()
                        }
                    }
                }
                Spacer().frame(height: 34)
            }
        }
        .onAppear { now = Date() }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now = $0 }
        .interactiveDismissDisabled()
    }

    private func callButton(title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            Button(action: action) {
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 66, height: 66)
                    .background(color)
                    .clipShape(Circle())
            }
            Text(title).font(.caption2).foregroundStyle(.white.opacity(0.6))
        }
    }
}

struct FriendsView: View {
    @ObservedObject var service: MeshService
    @Environment(\.dismiss) private var dismiss
    @State private var renaming: Friend?
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                if service.friends.isEmpty {
                    Text("Пока нет друзей. Подключитесь к устройству и нажмите «В друзья».")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(service.friends) { friend in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(friend.name).font(.headline)
                            Text(friend.peerIdentityId)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if service.connectedIdentityId == friend.peerIdentityId {
                            Text("онлайн").font(.caption).foregroundStyle(.green)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { service.removeFriend(friend) } label: {
                            Label("Удалить", systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            newName = friend.name
                            renaming = friend
                        } label: {
                            Label("Имя", systemImage: "pencil")
                        }
                        .tint(.purple)
                    }
                }
            }
            .navigationTitle("Друзья")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
            .alert("Имя друга", isPresented: Binding(
                get: { renaming != nil },
                set: { if !$0 { renaming = nil } }
            )) {
                TextField("Имя", text: $newName)
                Button("Сохранить") {
                    if let friend = renaming {
                        let clean = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !clean.isEmpty {
                            if let index = service.friends.firstIndex(where: { $0.peerIdentityId == friend.peerIdentityId }) {
                                service.friends[index].name = String(clean.prefix(40))
                                service.persistFriends()
                            }
                        }
                    }
                    renaming = nil
                }
                Button("Отмена", role: .cancel) { renaming = nil }
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var service: MeshService
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Имя") {
                    TextField("Как вас видят рядом", text: $name)
                }
                Section("Без сервера") {
                    Text("Бетельгейзе использует прямое соединение Apple Multipeer Connectivity. Сервер не нужен, пока оба приложения открыты рядом.")
                        .font(.footnote)
                    Text("Это локальный режим: он не работает через интернет, в фоне и после закрытия приложения.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Проверка") {
                    Text("Сравните отпечаток ключа с собеседником. Если отпечатки совпадают, посредник не подменял ключи.")
                        .font(.footnote)
                }
            }
            .navigationTitle("Настройки")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") {
                        service.setName(name)
                        dismiss()
                    }
                }
            }
            .onAppear { name = service.displayName }
        }
    }
}
