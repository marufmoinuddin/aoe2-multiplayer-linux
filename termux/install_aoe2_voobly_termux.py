#!/usr/bin/env python3
"""Compatibility entrypoint: the Termux runtime is now upstream Mobox.

The former custom Kron4ek/Winetricks implementation is available in Git history.
"""
import os
import subprocess
import urllib.request
from pathlib import Path


def main():
    target = Path.home() / '.aoe2-termux/install-mobox-aoe2.sh'
    target.parent.mkdir(parents=True, exist_ok=True)
    local = Path(__file__).resolve().with_name('install-mobox-aoe2.sh')
    if local.is_file():
        content = local.read_bytes()
    else:
        ref = os.environ.get('AOE2_TERMUX_REF', 'main')
        url = f'https://raw.githubusercontent.com/marufmoinuddin/aoe2-multiplayer-linux/{ref}/termux/install-mobox-aoe2.sh'
        with urllib.request.urlopen(url, timeout=60) as response:
            content = response.read()
    temp = target.with_suffix('.tmp')
    temp.write_bytes(content)
    bash = str(Path(os.environ.get('PREFIX', '/data/data/com.termux/files/usr')) / 'bin/bash')
    subprocess.run([bash, '-n', str(temp)], check=True)
    temp.replace(target)
    os.execv(bash, [bash, str(target)])


if __name__ == '__main__':
    main()
