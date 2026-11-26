import CryptoKit
import Darwin
import Foundation
import Security

protocol HostAdminBackend: Sendable {
    func status() async throws -> HostAdminStatus
    func setExpiry(_ expiryMS: Int64) async throws -> HostAdminStatus
    func newPassword(_ expiryMS: Int64) async throws -> HostAdminPassword
}

struct HostAdminStatus: Sendable {
    let state: String
    let nowMS: Int64
    let validFromMS: Int64?
    let validUntilMS: Int64?
}

struct HostAdminPassword: Sendable {
    let status: HostAdminStatus
    let password: String
}

struct HostAdminAdapter: HostAdminBackend {
    private static let managedRoot = "/Library/SlateHopHost"
    private static let bundlePath = managedRoot + "/RustDesk.app"
    private static let executablePath = bundlePath + "/Contents/MacOS/RustDesk"
    private static let maxTimestamp: Int64 = 253_402_300_799_999
    private static let queue = DispatchQueue(label: "com.slatehop.host-admin.cli", qos: .userInitiated)

    func status() async throws -> HostAdminStatus {
        try await Self.run(.status).status
    }

    func setExpiry(_ expiryMS: Int64) async throws -> HostAdminStatus {
        try await Self.run(.setExpiry(expiryMS)).status
    }

    func newPassword(_ expiryMS: Int64) async throws -> HostAdminPassword {
        let reply = try await Self.run(.newPassword(expiryMS))
        guard let password = reply.password else { throw AdapterError.invalidReply }
        return HostAdminPassword(status: reply.status, password: password)
    }

    static func connectionAddresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(first) }

        var addresses = Set<String>()
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard interface.ifa_flags & UInt32(IFF_UP) != 0,
                  interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  let address = interface.ifa_addr else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            let capacity = Int(NI_MAXHOST)
            var host = [CChar](repeating: 0, count: capacity)
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host,
                              socklen_t(capacity), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let value = String(cString: host)
            guard value != "0.0.0.0", value != "::", value != "::1",
                  !value.hasPrefix("127."), !value.hasPrefix("::ffff:127."),
                  !value.contains("%") else { continue }
            addresses.insert(value)
        }
        return addresses.sorted {
            if $0.contains(":") != $1.contains(":") { return !$0.contains(":") }
            return $0 < $1
        }
    }

    private enum Operation: Sendable {
        case status
        case setExpiry(Int64)
        case newPassword(Int64)

        var arguments: [String] {
            get throws {
                switch self {
                case .status:
                    return ["--rental-admin-status"]
                case .setExpiry(let expiry):
                    return ["--rental-admin-set-expiry", try Self.decimal(expiry)]
                case .newPassword(let expiry):
                    return ["--rental-admin-new-password", try Self.decimal(expiry)]
                }
            }
        }

        private static func decimal(_ expiry: Int64) throws -> String {
            guard expiry > 0, expiry <= HostAdminAdapter.maxTimestamp else {
                throw AdapterError.invalidExpiry
            }
            return String(expiry)
        }
    }

    private struct Reply: Decodable, Sendable {
        let state: String
        let nowMS: Int64
        let validFromMS: Int64?
        let validUntilMS: Int64?
        let password: String?

        private enum CodingKeys: String, CodingKey {
            case state, password
            case nowMS = "now_ms"
            case validFromMS = "valid_from_ms"
            case validUntilMS = "valid_until_ms"
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            state = try values.decode(String.self, forKey: .state)
            nowMS = try values.decode(Int64.self, forKey: .nowMS)
            validFromMS = try values.decodeIfPresent(Int64.self, forKey: .validFromMS)
            validUntilMS = try values.decodeIfPresent(Int64.self, forKey: .validUntilMS)
            password = try values.decodeIfPresent(String.self, forKey: .password)
            if state == "recovery_required" {
                guard values.contains(.validFromMS), values.contains(.validUntilMS) else {
                    throw AdapterError.invalidReply
                }
            }
        }

        var status: HostAdminStatus {
            HostAdminStatus(state: state, nowMS: nowMS, validFromMS: validFromMS, validUntilMS: validUntilMS)
        }

        func validate(for operation: Operation) throws {
            guard (0...HostAdminAdapter.maxTimestamp).contains(nowMS) else {
                throw AdapterError.invalidReply
            }
            let recovery = state == "recovery_required"
            if recovery {
                guard case .status = operation else { throw AdapterError.invalidReply }
            }
            switch (validFromMS, validUntilMS) {
            case (nil, nil):
                guard state == "unconfigured" || recovery else { throw AdapterError.invalidReply }
            case let (from?, until?):
                guard from >= 0, from < until, until <= HostAdminAdapter.maxTimestamp else {
                    throw AdapterError.invalidReply
                }
                let expected = nowMS < from ? "pending" : (nowMS < until ? "active" : "expired")
                guard state == expected || recovery else { throw AdapterError.invalidReply }
            default:
                throw AdapterError.invalidReply
            }
            switch operation {
            case .status:
                guard password == nil else { throw AdapterError.invalidReply }
            case .setExpiry(let expiry):
                guard password == nil, validUntilMS == expiry else { throw AdapterError.invalidReply }
            case .newPassword(let expiry):
                guard validUntilMS == expiry, let password, !password.isEmpty,
                      password.utf8.count <= 128,
                      password.utf8.allSatisfy({ (33...126).contains($0) }) else {
                    throw AdapterError.invalidReply
                }
            }
        }
    }

    private enum AdapterError: LocalizedError {
        case invalidExpiry, untrustedInstallation, cancelled, operationFailed, invalidReply

        var errorDescription: String? {
            switch self {
            case .invalidExpiry:
                return "截止时间超出允许范围。"
            case .untrustedInstallation:
                return "无法确认受信任的宿主安装。可使用演示模式。"
            case .cancelled:
                return "已取消管理员授权。"
            case .operationFailed:
                return "管理员操作未确认成功。请先刷新状态，再决定是否重试。"
            case .invalidReply:
                return "宿主回执无效。请先刷新状态，再决定是否重试。"
            }
        }
    }

    private static func run(_ operation: Operation) async throws -> Reply {
        let arguments = try operation.arguments
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let pin = try trustedHostDigest()
                    let data = try execute(arguments: arguments, digest: pin)
                    guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
                        throw AdapterError.invalidReply
                    }
                    try reply.validate(for: operation)
                    continuation.resume(returning: reply)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func trustedHostDigest() throws -> String {
        // A build-time pin identifies a reviewed CLI-capable host, including when an older
        // application has the same bundle identifier. An empty pin allows Demo only.
        guard getuid() != 0, geteuid() == getuid(),
              let pin = Bundle.main.object(forInfoDictionaryKey: "SlateHopTrustedHostSHA256") as? String,
              pin.utf8.count == 64,
              pin.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw AdapterError.untrustedInstallation
        }
        for directory in ["/", "/Library", managedRoot, bundlePath, bundlePath + "/Contents", bundlePath + "/Contents/MacOS"] {
            let entry = try protectedEntry(directory)
            guard entry.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
                throw AdapterError.untrustedInstallation
            }
        }
        let executable = try protectedEntry(executablePath)
        guard executable.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              executable.st_mode & 0o100 != 0, executable.st_mode & 0o6000 == 0 else {
            throw AdapterError.untrustedInstallation
        }

        let bundle = URL(fileURLWithPath: bundlePath, isDirectory: true)
        try verifyBundleTree(bundle)
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSCheckAllArchitectures)
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard Bundle(url: bundle)?.executableURL?.path == executablePath,
              SecStaticCodeCreateWithPath(bundle as CFURL, SecCSFlags(rawValue: 0), &code) == errSecSuccess,
              let code,
              SecRequirementCreateWithString("identifier \"com.carriez.rustdesk\"" as CFString,
                                             SecCSFlags(rawValue: 0), &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess,
              let bytes = try? Data(contentsOf: URL(fileURLWithPath: executablePath), options: .mappedIfSafe),
              SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == pin else {
            throw AdapterError.untrustedInstallation
        }
        return pin
    }

    private static func protectedEntry(_ path: String, allowBundleLink: Bool = false) throws -> stat {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == 0 else { throw AdapterError.untrustedInstallation }
        let kind = info.st_mode & mode_t(S_IFMT)
        if kind == mode_t(S_IFLNK), allowBundleLink { return info }
        guard kind == mode_t(S_IFDIR) || kind == mode_t(S_IFREG),
              info.st_mode & 0o022 == 0,
              permitsNoACLGrants(path) else { throw AdapterError.untrustedInstallation }
        return info
    }

    private static func permitsNoACLGrants(_ path: String) -> Bool {
        errno = 0
        guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else {
            return errno == ENOENT || errno == ENOATTR
        }
        defer { _ = acl_free(UnsafeMutableRawPointer(acl)) }

        var entry: acl_entry_t?
        var entryID: Int32 = 0 // ACL_FIRST_ENTRY
        while acl_get_entry(acl, entryID, &entry) == 0 {
            var tag = ACL_UNDEFINED_TAG
            guard let entry, acl_get_tag_type(entry, &tag) == 0, tag == ACL_EXTENDED_DENY else { return false }
            entryID = -1 // ACL_NEXT_ENTRY
        }
        return errno == EINVAL // Darwin reports the end of this valid ACL with EINVAL.
    }

    private static func verifyBundleTree(_ bundle: URL) throws {
        var mount = statfs()
        guard statfs(bundle.path, &mount) == 0, mount.f_flags & UInt32(MNT_LOCAL) != 0 else {
            throw AdapterError.untrustedInstallation
        }
        let bundleDevice = try protectedEntry(bundle.path).st_dev
        var traversalFailed = false
        guard let entries = FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: nil,
                                                           errorHandler: { _, _ in traversalFailed = true; return false }) else {
            throw AdapterError.untrustedInstallation
        }
        for case let entry as URL in entries {
            let info = try protectedEntry(entry.path, allowBundleLink: true)
            guard info.st_dev == bundleDevice else { throw AdapterError.untrustedInstallation }
            if info.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) {
                // Framework layout uses symlinks such as Versions/Current.
                let target = entry.resolvingSymlinksInPath().path
                guard target != entry.path, target.hasPrefix(bundlePath + "/") else {
                    throw AdapterError.untrustedInstallation
                }
                _ = try protectedEntry(target)
                entries.skipDescendants()
            }
        }
        guard !traversalFailed else { throw AdapterError.untrustedInstallation }
    }

    private static func execute(arguments: [String], digest: String) throws -> Data {
        // Open the same root-owned inode as the installer and retain the lock until
        // the child exits. Recheck the committed release after macOS authorizes.
        let recheck = #"""
        my ($root, $expected, $host, $bundle) = splice @ARGV, 0, 4;
        chdir "/" or exit 78;
        for my $dir ("/", "/Library", $root) {
            my @metadata = lstat $dir;
            @metadata && S_ISDIR($metadata[2]) && $metadata[4] == 0
                && !($metadata[2] & 0022) or exit 78;
        }
        sub protected_file {
            my ($path, $access) = @_;
            sysopen my $file, $path, $access | O_NOFOLLOW | O_NONBLOCK or exit 78;
            my @metadata = stat $file;
            @metadata && S_ISREG($metadata[2]) && $metadata[3] == 1
                && $metadata[4] == 0 && !($metadata[2] & 06022) or exit 78;
            return $file;
        }
        my $lock = protected_file("$root/.lifecycle.lock", O_RDWR);
        flock $lock, LOCK_EX | LOCK_NB or exit 75;
        lstat "$root/.transaction" and exit 75;
        $!{ENOENT} or exit 78;
        my $record = protected_file("$root/release.json", O_RDONLY);
        my $size = -s $record;
        $size > 0 && $size <= 4096 or exit 78;
        my $count = read($record, my $json, $size);
        defined $count && $count == $size or exit 78;
        my $release = eval { decode_json($json) };
        ref($release) eq "HASH" && ($release->{host_sha256} // "") eq $expected or exit 78;
        my $binary = protected_file($host, O_RDONLY);
        Digest::SHA->new(256)->addfile($binary)->hexdigest eq $expected or exit 78;
        system("/usr/bin/codesign", "--verify", "--deep", "--strict", "--all-architectures",
            "-R", q(=identifier "com.carriez.rustdesk"), $bundle) == 0 or exit 78;
        my $status = system { $host } $host, @ARGV;
        exit($status == -1 || ($status & 127) ? 1 : $status >> 8);
        """#
        let program = recheck.replacingOccurrences(of: "\n", with: " ")
        let command = "exec /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C /usr/bin/perl -MFcntl=:DEFAULT,:flock,:mode -MDigest::SHA -MJSON::PP -e '\(program)' \(managedRoot) \(digest) \(executablePath) \(bundlePath) \(arguments.joined(separator: " "))"
        let literal = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        try
            set replyText to do shell script "\(literal)" with administrator privileges without altering line endings
            return "ok" & linefeed & replyText
        on error number errorNumber
            if errorNumber is -128 then return "cancelled"
            if errorNumber is 78 then return "untrusted"
            return "failed"
        end try
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        process.currentDirectoryURL = URL(fileURLWithPath: "/", isDirectory: true)
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe.fileHandleForWriting
        defer { try? pipe.fileHandleForReading.close() }
        do { try process.run() } catch { throw AdapterError.operationFailed }
        try? pipe.fileHandleForWriting.close()

        var output = Data()
        do {
            while let chunk = try pipe.fileHandleForReading.read(upToCount: 4_096), !chunk.isEmpty {
                guard output.count + chunk.count <= 16_384 else { throw AdapterError.invalidReply }
                output.append(chunk)
            }
        } catch {
            if process.isRunning { process.terminate() }
            throw AdapterError.invalidReply
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: output, encoding: .utf8) else { throw AdapterError.operationFailed }
        if text.hasPrefix("ok\n") { return Data(text.dropFirst(3).utf8) }
        switch text.trimmingCharacters(in: .newlines) {
        case "cancelled": throw AdapterError.cancelled
        case "untrusted": throw AdapterError.untrustedInstallation
        default: throw AdapterError.operationFailed
        }
    }
}
