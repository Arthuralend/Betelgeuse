import SwiftUI
import UniformTypeIdentifiers

struct DirectView: View {
    @StateObject private var session = DirectSession()
    @State private var invitation = ""
    @State private var message = ""
    @State private var selecting = false
    @State private var historyName: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let peer = session.peer {
                        HStack {
                            Label(peer.name, systemImage: "person.circle.fill")
                                .font(.headline)
                            Spacer()
                            Button { session.saveContact() } label: {
                                Image(systemName: session.contacts.contains(where: { $0.id == peer.id }) ? "checkmark.circle" : "person.badge.plus")
                            }
                            .accessibilityLabel("Сохранить контакт")
                        }
                    } else {
                        TextField("Ваше имя", text: $session.name)
                            .disabled(session.busy)
                    }
                    Text(session.status).font(.footnote).foregroundStyle(.secondary)
                    if let invite = session.invite {
                        ShareLink(item: invite, subject: Text("Betelgeuse"), message: Text("Приглашение Betelgeuse")) {
                            Label("Поделиться приглашением", systemImage: "square.and.arrow.up")
                        }
                        Button("Скопировать приглашение") { UIPasteboard.general.string = invite }
                    }
                    if session.busy {
                        Button("Отключиться", role: .destructive) { session.disconnect() }
                    } else {
                        Button { session.host() } label: { Label("Создать приглашение по Wi-Fi", systemImage: "wifi") }
                        TextField("Ретранслятор (адрес:порт)", text: $session.relayAddress)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        Button(action: session.hostInternet) { Label("Создать интернет-приглашение", systemImage: "globe") }
                        TextField("Ссылка-приглашение", text: $invitation)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        Button("Подключиться") {
                            historyName = nil
                            session.join(invitation)
                        }
                        .disabled(invitation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                if session.peer != nil {
                    Section {
                        callControls
                        if let offer = session.incoming {
                            Text("\(offer.name) · \(ByteCountFormatter.string(fromByteCount: offer.size, countStyle: .file))")
                            Button("Принять файл") { session.respondToFile(accept: true) }
                            Button("Отклонить", role: .destructive) { session.respondToFile(accept: false) }
                        }
                        if let transfer = session.transfer { Text(transfer).foregroundStyle(.secondary) }
                        if let url = session.fileURL { ShareLink(item: url) { Label("Сохранить полученный файл", systemImage: "square.and.arrow.up") } }
                        Button { selecting = true } label: { Label("Отправить файл", systemImage: "paperclip") }
                            .disabled(session.call != nil)
                    }
                }

                if session.peer != nil || historyName != nil {
                    Section(historyName ?? "Переписка") {
                        ForEach(session.messages) { item in
                            Text(item.text)
                                .textSelection(.enabled)
                                .padding(.vertical, 4)
                                .padding(.horizontal, 10)
                                .background(item.mine ? Color.indigo.opacity(0.28) : Color.secondary.opacity(0.12),
                                            in: RoundedRectangle(cornerRadius: 10))
                                .frame(maxWidth: .infinity, alignment: item.mine ? .trailing : .leading)
                                .listRowSeparator(.hidden)
                        }
                        if session.peer != nil {
                            HStack {
                                TextField("Сообщение", text: $message, axis: .vertical).lineLimit(1...4)
                                Button {
                                    session.send(message)
                                    message = ""
                                } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                                .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || message.utf8.count > 8192)
                                .accessibilityLabel("Отправить сообщение")
                            }
                        }
                    }
                }

                if session.peer == nil && !session.contacts.isEmpty {
                    Section("Контакты") {
                        ForEach(session.contacts) { contact in
                            Button(contact.name) {
                                historyName = contact.name
                                session.showHistory(contact.id)
                            }
                            .swipeActions {
                                Button("Удалить", role: .destructive) {
                                    session.removeContact(contact)
                                    historyName = nil
                                }
                            }
                        }
                    }
                }
                if session.peer == nil && session.fileURL != nil {
                    Section("Файлы") {
                        if let url = session.fileURL { ShareLink(item: url) { Label("Сохранить полученный файл", systemImage: "square.and.arrow.up") } }
                    }
                }
            }
            .navigationTitle("Бетельгейзе")
            .tint(Color(red: 0.65, green: 0.67, blue: 1))
            .fileImporter(isPresented: $selecting, allowedContentTypes: [.item]) { result in
                if case let .success(url) = result { session.offerFile(url) }
            }
            .onChange(of: session.peer?.id) { value in
                if value != nil { historyName = nil }
            }
        }
    }

    @ViewBuilder private var callControls: some View {
        switch session.call {
        case .incoming:
            Button("Ответить", action: session.answerCall)
            Button("Отклонить звонок", role: .destructive, action: session.hangUp)
        case .outgoing:
            Button("Отменить вызов", role: .destructive, action: session.hangUp)
        case .active:
            Button("Завершить звонок", role: .destructive, action: session.hangUp)
        case nil:
            Button(action: session.callPeer) { Label("Аудиозвонок", systemImage: "phone") }
        }
    }
}
