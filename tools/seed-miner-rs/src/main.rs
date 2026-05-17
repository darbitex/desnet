// Resource-account seed miner for Aptos/Supra.
//
// Finds a seed string `s` such that
//   sha3_256(BCS(source_addr) || s || 0xFF)
// starts with --prefix and ends with --suffix (both hex, even-length).
//
// Supra resource-account derivation scheme byte = 0xFF (Aptos uses 0xFE — see
// `desnet_supra_experiment.md` memory note).
//
// Hot-loop optimizations:
//   - pre-allocated seed buffer per worker (no per-iter Vec alloc)
//   - in-place hex counter mutation (no format!)
//   - cloneable Sha3_256 init state (`source || seed_base` pre-loaded)
//   - chunk_size = 1 << 22 (~4M attempts) to amortize atomic ops

use clap::Parser;
use rayon::prelude::*;
use sha3::{Digest, Sha3_256};
use std::fs::OpenOptions;
use std::io::Write;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::Instant;

#[derive(Parser)]
#[command(about = "Aptos/Supra resource-account seed miner — sha3-256, prefix+suffix matching, parallel")]
struct Args {
    #[arg(long)]
    source: String,

    #[arg(long, default_value = "")]
    prefix: String,

    #[arg(long, default_value = "")]
    suffix: String,

    #[arg(long, default_value = "desnet-mainnet-v04-")]
    seed_base: String,

    #[arg(long, default_value_t = 3600)]
    max_seconds: u64,

    #[arg(long, default_value = "ff")]
    scheme: String,

    #[arg(long, default_value = "")]
    out: String,

    /// Append progress lines to this file (independent of stdout). Survives SIGPIPE.
    #[arg(long, default_value = "")]
    log: String,
}

fn parse_hex(s: &str) -> Vec<u8> {
    let s = s.strip_prefix("0x").unwrap_or(s);
    hex::decode(s).expect("invalid hex")
}

const HEX_CHARS: &[u8; 16] = b"0123456789abcdef";

fn main() {
    let args = Args::parse();

    let source = parse_hex(&args.source);
    assert_eq!(source.len(), 32, "source addr must be exactly 32 bytes (64 hex)");

    let prefix = parse_hex(&args.prefix);
    let suffix = parse_hex(&args.suffix);
    let scheme = parse_hex(&args.scheme);
    assert_eq!(scheme.len(), 1, "scheme byte must be 1 byte (2 hex)");

    let threads = rayon::current_num_threads();
    let bits = (prefix.len() + suffix.len()) * 8;
    let expected: u64 = 1u64 << bits.min(63);

    println!("seed-miner v2 — sha3-256 resource-account (hot-loop optimized)");
    println!("  source      = 0x{}", hex::encode(&source));
    println!("  prefix      = 0x{} ({} bytes)", hex::encode(&prefix), prefix.len());
    println!("  suffix      = 0x{} ({} bytes)", hex::encode(&suffix), suffix.len());
    println!("  scheme      = 0x{}", hex::encode(&scheme));
    println!("  seed_base   = {}", args.seed_base);
    println!("  threads     = {}", threads);
    println!("  bits        = {}", bits);
    println!("  expected    = ~{} attempts mean", expected);
    println!("  max_seconds = {}", args.max_seconds);
    println!();

    let attempts = AtomicU64::new(0);
    let found = AtomicBool::new(false);
    let result: Mutex<Option<(u64, Vec<u8>, Vec<u8>)>> = Mutex::new(None);
    let start = Instant::now();

    let chunk: u64 = 1 << 22; // ~4M per worker chunk
    let total_chunks: u64 = u64::MAX / chunk;
    let seed_base_bytes = args.seed_base.as_bytes().to_vec();
    let seed_base_len = seed_base_bytes.len();
    let scheme_byte = scheme[0];

    // Pre-build hasher state with source already absorbed.
    // We can clone this state per-iter to avoid re-feeding the 32-byte source.
    let mut base_hasher = Sha3_256::new();
    base_hasher.update(&source);
    let base_hasher_template = base_hasher;

    // Progress reporter (separate thread). Writes to log file directly so it
    // survives a closed stdout pipe (SIGPIPE) from a downstream `grep`.
    let log_path = args.log.clone();
    std::thread::scope(|s| {
        let attempts_ref = &attempts;
        let found_ref = &found;
        let max = args.max_seconds;
        let start_clone = start;
        let log_path_owned = log_path.clone();
        let progress = s.spawn(move || {
            let mut log_file = if !log_path_owned.is_empty() {
                OpenOptions::new()
                    .create(true).append(true).open(&log_path_owned)
                    .ok()
            } else { None };
            let mut last = 0u64;
            let mut last_t = Instant::now();
            loop {
                std::thread::sleep(std::time::Duration::from_secs(5));
                if found_ref.load(Ordering::Relaxed) {
                    return;
                }
                let elapsed = start_clone.elapsed().as_secs();
                if elapsed >= max {
                    return;
                }
                let cur = attempts_ref.load(Ordering::Relaxed);
                let dt = last_t.elapsed().as_secs_f64();
                let dn = cur.saturating_sub(last);
                let rate = if dt > 0.0 { dn as f64 / dt } else { 0.0 };
                let line = format!(
                    "  [{:>4}s] {:>15} attempts ({:>10.0}/s)",
                    elapsed, fmt(cur), rate
                );
                // stdout: ignore broken pipe etc., NEVER panic
                let _ = writeln!(std::io::stdout(), "{}", line);
                let _ = std::io::stdout().flush();
                // log file: independent of stdout
                if let Some(ref mut f) = log_file {
                    let _ = writeln!(f, "{}", line);
                    let _ = f.flush();
                }
                last = cur;
                last_t = Instant::now();
            }
        });

        // Mining workers
        (0..total_chunks).into_par_iter().for_each(|chunk_id| {
            if found.load(Ordering::Relaxed) { return; }
            if start.elapsed().as_secs() >= args.max_seconds {
                found.store(true, Ordering::Relaxed);
                return;
            }
            let chunk_start = match chunk_id.checked_mul(chunk) {
                Some(v) => v,
                None => return,
            };

            // Pre-allocate buffer: [seed_base][16 hex counter bytes][scheme byte]
            let mut buf: Vec<u8> = Vec::with_capacity(seed_base_len + 16 + 1);
            buf.extend_from_slice(&seed_base_bytes);
            // 16-char counter placeholder
            for _ in 0..16 { buf.push(b'0'); }
            buf.push(scheme_byte);
            let counter_offset = seed_base_len;
            let scheme_offset = seed_base_len + 16;

            for offset in 0..chunk {
                if (offset & 0xfffff) == 0 && found.load(Ordering::Relaxed) {
                    return;
                }
                let n: u64 = match chunk_start.checked_add(offset) {
                    Some(v) => v,
                    None => return,
                };
                // Write 16-hex-char counter in-place at counter_offset.
                // u64 is 16 hex chars exactly. Big-endian for human readability.
                for i in 0..16 {
                    let shift = (15 - i) * 4;
                    buf[counter_offset + i] = HEX_CHARS[((n >> shift) & 0xf) as usize];
                }
                // (scheme byte already in place at scheme_offset)

                // Clone the pre-loaded hasher (source already absorbed),
                // feed only seed + scheme.
                let mut hasher = base_hasher_template.clone();
                hasher.update(&buf[..]);
                let digest = hasher.finalize();

                if !prefix.is_empty() && digest[..prefix.len()] != prefix[..] {
                    continue;
                }
                if !suffix.is_empty() {
                    let dl = digest.len();
                    let sl = suffix.len();
                    if digest[dl - sl..] != suffix[..] {
                        continue;
                    }
                }
                // MATCH
                let total_so_far = attempts.fetch_add(offset + 1, Ordering::Relaxed) + offset + 1;
                found.store(true, Ordering::Relaxed);
                let seed_only = buf[..scheme_offset].to_vec();
                let mut r = result.lock().unwrap();
                *r = Some((total_so_far, seed_only, digest.to_vec()));
                return;
            }
            attempts.fetch_add(chunk, Ordering::Relaxed);
        });
        found.store(true, Ordering::Relaxed);
        progress.join().ok();
    });

    let elapsed = start.elapsed().as_secs_f64();
    let r = result.lock().unwrap();
    match r.as_ref() {
        Some((n, seed, digest)) => {
            let addr_hex = hex::encode(digest);
            let seed_utf8 = std::str::from_utf8(seed).unwrap_or("<non-utf8>");
            let seed_hex = hex::encode(seed);
            println!();
            println!("FOUND after {} attempts in {:.1}s ({:.0}/s)",
                fmt(*n), elapsed, *n as f64 / elapsed);
            println!("seed_utf8 = {}", seed_utf8);
            println!("seed_hex  = 0x{}", seed_hex);
            println!("@desnet   = 0x{}", addr_hex);

            if !args.out.is_empty() {
                let out = format!(
                    "source      = 0x{}\nseed_utf8   = {}\nseed_hex    = 0x{}\naddress     = 0x{}\nprefix      = 0x{}\nsuffix      = 0x{}\nscheme      = 0x{}\nattempts    = {}\nelapsed     = {:.1}s\n",
                    hex::encode(&source), seed_utf8, seed_hex, addr_hex,
                    hex::encode(&prefix), hex::encode(&suffix), hex::encode(&scheme),
                    fmt(*n), elapsed,
                );
                let tmp = format!("{}.tmp", args.out);
                std::fs::write(&tmp, &out).expect("write tmp failed");
                std::fs::rename(&tmp, &args.out).expect("atomic rename failed");
                println!("Saved -> {}", args.out);
            }
        }
        None => {
            println!();
            println!("NO MATCH within {} seconds ({} attempts at {:.0}/s)",
                args.max_seconds, fmt(attempts.load(Ordering::Relaxed)),
                attempts.load(Ordering::Relaxed) as f64 / elapsed);
            std::process::exit(2);
        }
    }
}

fn fmt(n: u64) -> String {
    let s = n.to_string();
    let mut out = String::new();
    for (i, c) in s.chars().rev().enumerate() {
        if i > 0 && i % 3 == 0 {
            out.insert(0, ',');
        }
        out.insert(0, c);
    }
    out
}
