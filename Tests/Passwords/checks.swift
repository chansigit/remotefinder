func checkPasswords() throws {
    let connection = ConnectionProfile(host: "fixture-" + UUID().uuidString, user: "test", port: "2222")
    let store = SSHPasswordStore(profile: connection)
    defer { try? store.forget() }
    let prompt = "test@fixture's password:"
    for text in ["Password:", "password: ", prompt,
                 "(test@cluster.example) Password:", "(test@cluster.example) Password for test:",
                 "Password for test@EXAMPLE.EDU:", "Enter password for test@cluster.example:", "Enter password:"] { precondition(SSHPasswordStore.passwordPrompt(text) != nil) }
    for text in ["Verification code:", "(test@cluster.example) Verification code:", "(test@cluster.example) Passcode or option (1-3):", "Password + verification code:", "One-time password:", "(test@cluster.example) One-time password:", "Passcode or option (1-3):", "Enter passphrase for key '/tmp/test':", "Password + OTP:", "New password:", "Password:\nVerification code:", "Are you sure you want to continue connecting (yes/no)?"] {
        precondition(SSHPasswordStore.passwordPrompt(text) == nil, "Do not save non-password challenges")
    }
    precondition(SSHPasswordStore(profile: ConnectionProfile(host: connection.host, user: "test", port: "2222", path: "/different")).service == store.service)
    for other in [ConnectionProfile(host: "different", user: "test", port: "2222"), ConnectionProfile(host: connection.host, user: "other", port: "2222"), ConnectionProfile(host: connection.host, user: "test", port: "22")] {
        precondition(SSHPasswordStore(profile: other).service != store.service)
    }
    let missing = try store.password(prompt: prompt, allowInteraction: false)
    precondition(missing == nil)
    try store.save("synthetic-one", prompt: prompt, label: "Temporary test credential")
    try store.save("synthetic-two-中文", prompt: prompt, label: "Temporary test credential")
    let stored = try store.password(prompt: prompt, allowInteraction: false)
    precondition(stored == "synthetic-two-中文")
    let otherPrompt = try store.password(prompt: "other@fixture's password:", allowInteraction: false)
    precondition(otherPrompt == nil, "Resolved SSH identity must match the prompt")
    let state = FileManager.default.temporaryDirectory.appendingPathComponent("RemoteFinder-password-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: state) }
    func ask(_ challenge: String, service: String? = nil) throws -> (Int32, Data) {
        let child = Process(); child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--askpass", challenge]
        var env = ProcessInfo.processInfo.environment
        env["REMOTEFINDER_AUTH_INTERACTIVE"] = "0"
        env["REMOTEFINDER_PASSWORD_SERVICE"] = service ?? store.service
        env["REMOTEFINDER_AUTH_STATE"] = state.path
        child.environment = env
        let pipe = Pipe(); child.standardOutput = pipe; child.standardError = FileHandle.nullDevice
        try child.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        child.waitUntilExit()
        return (child.terminationStatus, output)
    }
    let first = try ask(prompt)
    precondition(first.0 == 0 && first.1 == Data("synthetic-two-中文\n".utf8))
    precondition(FileManager.default.fileExists(atPath: state.appendingPathComponent("used-saved-password").path))
    let second = try ask(prompt)
    precondition(second.0 != 0 && second.1.isEmpty, "Never resubmit a rejected saved password")
    for challenge in ["Verification code:", "Enter passphrase for key '/tmp/test':", "Are you sure (yes/no)?", "Password:"] {
        let result = try ask(challenge)
        precondition(result.0 != 0 && result.1.isEmpty, "Background authentication must not prompt")
    }
    let prefixed = "(test@cluster.example) Password for test:"
    try store.save("synthetic-prefixed", prompt: prefixed, label: "Temporary prefixed prompt")
    let reused = try ask(prefixed)
    precondition(reused.0 == 0 && reused.1 == Data("synthetic-prefixed\n".utf8), "OpenSSH keyboard-interactive prefixed password is reused")
    try store.save("synthetic-other", prompt: "Password:", label: "Temporary test credential")
    try store.forget(prompt: prompt)
    let removed = try store.password(prompt: prompt, allowInteraction: false)
    let retained = try store.password(prompt: "Password:", allowInteraction: false)
    precondition(removed == nil && retained == "synthetic-other")
    try store.forget()
    let forgotten = try store.password(prompt: "Password:", allowInteraction: false)
    precondition(forgotten == nil)
    try store.forget()
    print("PASS: real Keychain create/update/read/delete, connection isolation, password prompt classification, actual askpass reuse, rejected-password bound and silent background authentication")
}
do { try checkPasswords() } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
