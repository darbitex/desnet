#!/usr/bin/env python3
"""Chunked publish of the desnet pkg to @desnet via @origin's publisher.

Flow:
  1. `supra move tool build-publish-payload` produces a JSON file containing
     `metadata_serialized` (hex) + `code` (list of hex strings, one per module).
  2. Slice metadata + each module's bytecode into chunks of MAX_CHUNK_BYTES.
  3. Call `publisher::stage_chunk` for every chunk except the last.
  4. Call `publisher::publish_chunked` for the last chunk — this triggers the
     actual `code::publish_package_txn` AT @desnet.

The publisher expects:
  metadata_chunk : vector<u8>
  code_indices   : vector<u16>   (which module each chunk belongs to)
  code_chunks    : vector<vector<u8>>  (paired with code_indices)

Per supra v0.5.0 tx size limit, MAX_CHUNK_BYTES ~ 32_000 leaves headroom for
BCS framing + signature. Adjust if a tx aborts with "too large".

Run from the scripts/mainnet-deploy/ directory:
    python3 02-publish-desnet-chunked.py
"""
import json
import os
import subprocess
import sys
from pathlib import Path

# Pull env vars from _env.sh by running it under bash.
def load_env():
    out = subprocess.check_output(
        ['bash', '-c', f'source {Path(__file__).parent / "_env.sh"} && env']
    ).decode()
    env = {}
    for line in out.splitlines():
        if '=' in line:
            k, v = line.split('=', 1)
            env[k] = v
    return env

ENV = load_env()
ORIGIN = ENV['ORIGIN_ADDR']
DESNET = ENV['DESNET_ADDR']
PRIVKEY = ENV['VANITY_PRIVKEY']
RPC_URL = ENV['RPC_URL']
GAS_PRICE = ENV['GAS_UNIT_PRICE']
MAX_GAS_PUB = ENV['MAX_GAS_PUBLISH']
MAX_GAS_ENTRY = ENV['MAX_GAS_ENTRY']
DESNET_PKG_DIR = ENV['DESNET_PKG_DIR']
NAMED_ADDR = ENV['NAMED_ADDRESSES']
SCRIPT_DIR = str(Path(__file__).parent.resolve())
SUPRA_PTY = f'{SCRIPT_DIR}/supra-pty.py'
# Password for the smr profile that lives in DESNET_PKG_DIR. supra CLI v0.5.0
# pre-flight-loads this profile EVEN when --private-key is supplied; with
# stdin closed this fails with ENXIO. supra-pty.py feeds the password.
SUPRA_PASSWORD = os.environ.get(
    'SUPRA_PASSWORD',
    'DesnetMainnetDeploy2026!StrongPasswordForLocalCliOnly',
)

# Per-tx code payload budget. Matches the testnet-proven chunker_testnet.py:
# bin-pack COMPLETE modules (never split one), 50KB target leaves headroom
# under Supra's 64KB tx serialization limit after BCS overhead + signature.
MAX_CHUNK_BYTES = 50_000
PAYLOAD_JSON = '/tmp/desnet-publish-payload.json'


def run(cmd, **kw):
    print(f"$ {' '.join(cmd)}")
    # Detach subprocess stdin so it cannot consume our pipe-fed `y` answer.
    kw.setdefault('stdin', subprocess.DEVNULL)
    return subprocess.run(cmd, check=True, **kw)


def build_payload():
    """Compile + serialize desnet pkg into a publish-payload JSON."""
    print('==[ build-publish-payload ]==')
    # Pre-delete stale payload so the CLI never prompts "overwrite? [y/n]".
    try:
        os.remove(PAYLOAD_JSON)
    except FileNotFoundError:
        pass
    run([
        'supra', 'move', 'tool', 'build-publish-payload',
        '--package-dir', DESNET_PKG_DIR,
        '--named-addresses', NAMED_ADDR,
        '--json-output-file', PAYLOAD_JSON,
        '--included-artifacts', 'none',
        '--skip-fetch-latest-git-deps',
        '--override-size-check',
    ])
    return json.load(open(PAYLOAD_JSON))


def hex_to_bytes(s: str) -> bytes:
    s = s[2:] if s.startswith('0x') else s
    return bytes.fromhex(s)


def slice_into_chunks(metadata: bytes, modules: list[bytes]) -> list[tuple[bytes, list[int], list[bytes]]]:
    """Returns a list of (metadata_chunk, code_indices, code_chunks) tuples.

    Mirrors testnet's proven chunker (.deploy/chunker_testnet.py): bin-pack
    complete modules in order, never split a module across chunks. Metadata
    rides in the first chunk only (empty bytes for subsequent chunks). The
    last tuple in the returned list is fed to publish_chunked.
    """
    chunks: list[tuple[bytes, list[int], list[bytes]]] = []
    cur_idx: list[int] = []
    cur_code: list[bytes] = []
    cur_size = 0

    for mod_idx, code in enumerate(modules):
        if cur_size + len(code) > MAX_CHUNK_BYTES and cur_idx:
            chunks.append((b'', cur_idx, cur_code))
            cur_idx, cur_code, cur_size = [], [], 0
        cur_idx.append(mod_idx)
        cur_code.append(code)
        cur_size += len(code)
    if cur_idx:
        chunks.append((b'', cur_idx, cur_code))

    # Metadata rides in the FIRST chunk only.
    md, idx, cd = chunks[0]
    chunks[0] = (metadata, idx, cd)
    return chunks


def submit_chunk(fn_name: str, metadata: bytes, indices: list[int], code: list[bytes], chunk_idx: int):
    """Call publisher::stage_chunk or publisher::publish_chunked via --json-file.

    The supra CLI's --args parser does not accept the `hex:[h1,h2,...]` array
    shorthand for vector<vector<u8>>, so we serialize the call as a JSON file
    matching the format produced by build-publish-payload.
    """
    # NOTE: u16 vector values must be strings per the proven testnet chunker
    # (.deploy/chunker_testnet.py line 66). Integers cause supra CLI to reject.
    # NOTE: hex values get a "0x" prefix to mirror the canonical format from
    # build-publish-payload (empty metadata for non-first chunks = "0x").
    payload = {
        "function_id": f"{ORIGIN}::publisher::{fn_name}",
        "type_args": [],
        "args": [
            {"type": "hex", "value": ("0x" + metadata.hex()) if metadata else "0x"},
            {"type": "u16", "value": [str(i) for i in indices]},
            {"type": "hex", "value": ["0x" + c.hex() for c in code]},
        ],
    }
    json_path = f'/tmp/desnet-chunk-{chunk_idx}.json'
    with open(json_path, 'w') as f:
        json.dump(payload, f)
    cmd = [
        'python3', SUPRA_PTY,
        'move', 'tool', 'run',
        '--json-file', json_path,
        '--private-key', PRIVKEY,
        '--sender-account', ORIGIN,
        '--url', RPC_URL,
        '--max-gas', MAX_GAS_PUB if fn_name == 'publish_chunked' else MAX_GAS_ENTRY,
        '--gas-unit-price', GAS_PRICE,
        '--assume-yes',
    ]
    print(f"$ supra ... run {fn_name} (json={json_path})  meta_bytes={len(metadata)} code_bytes={sum(len(c) for c in code)} mod_idx={indices}")
    # supra CLI v0.5.0 'move tool run' pre-flight-loads the smr profile from
    # CWD even when --private-key is supplied; with stdin closed it fails on
    # the password prompt. Invoke via supra-pty.py which forks a pty and feeds
    # SUPRA_PASSWORD. cwd=DESNET_PKG_DIR so the smr files are visible.
    env = {**os.environ, 'SUPRA_PASSWORD': SUPRA_PASSWORD}
    subprocess.run(cmd, check=True, cwd=DESNET_PKG_DIR, env=env)


def main():
    payload = build_payload()
    meta_hex = payload.get('args', [{}])[0].get('value') or payload.get('metadata_serialized')
    code_list = payload.get('args', [{}, {}])[1].get('value') or payload.get('code')

    if not meta_hex or not code_list:
        print('ERROR: could not extract metadata + code from payload JSON.')
        print('Payload keys:', list(payload.keys()))
        print('Inspect /tmp/desnet-publish-payload.json manually.')
        sys.exit(1)

    metadata = hex_to_bytes(meta_hex)
    modules = [hex_to_bytes(c) for c in code_list]

    print(f'metadata: {len(metadata)} bytes')
    for i, m in enumerate(modules):
        print(f'  module[{i}]: {len(m)} bytes')

    chunks = slice_into_chunks(metadata, modules)
    n = len(chunks)
    print(f'\nTotal chunks: {n} (max chunk = {MAX_CHUNK_BYTES} bytes)')
    print('Plan:')
    for i, (md, idx, cd) in enumerate(chunks):
        kind = 'publish_chunked' if i == n - 1 else 'stage_chunk'
        print(f'  [{i+1}/{n}] {kind}  meta={len(md)}B code={sum(len(c) for c in cd)}B mods={idx}')

    print()
    ans = input('Proceed? (y/n) >> ').strip().lower()
    if ans != 'y':
        print('aborted')
        return

    for i, (md, idx, cd) in enumerate(chunks):
        fn = 'publish_chunked' if i == n - 1 else 'stage_chunk'
        print(f'\n==[ chunk {i+1}/{n}: {fn} ]==')
        submit_chunk(fn, md, idx, cd, i + 1)

    print('\n==[ chunked publish DONE ]==')
    print(f'Verify with: supra move account balance --account-address {DESNET}')


if __name__ == '__main__':
    main()
