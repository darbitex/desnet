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

MAX_CHUNK_BYTES = 32_000
PAYLOAD_JSON = '/tmp/desnet-publish-payload.json'


def run(cmd, **kw):
    print(f"$ {' '.join(cmd)}")
    return subprocess.run(cmd, check=True, **kw)


def build_payload():
    """Compile + serialize desnet pkg into a publish-payload JSON."""
    print('==[ build-publish-payload ]==')
    run([
        'supra', 'move', 'tool', 'build-publish-payload',
        '--package-dir', DESNET_PKG_DIR,
        '--named-addresses', NAMED_ADDR,
        '--json-output-file', PAYLOAD_JSON,
        '--included-artifacts', 'none',
        '--skip-fetch-latest-git-deps',
    ])
    return json.load(open(PAYLOAD_JSON))


def hex_to_bytes(s: str) -> bytes:
    s = s[2:] if s.startswith('0x') else s
    return bytes.fromhex(s)


def slice_into_chunks(metadata: bytes, modules: list[bytes]) -> list[tuple[bytes, list[int], list[bytes]]]:
    """Returns a list of (metadata_chunk, code_indices, code_chunks) tuples.

    metadata is sliced first (chunked alone). Then each module's bytecode is
    sliced and paired with its module index. The LAST tuple in the list will
    be passed to publish_chunked (which performs the actual publish).
    """
    chunks: list[tuple[bytes, list[int], list[bytes]]] = []

    # Metadata chunks (paired with empty code segments).
    if len(metadata) <= MAX_CHUNK_BYTES:
        chunks.append((metadata, [], []))
    else:
        for i in range(0, len(metadata), MAX_CHUNK_BYTES):
            chunks.append((metadata[i:i + MAX_CHUNK_BYTES], [], []))

    # Module bytecode chunks.
    for mod_idx, code in enumerate(modules):
        for i in range(0, len(code), MAX_CHUNK_BYTES):
            piece = code[i:i + MAX_CHUNK_BYTES]
            # Pack each module-bytecode segment as its own chunk.
            chunks.append((b'', [mod_idx], [piece]))

    return chunks


def submit_chunk(fn_name: str, metadata: bytes, indices: list[int], code: list[bytes]):
    """Call publisher::stage_chunk or publisher::publish_chunked."""
    # supra CLI run args use JSON-array literals for vectors. hex: prefix for bytes.
    args = [
        f'hex:{metadata.hex()}',
        f'"u16:[{",".join(str(i) for i in indices)}]"',
        f'"hex:[{",".join(c.hex() for c in code)}]"',
    ]
    # We need to be careful with shell quoting. Use subprocess with list (no shell).
    cmd = [
        'supra', 'move', 'tool', 'run',
        '--function-id', f'{ORIGIN}::publisher::{fn_name}',
        '--args',
        f'hex:{metadata.hex()}',
        f'u16:[{",".join(str(i) for i in indices)}]',
        f'hex:[{",".join(c.hex() for c in code)}]',
        '--private-key', PRIVKEY,
        '--sender-account', ORIGIN,
        '--url', RPC_URL,
        '--max-gas', MAX_GAS_PUB if fn_name == 'publish_chunked' else MAX_GAS_ENTRY,
        '--gas-unit-price', GAS_PRICE,
        '--assume-yes',
    ]
    print(f"$ supra ... run {fn_name}  meta_bytes={len(metadata)} code_bytes={sum(len(c) for c in code)} mod_idx={indices}")
    subprocess.run(cmd, check=True)


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
        submit_chunk(fn, md, idx, cd)

    print('\n==[ chunked publish DONE ]==')
    print(f'Verify with: supra move account balance --account-address {DESNET}')


if __name__ == '__main__':
    main()
