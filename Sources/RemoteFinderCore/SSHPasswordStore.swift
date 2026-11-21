import Foundation
import Security
import LocalAuthentication
import CryptoKit
import Darwin

// Passwords live only in the local Keychain; connection preferences contain no secrets.
struct SSHPasswordStore {
    let service: String

    init(profile: ConnectionProfile) {
        let identity = try! JSONEncoder().encode([profile.host, profile.user, profile.port])
        service = "local.remotefinder.ssh.password." + Self.digest(identity)
    }

    init(service: String) { self.service = service }

    static func passwordPrompt(_ prompt: String) -> String? {
        let value = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.contains("\n"), !value.contains("\r") else { return nil }
        // OpenSSH prefixes keyboard-interactive prompts with "(user@host) ".
        var challenge = value
        if let prefix = challenge.range(of: #"^\([^\s()]+@[^\s()]+\)\s*"#, options: .regularExpression) {
            challenge.removeSubrange(prefix)
        }
        let patterns = [#"(?i)^password\s*:$"#,
                        #"(?i)^[^\s@]+@[^\s]+'s password\s*:$"#,
                        #"(?i)^(?:enter )?password for [^\s:]+\s*:$"#,
                        #"(?i)^enter password\s*:$"#]
        if patterns.contains(where: { challenge.range(of: $0, options: .regularExpression) != nil }) { return value }
        return nil
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // The marker contains no password and bounds reuse to once per prompt per SSH attempt.
    static func claimSavedPassword(prompt: String, directory: String) -> Bool {
        let file = URL(fileURLWithPath: directory).appendingPathComponent(digest(Data(prompt.utf8))).path
        let descriptor = open(file, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { return false }
        close(descriptor)
        return true
    }

    private func query(prompt: String? = nil) -> [String: Any] {
        var result: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                     kSecAttrService as String: service,
                                     kSecAttrSynchronizable as String: false]
        if let prompt = prompt { result[kSecAttrAccount as String] = prompt }
        return result
    }

    func password(prompt: String, allowInteraction: Bool) throws -> String? {
        var request = query(prompt: prompt)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        if !allowInteraction {
            let context = LAContext(); context.interactionNotAllowed = true
            request[kSecUseAuthenticationContext as String] = context
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data, let password = String(data: data, encoding: .utf8) else {
            throw RemoteError("钥匙串中的密码无法读取，请忘记密码后重新输入。")
        }
        return password
    }

    func save(_ password: String, prompt: String, label: String) throws {
        let attributes: [String: Any] = [kSecValueData as String: Data(password.utf8),
                                         kSecAttrLabel as String: "RemoteFinder · " + label]
        let status = SecItemUpdate(query(prompt: prompt) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            try check(SecItemAdd(query(prompt: prompt).merging(attributes) { _, new in new } as CFDictionary, nil))
        } else { try check(status) }
    }

    func forget(prompt: String? = nil) throws {
        var request = query(prompt: prompt)
        request[kSecMatchLimit as String] = kSecMatchLimitAll
        let status = SecItemDelete(request as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private func check(_ status: OSStatus) throws {
        guard status != errSecSuccess else { return }
        throw RemoteError("无法访问 macOS 钥匙串（\(status)）。请确认登录钥匙串已解锁，并允许 RemoteFinder 访问。")
    }
}
