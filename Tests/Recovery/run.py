"""Exercise the actual controller with local sessions and shortened retry delays."""
from pathlib import Path
import subprocess
import tempfile
import os

root = Path(__file__).resolve().parents[2]
build = root / '.build' / 'recovery'
build.mkdir(parents=True, exist_ok=True)
source = (root / 'Sources/RemoteFinder/BrowserController.swift').read_text()
source = source.replace('private ', '')
source = source.replace('        _ = transfers', '')
source = source.replace('FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/RemoteFinder/Transfers")', 'URL(fileURLWithPath: ProcessInfo.processInfo.environment["RF_TRANSFER_TEST_ROOT"]!)')
source = source.replace('SFTPClient(profile: connection, askpass: helper.path, interactive: interactive)', 'testSession(profile: connection, askpass: helper.path, interactive: interactive)')
source = source.replace('SFTPClient(profile: connection, askpass: helper.path, interactive: false)', 'testSession(profile: connection, askpass: helper.path, interactive: false)')
source = source.replace('SFTPClient(profile: connection, askpass: helper.path)', 'testSession(profile: connection, askpass: helper.path)')
source = source.replace('[1, 2, 4, 8, 16]', '[0.01, 0.02, 0.04, 0.08, 0.16]')
a = source.index('    func showError(_ message: String) {')
b = source.index('    func controlTextDidChange', a)
source = source[:a] + '    func showError(_ message: String) { testErrors.append(message) }\n' + source[b:]
controller = build / 'BrowserController.swift'
controller.write_text(source)
command = ['swiftc'] + [str(p) for p in (root / 'Sources/RemoteFinderCore').glob('*.swift')]
command += [str(root / 'Sources/RemoteFinder/RemotePathBar.swift'), str(root / 'Sources/RemoteFinder/TransferWindow.swift'), str(controller), str(root / 'Tests/Recovery/main.swift'), '-o', str(build / 'tests')]
subprocess.run(command, cwd=root, check=True)
with tempfile.TemporaryDirectory(prefix='RF-drop-tests-') as state:
    subprocess.run([str(build / 'tests')], cwd=root, check=True, env=dict(os.environ, RF_TRANSFER_TEST_ROOT=state))
