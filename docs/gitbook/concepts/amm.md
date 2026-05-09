# AMM Pools

DeSNet features a purpose-built, constant-product AMM (Automated Market Maker) for every profile token, paired against APT.

## Protocol-Native Liquidity

Each `$TOKEN` is paired with APT in its own pool. The pool is created atomically during handle registration with a seed of **5 APT** and **50M $TOKEN**.

- **Pool Address**: Deterministically derived from the handle.
- **Algorithm**: Constant Product ($x * y = k$).

## Fees & Incentives

- **Trading Fee**: 10 basis points (0.10%).
- **Protocol Cut**: 0%. 100% of the trading fees go to the Liquidity Providers (LPs).
- **Flash Loans**: Supported with a 10 bps fee, also 100% to LPs.

## Composability

The AMM is designed to be "shape-compatible" with major Aptos DEXs (like Darbitex). This allows external aggregators and arbitrage bots to interact with DeSNet liquidity using standard interfaces.

## Safety Features

- **Reentrancy Guard**: Pools are locked during flash loan execution.
- **Two-Phase Settle**: Protocol-level buybacks (from handle fees) use a commit-reveal mechanism to prevent MEV sandwich attacks.
