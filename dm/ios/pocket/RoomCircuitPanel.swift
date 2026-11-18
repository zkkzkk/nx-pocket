// SPDX-License-Identifier: MIT
import SwiftUI

enum RoomCircuitAppleHost {
    case meloNX
    case nxPocket
}

@MainActor
private final class RoomCircuitAppointments: ObservableObject {
    @Published var address = UserDefaults.standard.string(forKey: "roomcircuit.server") ?? ""
    @Published private(set) var service: RoomCircuitService?
    @Published private(set) var options: RoomCircuitOptions?
    @Published private(set) var rows: [RoomCircuitAppointment] = []
    @Published private(set) var next: Int?
    @Published private(set) var selected: RoomCircuitAppointment?
    @Published private(set) var rooms: [RoomCircuitRoom] = []
    @Published private(set) var follows: [String] = []
    @Published private(set) var notice: String?
    @Published private(set) var busy = false
    @Published var failure: Error?
    private var nextFollow = 0
    private var previousRooms: [String: Set<String>] = [:]
    private var clockOffset = 0

    var now: Date { Date().addingTimeInterval(TimeInterval(clockOffset)) }

    func connect() async {
        await perform {
            let origin = try RoomCircuitService.parseOrigin(address)
            let client = RoomCircuitService(origin: origin, identity: RoomCircuitService.savedIdentity(for: origin))
            // Publish the new server only after it has successfully served appointments.
            let newOptions = try await client.options()
            let reply = try await client.get("list")
            service = client
            address = origin.absoluteString
            UserDefaults.standard.set(address, forKey: "roomcircuit.server")
            options = newOptions
            updateClock(reply)
            rows = reply.rows ?? []
            next = reply.next
            selected = nil
            rooms = []
            notice = nil
            previousRooms = [:]
            follows = Array((UserDefaults.standard.stringArray(forKey: RoomCircuitService.key(origin, "follows")) ?? []).prefix(12))
            nextFollow = 0
        }
    }

    func refresh() async {
        guard let service else { return }
        await perform { try await loadFirst(service) }
    }

    func loadMore() async {
        guard let service, let next else { return }
        await perform {
            let reply = try await service.get("list", offset: next)
            updateClock(reply)
            let known = Set(rows.map(\.id))
            rows.append(contentsOf: (reply.rows ?? []).filter { !known.contains($0.id) })
            self.next = reply.next
        }
    }

    func open(_ id: String) async {
        guard let service else { return }
        await perform { try await show(id, service: service) }
    }

    func closeDetail() {
        selected = nil
        rooms = []
    }

    func create(start: Date, game: String, app: String?) async -> Bool {
        guard let service else { return false }
        return await perform {
            let reply = try await service.create(start: start, game: game, app: app)
            updateClock(reply)
            rows = reply.rows ?? []
            next = reply.next
            if let row = reply.created {
                selected = row
                rooms = []
            }
        }
    }

    func changeReady(_ event: RoomCircuitAppointment) async {
        guard let service else { return }
        await perform {
            let reply = try await service.get(event.ready ? "leave" : "ready", id: event.id)
            rows = reply.rows ?? []
            next = reply.next
            updateClock(reply)
            try await show(event.id, service: service)
        }
    }

    func canReady(_ event: RoomCircuitAppointment) -> Bool {
        let opens = event.starts - (options?.readyBefore ?? 1800)
        return now.timeIntervalSince1970 >= TimeInterval(opens)
    }

    func toggleFollow(_ id: String) {
        guard let service else { return }
        if let i = follows.firstIndex(of: id) {
            follows.remove(at: i)
            previousRooms[id] = nil
        } else if follows.count < 12 {
            follows.append(id)
        }
        UserDefaults.standard.set(follows, forKey: RoomCircuitService.key(service.origin, "follows"))
    }

    func updateVisiblePanel() async {
        guard let service, !busy else { return }
        let origin = service.origin
        do {
            if let id = selected?.id {
                let reply = try await service.get("event", id: id)
                guard self.service?.origin == origin, selected?.id == id, !busy else { return }
                updateClock(reply)
                selected = reply.rows?.first
                let snapshot = try await service.get("rooms", id: id)
                guard self.service?.origin == origin, selected?.id == id, !busy else { return }
                rooms = snapshot.rooms ?? []
            } else {
                let page = try await service.get("list")
                guard self.service?.origin == origin, selected == nil, !busy else { return }
                updateClock(page)
                // Do not replace rows the user explicitly paged in.
                if rows.count <= 6 {
                    rows = page.rows ?? []
                    next = page.next
                }
            }

            let ids = follows
            guard !ids.isEmpty else { return }
            let count = min(ids.count, 3)
            let batch = (0..<count).map { ids[(nextFollow + $0) % ids.count] }
            nextFollow = (nextFollow + count) % ids.count
            for id in batch {
                let reply = try await service.get("rooms", id: id)
                guard self.service?.origin == origin, !busy else { return }
                if !follows.contains(id) { continue }
                let current = Set((reply.rooms ?? []).filter(\.crossplay).map(\.host))
                if !current.subtracting(previousRooms[id] ?? []).isEmpty {
                    notice = id
                }
                previousRooms[id] = current
            }
        } catch {
            // Polling is best-effort. Manual operations show exact errors and keep their last result.
        }
    }

    func clearNotice() { notice = nil }

    private func show(_ id: String, service: RoomCircuitService) async throws {
        let reply = try await service.get("event", id: id)
        updateClock(reply)
        guard let event = reply.rows?.first else { throw RoomCircuitFailure.response(404, "not_found") }
        selected = event
        rooms = []
        let snapshot = try await service.get("rooms", id: id)
        rooms = snapshot.rooms ?? []
        if notice == id { notice = nil }
    }

    private func loadFirst(_ service: RoomCircuitService) async throws {
        let reply = try await service.get("list")
        updateClock(reply)
        rows = reply.rows ?? []
        next = reply.next
    }

    private func updateClock(_ reply: RoomCircuitReply) {
        if let stamp = reply.now, (0...4_102_444_800).contains(stamp) {
            clockOffset = stamp - Int(Date().timeIntervalSince1970)
        }
    }

    @discardableResult
    private func perform(_ work: () async throws -> Void) async -> Bool {
        guard !busy else { return false }
        busy = true
        failure = nil
        defer { busy = false }
        do {
            try await work()
            return true
        } catch is CancellationError {
            return false
        } catch {
            failure = error
            return false
        }
    }
}

struct RoomCircuitPanel: View {
    let host: RoomCircuitAppleHost
    let chinese: Bool
    var showsClose = true
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = RoomCircuitAppointments()
    @State private var showCreate = false
    @State private var date = Date()
    @State private var game = ""
    @State private var manualLCID = ""
    @State private var manualApp = ""

    private func word(_ english: String, _ simplified: String) -> String { chinese ? simplified : english }

    var body: some View {
        NavigationStack {
            Form {
                Section(word("Server", "服务器")) {
                    TextField("https://rooms.example.net", text: $model.address)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                    Button(model.service == nil ? word("Connect", "连接") : word("Apply server", "应用服务器")) {
                        Task { await model.connect() }
                    }
                    if let origin = model.service?.origin {
                        Text(origin.absoluteString).font(.footnote).foregroundStyle(.secondary)
                    }
                }

                if model.service != nil {
                    if let notice = model.notice {
                        Section(word("Room open", "房间已开放")) {
                            Button(word("View followed appointment", "查看关注的约战")) {
                                Task { await model.open(notice) }
                            }
                            Button(word("Dismiss notice", "关闭提醒")) { model.clearNotice() }
                        }
                    }

                    if let event = model.selected {
                        detail(event)
                    } else {
                        schedule
                    }
                    connectionInfo
                }
                if model.busy { ProgressView().frame(maxWidth: .infinity) }
                if let error = model.failure, !showCreate {
                    Text(message(error)).foregroundStyle(.red).accessibilityAddTraits(.updatesFrequently)
                }
            }
            .disabled(model.busy)
            .navigationTitle(word("RoomCircuit", "RoomCircuit"))
            .toolbar {
                if showsClose {
                    ToolbarItem(placement: .cancellationAction) { Button(word("Close", "关闭")) { dismiss() } }
                }
            }
            .sheet(isPresented: $showCreate) { createForm }
        }
        .frame(minWidth: minimumWidth, minHeight: minimumHeight)
        .task {
            if !model.address.isEmpty { await model.connect() }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(20)) }
                catch { return }
                if scenePhase == .active { await model.updateVisiblePanel() }
            }
        }
    }

    private var minimumWidth: CGFloat? {
        #if os(macOS)
        480
        #else
        nil
        #endif
    }

    private var minimumHeight: CGFloat? {
        #if os(macOS)
        460
        #else
        nil
        #endif
    }

    private var schedule: some View {
        Section(word("Appointments", "约战")) {
            Button(word("New appointment", "发起约战"), systemImage: "plus") {
                date = model.now.addingTimeInterval(15 * 60)
                game = model.options?.games.first?.id ?? ""
                manualLCID = ""
                manualApp = ""
                model.failure = nil
                showCreate = true
            }
            Button(word("Refresh", "刷新"), systemImage: "arrow.clockwise") { Task { await model.refresh() } }
            if model.rows.isEmpty { Text(word("No appointments yet.", "暂无约战。")).foregroundStyle(.secondary) }
            ForEach(model.rows) { row in
                Button {
                    Task { await model.open(row.id) }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title(row))
                        Text(dateLabel(row) + " · " + countLabel(row)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if model.next != nil {
                Button(word("Show more", "加载更多")) { Task { await model.loadMore() } }
            }
        }
    }

    private func detail(_ event: RoomCircuitAppointment) -> some View {
        Group {
            Section(title(event)) {
                Text(dateLabel(event) + " · " + countLabel(event))
                Button(event.ready ? word("Cancel ready", "取消就绪") : word("Ready", "标记就绪")) {
                    Task { await model.changeReady(event) }
                }
                .disabled(!event.ready && !model.canReady(event))
                if !event.ready && !model.canReady(event) {
                    let minutes = (model.options?.readyBefore ?? 1800) / 60
                    Text(word("Ready opens \(minutes) minutes before the appointment.", "约战前 \(minutes) 分钟可标记就绪。"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button(model.follows.contains(event.id) ? word("Unfollow", "取消关注") : word("Follow", "关注")) {
                    model.toggleFollow(event.id)
                }
                .disabled(!model.follows.contains(event.id) && model.follows.count >= 12)
                Button(word("Back to appointments", "返回约战列表")) { model.closeDetail() }
            }

            Section(word("Compatible open rooms", "可加入的跨端房间")) {
                let compatible = model.rooms.filter(\.crossplay)
                if compatible.isEmpty {
                    Text(word("No compatible room is open.", "暂无可加入的跨端房间。")).foregroundStyle(.secondary)
                }
                ForEach(Array(compatible.enumerated()), id: \.offset) { _, room in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(room.host)
                        let match = room.appointmentBound ? word("This appointment", "本次约战") :
                            room.titleConfirmed ? word("Matching game", "同一游戏") : word("Matching LCID", "联机 ID 匹配")
                        Text("\(room.players)/\(room.max) · \(match)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button(word("Refresh rooms", "刷新房间")) { Task { await model.open(event.id) } }
            }
        }
    }

    private var connectionInfo: some View {
        Section(word("Play together", "联机设置")) {
            if let route = model.options?.endpoints.first(where: { $0.id == "lanplay" }) {
                LabeledContent(word("LAN Play relay", "LAN Play 中继")) {
                    Text(route.address).textSelection(.enabled)
                }
                let instructions = switch host {
                case .meloNX:
                    word("Use a compatible Wi-Fi gateway and a MeloNX build with LAN Play routing. Join from the game’s Local Wireless menu.",
                         "使用兼容的 Wi-Fi 网关和支持 LAN Play 路由的 MeloNX 构建，再从游戏的本地通信菜单加入。")
                case .nxPocket:
                    word("Set up the Wi-Fi gateway and join from a supported game’s Local Wireless menu.",
                         "先设置 Wi-Fi 网关，再从支持的游戏的本地通信菜单加入。")
                }
                Text(instructions).font(.footnote).foregroundStyle(.secondary)
            } else {
                Text(word("LAN Play is not enabled on this relay.", "此中继尚未开启 LAN Play。")).foregroundStyle(.secondary)
            }
        }
    }

    private var createForm: some View {
        NavigationStack {
            Form {
                Picker(word("Game", "游戏"), selection: $game) {
                    ForEach(model.options?.games ?? []) { option in
                        Text(chinese ? option.zh ?? option.name : option.name).tag(option.id)
                    }
                    Text(word("Enter local communication ID", "手动填写联机 ID")).tag("")
                }
                if game.isEmpty {
                    TextField(word("16-digit LCID", "16 位联机 ID"), text: $manualLCID).autocorrectionDisabled()
                    TextField(word("App ID (optional)", "应用 ID（选填）"), text: $manualApp).autocorrectionDisabled()
                }
                DatePicker(word("Starts", "开始时间"), selection: $date)
                if model.busy { ProgressView() }
                if let error = model.failure { Text(message(error)).foregroundStyle(.red) }
            }
            .disabled(model.busy)
            .navigationTitle(word("New appointment", "发起约战"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(word("Cancel", "取消")) { showCreate = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(word("Create", "发布")) {
                        let selected = model.options?.games.first { $0.id == game }
                        let app = manualApp.trimmingCharacters(in: .whitespacesAndNewlines)
                        Task {
                            if await model.create(start: date, game: selected?.game ?? manualLCID,
                                                  app: selected?.app ?? (selected == nil && !app.isEmpty ? app : nil)) {
                                showCreate = false
                            }
                        }
                    }
                    .disabled(model.busy)
                }
            }
            .interactiveDismissDisabled(model.busy)
        }
        .frame(minWidth: minimumWidth, minHeight: minimumHeight)
    }

    private func title(_ event: RoomCircuitAppointment) -> String {
        let game = model.options?.games.first {
            $0.game.caseInsensitiveCompare(event.game) == .orderedSame &&
            $0.app?.caseInsensitiveCompare(event.app) == .orderedSame
        }
        return (chinese ? game?.zh ?? game?.name : game?.name) ?? event.game.uppercased()
    }

    private func dateLabel(_ event: RoomCircuitAppointment) -> String {
        Date(timeIntervalSince1970: TimeInterval(event.starts)).formatted(date: .abbreviated, time: .shortened)
    }

    private func countLabel(_ event: RoomCircuitAppointment) -> String {
        chinese ? "\(event.interested) 人就绪" : "\(event.interested) ready"
    }

    private func message(_ error: Error) -> String {
        switch error as? RoomCircuitFailure {
        case .origin: word("Enter an HTTPS server address, or an HTTP address on your local network.",
                           "请输入 HTTPS 服务器地址，或本地网络的 HTTP 地址。")
        case .capability: word("Update the relay to a version that supports native appointments.",
                               "请将中继升级到支持原生约战的版本。")
        case .input: word("Enter a valid 16-digit hexadecimal local communication ID.",
                          "请输入有效的 16 位十六进制联机 ID。")
        case .response(_, "limit"): word("Too many requests. Wait and try again.", "请求过多，请稍后再试。")
        case .response(_, "invalid"): word("Check the start time or readiness window.", "请检查开始时间或就绪时间。")
        case .response(_, "not_found"): word("That appointment is no longer available.", "该约战已不可用。")
        default: word("Could not load RoomCircuit. Check the server and try again.", "无法读取 RoomCircuit，请检查服务器后重试。")
        }
    }
}
