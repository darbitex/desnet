#!/usr/bin/env python3
"""Convert @origin from EOA -> 1/4 multisig + revoke its auth_key.

Calls `0x1::multisig_account::create_with_existing_account_and_revoke_auth_key`
with params:
  multisig_address           : address                         (= @origin)
  owners                     : vector<address>                 (4 owners)
  num_signatures_required    : u64                             (= 1 initial)
  account_scheme             : u8                              (= 0, Ed25519)
  account_public_key         : vector<u8>                      (= vanity pubkey)
  create_multisig_account_signed_message : vector<u8>          (BCS-encoded auth message)
  metadata_keys              : vector<String>                  (empty)
  metadata_values            : vector<vector<u8>>              (empty)
  timeout_duration           : u64                             (= 0 = no timeout)

Auth message format (MultisigAccountCreationWithAuthKeyRevocationMessage):
  bcs::encode(struct {
    chain_id: u8,            (mainnet = 8)
    account_address: address,
    sequence_number: u64,    (current seq of @origin)
    owners: vector<address>,
    num_signatures_required: u64,
  })
"""
import json
import subprocess
import sys
import hashlib
from pathlib import Path

try:
    import nacl.signing
except ImportError:
    sys.exit('pip install pynacl')


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
PRIVKEY = ENV['VANITY_PRIVKEY']
RPC_URL = ENV['RPC_URL']
GAS_PRICE = ENV['GAS_UNIT_PRICE']
MAX_GAS = ENV['MAX_GAS_ENTRY']
CHAIN_ID = int(ENV['CHAIN_ID'])
OWNERS = json.loads(ENV['MULTISIG_OWNERS_VEC'])
THRESHOLD = int(ENV['THRESHOLD_INITIAL'])


def bcs_encode_address(addr: str) -> bytes:
    h = addr[2:] if addr.startswith('0x') else addr
    return bytes.fromhex(h.zfill(64))


def bcs_encode_u8(v: int) -> bytes:
    return v.to_bytes(1, 'little')


def bcs_encode_u64(v: int) -> bytes:
    return v.to_bytes(8, 'little')


def bcs_encode_uleb128(v: int) -> bytes:
    out = b''
    while v >= 0x80:
        out += bytes([(v & 0x7f) | 0x80])
        v >>= 7
    out += bytes([v])
    return out


def bcs_encode_vec_address(addrs: list[str]) -> bytes:
    out = bcs_encode_uleb128(len(addrs))
    for a in addrs:
        out += bcs_encode_address(a)
    return out


def get_seq_num(addr: str) -> int:
    """Fetch current sequence_number from Supra mainnet for the account."""
    import urllib.request
    url = f'{RPC_URL}/rpc/v3/accounts/{addr}'
    req = urllib.request.Request(url)
    with urllib.request.urlopen(req) as r:
        data = json.loads(r.read())
    return int(data.get('sequence_number', 0))


def derive_pubkey(privkey_hex: str) -> bytes:
    seed = bytes.fromhex(privkey_hex[2:] if privkey_hex.startswith('0x') else privkey_hex)
    sk = nacl.signing.SigningKey(seed)
    return bytes(sk.verify_key)


def build_auth_message(account_addr: str, seq: int, owners: list[str], threshold: int) -> bytes:
    """BCS-encode the MultisigAccountCreationWithAuthKeyRevocationMessage struct."""
    out = b''
    out += bcs_encode_u8(CHAIN_ID)
    out += bcs_encode_address(account_addr)
    out += bcs_encode_u64(seq)
    out += bcs_encode_vec_address(owners)
    out += bcs_encode_u64(threshold)
    return out


def sign_message(privkey_hex: str, message: bytes) -> bytes:
    seed = bytes.fromhex(privkey_hex[2:] if privkey_hex.startswith('0x') else privkey_hex)
    sk = nacl.signing.SigningKey(seed)
    signed = sk.sign(message)
    return bytes(signed.signature)


def main():
    print('==[ 03-convert-to-multisig ]==')
    print(f'@origin       : {ORIGIN}')
    print(f'Owners (4)    :')
    for o in OWNERS:
        print(f'  {o}')
    print(f'Threshold     : {THRESHOLD}/4')
    print()

    pubkey = derive_pubkey(PRIVKEY)
    print(f'Derived pubkey: 0x{pubkey.hex()}')

    seq = get_seq_num(ORIGIN)
    print(f'Current seq#  : {seq}')

    msg = build_auth_message(ORIGIN, seq, OWNERS, THRESHOLD)
    print(f'Auth message  : {len(msg)} bytes BCS')

    sig = sign_message(PRIVKEY, msg)
    print(f'Signature     : 0x{sig.hex()}')

    print('\nReady to submit conversion tx.')
    print('After this succeeds, vanity privkey is BURNED (auth_key=0).')
    print('Future ops require 1/4 multisig (any 1 of 4 owners).')
    ans = input('\nProceed? (y/n) >> ').strip().lower()
    if ans != 'y':
        print('aborted')
        return

    cmd = [
        'supra', 'move', 'tool', 'run',
        '--function-id', '0x1::multisig_account::create_with_existing_account_and_revoke_auth_key',
        '--args',
        f'address:{ORIGIN}',
        'address:[' + ','.join(OWNERS) + ']',
        f'u64:{THRESHOLD}',
        'u8:0',
        f'hex:{pubkey.hex()}',
        f'hex:{sig.hex()}',
        'string:[]',
        'hex:[]',
        'u64:0',
        '--private-key', PRIVKEY,
        '--sender-account', ORIGIN,
        '--rpc-url', RPC_URL,
        '--max-gas', MAX_GAS,
        '--gas-unit-price', GAS_PRICE,
        '--assume-yes',
    ]
    subprocess.run(cmd, check=True)

    print('\n==[ conversion done — vanity privkey BURNED ]==')
    print(f'Verify: supra move tool show --query resource --name 0x1::multisig_account::MultisigAccount --account-address {ORIGIN}')


if __name__ == '__main__':
    main()
