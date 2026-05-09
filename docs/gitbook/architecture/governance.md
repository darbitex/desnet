# Governance & DAO

DeSNet is governed by a decentralized autonomous organization (DAO) that manages the protocol's evolution.

## Voting Power

Voting power is earned, not just bought. It is calculated based on the rewards a user has earned through LP staking.
- **Isolation**: Voting power is isolated per-token.
- **Time-Weighting**: Rewards earned within the last 30 days carry the most weight.

## Upgrade Infrastructure

The protocol supports **Chunked Package Upgrades**. Because the DeSNet package is large, upgrades are staged in chunks before being published atomically.
- **Hash-Pin Verification**: Ensures that the staged chunks match the proposed upgrade.
- **Governance Gated**: Only successful DAO proposals can trigger the final publication of an upgrade.

## Transparency

All social actions and economic changes are recorded in the on-chain `history` module, which maintains a BCS-encoded append-only log for every profile.
