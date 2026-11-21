"""Test the shipping askpass branch without prompting or using real credentials."""
from pathlib import Path
import subprocess
root = Path(__file__).resolve().parents[2]
build = root / '.build' / 'passwords'
build.mkdir(parents=True, exist_ok=True)
source = (root / 'Sources/RemoteFinder/main.swift').read_text().split('final class AppDelegate:')[0]
source += (root / 'Tests/Passwords/checks.swift').read_text()
(build / 'main.swift').write_text(source)
command = ['swiftc'] + [str(p) for p in (root / 'Sources/RemoteFinderCore').glob('*.swift')]
command += [str(build / 'main.swift'), '-o', str(build / 'tests')]
subprocess.run(command, cwd=root, check=True)
subprocess.run(['codesign', '--force', '--sign', '-', str(build / 'tests')], check=True)
subprocess.run([str(build / 'tests')], cwd=root, check=True)
