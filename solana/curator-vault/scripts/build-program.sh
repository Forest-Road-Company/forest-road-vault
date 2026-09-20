#!/usr/bin/env bash
set -euo pipefail

# npm and non-interactive CI shells do not necessarily load the user's Rust, AVM or Solana
# profile snippets. Add their conventional install locations without overriding a tool already
# selected earlier in PATH.
export PATH="${PATH}:${HOME}/.avm/bin:${HOME}/.cargo/bin:${HOME}/.local/share/solana/install/active_release/bin"

expected_anchor='anchor-cli 1.2.0'
expected_solana_prefix='solana-cli 4.1.2 '
expected_rust_prefix='rustc 1.98.1 '

actual_anchor="$(anchor --version)"
actual_solana="$(solana --version)"
actual_rust="$(rustc --version)"

[[ "$actual_anchor" == "$expected_anchor" ]] || {
  echo "wrong Anchor CLI: expected '$expected_anchor', got '$actual_anchor'" >&2
  exit 1
}
[[ "$actual_solana" == "$expected_solana_prefix"* ]] || {
  echo "wrong Solana CLI: expected '$expected_solana_prefix...', got '$actual_solana'" >&2
  exit 1
}
[[ "$actual_rust" == "$expected_rust_prefix"* ]] || {
  echo "wrong host Rust: expected '$expected_rust_prefix...', got '$actual_rust'" >&2
  exit 1
}

# These defaults have changed between Anchor releases. Keep both explicit so the same source
# cannot silently move between SBF instruction sets or platform-tools images.
anchor build --ignore-keys --arch v3 --tools-version v1.57
