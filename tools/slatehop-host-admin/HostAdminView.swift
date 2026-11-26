import AppKit
import SwiftUI

@MainActor
struct HostAdminView: View {
    @StateObject private var model: HostAdminWindowModel
    @State private var confirmedExpiry = Date()
    @State private var confirmPasswordChange = false
    private let deviceName: String
    private let addresses: [String]
    private let demo: Bool

    init(backend: HostAdminBackend, deviceName: String, addresses: [String], demo: Bool) {
        _model = StateObject(wrappedValue: HostAdminWindowModel(backend: backend))
        self.deviceName = deviceName
        self.addresses = addresses
        self.demo = demo
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                deviceCard
                if let message = model.message {
                    Label(message, systemImage: model.failed ? "exclamationmark.circle" : "info.circle")
                        .foregroundColor(model.failed ? .red : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.updatesFrequently)
                }
                expiryCard
                passwordCard
            }
            .frame(maxWidth: 700)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 560, idealWidth: 660, minHeight: 580, idealHeight: 740)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            if demo { await model.refresh() }
        }
        .onDisappear { model.closeWindow() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            model.hidePassword()
        }
        .alert(passwordDialogTitle, isPresented: $confirmPasswordChange) {
            Button("取消", role: .cancel) {}
            if model.requiresRecovery {
                Button("重新签发密码", role: .destructive) { issueConfirmedPassword() }
            } else if model.hasPolicy {
                Button("重置密码", role: .destructive) { issueConfirmedPassword() }
            } else {
                Button("生成密码") { issueConfirmedPassword() }
            }
        } message: {
            Text(passwordConfirmation)
        }
        .environment(\.locale, Locale(identifier: "zh_Hans_CN"))
    }

    private var deviceCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .frame(width: 48, height: 48)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(deviceName).font(.title2.weight(.semibold))
                    Text("连接设备与有效期").foregroundColor(.secondary)
                }
                Spacer(minLength: 8)
                if model.busy {
                    ProgressView().controlSize(.small).accessibilityLabel("正在处理")
                }
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label(model.snapshot == nil ? "读取状态" : "刷新", systemImage: "arrow.clockwise")
                }
                .disabled(model.busy)
            }
            if demo {
                Label("演示模式 · 合成设备，退出后重置", systemImage: "sparkles")
                    .font(.callout.weight(.semibold))
                    .foregroundColor(.accentColor)
            } else if model.snapshot == nil {
                Text("读取状态需要 macOS 管理员授权。").font(.caption).foregroundColor(.secondary)
            }
            Divider()
            TimelineView(.periodic(from: Date(), by: 15)) { context in
                let state = model.stateBadge(at: context.date)
                HStack {
                    Label(state.label, systemImage: state.symbol)
                        .font(.callout.weight(.semibold))
                    Spacer()
                    if !model.requiresRecovery, let end = model.currentExpiry {
                        Text("有效期至 \(format(end))").font(.callout)
                    }
                }
            }
            if model.requiresRecovery {
                Label("连接授权已暂停。请重新签发远控密码。", systemImage: "exclamationmark.shield")
                    .font(.callout.weight(.semibold))
                    .foregroundColor(.orange)
                if let start = model.currentStart, let end = model.currentExpiry {
                    Text("原有效期 \(format(start)) 至 \(format(end))")
                        .font(.callout).foregroundColor(.secondary)
                } else {
                    Text("原有效期未知").font(.callout).foregroundColor(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("本机地址").font(.callout.weight(.semibold))
                if addresses.isEmpty {
                    Text("没有找到可报告的本机地址，请检查网络。").foregroundColor(.secondary)
                }
                ForEach(addresses, id: \.self) { address in
                    HStack {
                        Text(verbatim: address).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        Spacer(minLength: 8)
                        Button {
                            model.copyAddress(address)
                        } label: {
                            Label("复制地址", systemImage: "doc.on.doc")
                        }
                        .accessibilityLabel("复制地址 \(address)")
                    }
                }
                if !demo && !addresses.isEmpty {
                    Text("直连是否可用取决于网络和主机配置；端口以实际配置为准。")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
        }
        .padding(18)
        .background(
            LinearGradient(
                colors: [Color.accentColor.opacity(0.12), Color(nsColor: .controlBackgroundColor)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 16)
        )
    }

    private var expiryCard: some View {
        card("有效期", symbol: "calendar") {
            if model.requiresRecovery {
                Text("选择重新签发后的截止时间。").foregroundColor(.secondary)
            } else if model.isUnconfigured {
                Text("先选择截止时间，再生成第一把远控密码。").foregroundColor(.secondary)
            } else {
                Text("续期保留现有远控密码。快捷选项从现有截止时间或当前时间中的较晚者起算。")
                    .foregroundColor(.secondary)
            }
            if !model.requiresRecovery {
                HStack(spacing: 8) {
                    Button("延长 1 小时") { model.chooseExtension(3_600) }
                    Button("延长 7 天") { model.chooseExtension(7 * 86_400) }
                }
                .disabled(!model.canSaveExpiry || model.busy)
            }
            DatePicker("截止时间", selection: $model.expiry, displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.field)
                .disabled(model.snapshot == nil || model.busy)
            Text("时区 \(TimeZone.current.identifier)")
                .font(.caption).foregroundColor(.secondary)
            if let issue = model.expiryIssue(model.expiry), model.snapshot != nil {
                Text(issue).font(.callout).foregroundColor(.red)
            }
            if model.canSaveExpiry {
                Button("保存有效期") {
                    let expiry = model.expiry
                    Task { await model.saveExpiry(expiry) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.busy || model.expiryIssue(model.expiry) != nil)
            }
        }
    }

    private var passwordCard: some View {
        card("远控密码", symbol: "key") {
            if model.requiresRecovery {
                Text("旧密码可能已不可用。重新签发后，请更新已提供给租客的设备信息。")
                    .foregroundColor(.secondary)
            } else {
                Text(model.isUnconfigured ? "为此设备生成独立远控密码。" : "已保存的密码无法查看。忘记密码时可以重置。")
                    .foregroundColor(.secondary)
            }
            if model.hasPasswordResult {
                VStack(alignment: .leading, spacing: 9) {
                    Text("本次生成的密码").font(.callout.weight(.semibold))
                    if let password = model.visiblePassword {
                        Text(verbatim: password).font(.system(.body, design: .monospaced))
                    } else {
                        Text("密码已隐藏").foregroundColor(.secondary)
                    }
                    HStack(spacing: 8) {
                        Button(model.visiblePassword == nil ? "显示" : "隐藏") { model.togglePassword() }
                        Button("复制密码") { model.copyPassword() }
                        Button("清除结果") { model.clearPassword() }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
            if model.canIssuePassword {
                Button(passwordActionTitle) {
                    confirmedExpiry = model.expiry
                    confirmPasswordChange = true
                }
                .disabled(model.busy || model.expiryIssue(model.expiry) != nil)
                if !demo {
                    Text("此操作需要 macOS 管理员授权。").font(.caption).foregroundColor(.secondary)
                }
            }
        }
    }

    private var passwordActionTitle: String {
        if model.requiresRecovery { return "重新签发密码…" }
        return model.hasPolicy ? "重置密码…" : "生成密码…"
    }

    private var passwordDialogTitle: String {
        if model.requiresRecovery { return "重新签发远控密码？" }
        return model.hasPolicy ? "重置远控密码？" : "生成远控密码？"
    }

    private var passwordConfirmation: String {
        let deadline = "所选截止时间为 \(format(confirmedExpiry))（\(TimeZone.current.identifier)）。"
        if model.requiresRecovery {
            return "\(deadline) 旧密码可能已不可用。继续后请使用新密码，并更新已提供给租客的设备信息。"
        }
        if model.hasPolicy {
            return "\(deadline) 重置后旧密码将无法建立新连接，请及时更新对外提供的设备信息。"
        }
        return deadline
    }

    private func issueConfirmedPassword() {
        let expiry = confirmedExpiry
        Task { await model.issuePassword(expiry) }
    }

    private func card<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
    }

    private func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy年M月d日 HH:mm:ss"
        return formatter.string(from: date)
    }
}

@MainActor
private final class HostAdminWindowModel: ObservableObject {
    @Published private(set) var snapshot: HostAdminStatus?
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    @Published private(set) var failed = false
    @Published var expiry = Date()
    @Published private var password: String?
    @Published private var revealed = false

    private let backend: HostAdminBackend
    private var windowGeneration = 0

    init(backend: HostAdminBackend) {
        self.backend = backend
    }

    var isUnconfigured: Bool { snapshot?.state == "unconfigured" }
    var requiresRecovery: Bool { snapshot?.state == "recovery_required" }
    var hasPolicy: Bool { currentExpiry != nil && currentStart != nil }
    var canSaveExpiry: Bool { hasPolicy && !requiresRecovery }
    var canIssuePassword: Bool { hasPolicy || isUnconfigured || requiresRecovery }
    var hasPasswordResult: Bool { password != nil }
    var visiblePassword: String? { revealed ? password : nil }
    var currentExpiry: Date? { snapshot?.validUntilMS.map(Self.date) }
    var currentStart: Date? { snapshot?.validFromMS.map(Self.date) }

    func stateBadge(at date: Date) -> (label: String, symbol: String) {
        if requiresRecovery { return ("需要恢复", "exclamationmark.shield") }
        if let snapshot, let start = snapshot.validFromMS, let end = currentExpiry {
            if date >= end { return ("已过期", "exclamationmark.circle") }
            if date < Self.date(start) { return ("尚未生效", "clock") }
            return ("有效", "checkmark.circle.fill")
        }
        return isUnconfigured ? ("尚未配置", "clock") : ("状态未确认", "questionmark.circle")
    }

    func refresh() async {
        guard !busy else { return }
        busy = true
        message = nil
        defer { busy = false }
        do {
            let status = try await backend.status()
            snapshot = status
            expiry = suggestedExpiry(status)
            clearPassword()
        } catch {
            if Self.isCancellation(error) {
                show("读取已取消，可以重试。")
            } else {
                snapshot = nil
                clearPassword()
                show(Self.safeInstallMessage(error) ?? "无法读取主机状态。请检查本机 SlateHop 服务后重试。", failure: true)
            }
        }
    }

    func chooseExtension(_ seconds: TimeInterval) {
        guard !busy, canSaveExpiry, let currentExpiry else { return }
        expiry = max(currentExpiry, Date()).addingTimeInterval(seconds)
    }

    func expiryIssue(_ date: Date) -> String? {
        guard let snapshot, let milliseconds = Self.milliseconds(date) else {
            return "请先刷新状态，再选择截止时间。"
        }
        if date <= Date() || milliseconds <= snapshot.nowMS {
            return "截止时间必须晚于现在。"
        }
        if let from = snapshot.validFromMS, milliseconds <= from {
            return "截止时间必须晚于凭证生效时间。"
        }
        return nil
    }

    func saveExpiry(_ date: Date) async {
        guard !busy, canSaveExpiry else { return }
        if let issue = expiryIssue(date) {
            show(issue, failure: true)
            return
        }
        guard let deadline = Self.milliseconds(date) else { return }
        busy = true
        message = nil
        defer { busy = false }
        do {
            let status = try await backend.setExpiry(deadline)
            snapshot = status
            expiry = status.validUntilMS.map(Self.date) ?? date
            show("有效期已保存，远控密码保持原样。")
        } catch {
            handleWriteFailure(error, action: "保存有效期")
        }
    }

    func issuePassword(_ date: Date) async {
        guard !busy, canIssuePassword else { return }
        if let issue = expiryIssue(date) {
            show(issue, failure: true)
            return
        }
        guard let deadline = Self.milliseconds(date) else { return }
        let wasRecovery = requiresRecovery
        let generation = windowGeneration
        busy = true
        message = nil
        clearPassword()
        defer { busy = false }
        do {
            let result = try await backend.newPassword(deadline)
            snapshot = result.status
            expiry = result.status.validUntilMS.map(Self.date) ?? date
            if generation == windowGeneration {
                password = result.password
                show(wasRecovery ? "密码已重新签发，请按需显示或复制本次结果。" : "密码已生成，请按需显示或复制本次结果。")
            }
        } catch {
            handleWriteFailure(error, action: wasRecovery ? "重新签发密码" : "生成密码")
        }
    }

    func closeWindow() {
        windowGeneration += 1
        clearPassword()
    }

    func clearPassword() {
        password = nil
        revealed = false
    }

    func hidePassword() { revealed = false }
    func togglePassword() { revealed.toggle() }

    func copyAddress(_ address: String) { copy(address, label: "地址") }
    func copyPassword() {
        guard let password else { return }
        copy(password, label: "密码")
    }

    private func copy(_ text: String, label: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let copied = pasteboard.setString(text, forType: .string)
        show(copied ? "\(label)已复制。" : "无法复制\(label)。", failure: !copied)
    }

    private func handleWriteFailure(_ error: Error, action: String) {
        if Self.isCancellation(error) {
            show("操作已取消，可以重试。")
        } else {
            // A failed response may follow a write. Refresh before permitting another mutation.
            // Adapter error details are not displayed because they may contain sensitive output.
            snapshot = nil
            clearPassword()
            show(Self.safeInstallMessage(error) ?? "未能确认\(action)的结果，请重新读取主机状态后再试。", failure: true)
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        // The current adapter exposes a fixed LocalizedError description, not its private enum.
        if (error as? LocalizedError)?.errorDescription == "已取消管理员授权。" { return true }
        let native = error as NSError
        return (native.domain == NSCocoaErrorDomain && native.code == CocoaError.Code.userCancelled.rawValue)
            || (native.domain == NSOSStatusErrorDomain && native.code == -128)
    }

    private static func safeInstallMessage(_ error: Error) -> String? {
        let message = "无法确认受信任的宿主安装。可使用演示模式。"
        return (error as? LocalizedError)?.errorDescription == message ? message : nil
    }

    private func show(_ text: String, failure: Bool = false) {
        message = text
        failed = failure
    }

    private func suggestedExpiry(_ status: HostAdminStatus) -> Date {
        let now = max(Self.date(status.nowMS), Date())
        if let end = status.validUntilMS.map(Self.date), end > now { return end }
        let start = status.validFromMS.map(Self.date) ?? now
        return max(start, now).addingTimeInterval(3_600)
    }

    private static func date(_ milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }

    private static func milliseconds(_ date: Date) -> Int64? {
        Int64(exactly: (date.timeIntervalSince1970 * 1_000).rounded())
    }
}
