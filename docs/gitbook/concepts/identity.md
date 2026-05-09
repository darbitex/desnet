# Identity (PID NFT)

Identity on DeSNet is centered around the **Profile ID (PID)**, which is implemented as an Aptos Object NFT.

## Deterministic Identity

Every PID has a deterministic address derived from the owner's wallet address. This ensures a 1:1 mapping between a wallet and its primary identity on the protocol.

```move
pid_addr = create_object_address(@desnet, bcs(wallet_address))
```

## Capability Hierarchy

DeSNet employs a three-tier authority model to balance security and usability:

1.  **Owner**: The address holding the PID NFT (typically a cold wallet or multisig). Has full control, including the ability to transfer the NFT, rotate the controller, or perform emergency revokes.
2.  **Controller**: A delegated "hot wallet" for daily operations. It can add/remove signers and update profile metadata but cannot transfer the identity itself.
3.  **Signers**: Per-app Ed25519 keys. These keys sign social actions (mints, sparks, etc.) off-chain, which are then submitted to the network.

## Handles

A handle is a human-readable name (e.g., `@alice`) associated with a PID.
- **Constraints**: 1-64 characters, lowercase `a-z`, `0-9`, and hyphens `-`.
- **Pricing**: One-time fee based on length (shorter handles are more expensive).
- **Immutability**: Once registered, a handle is permanently bound to that PID.

| Length | Fee (APT) |
| :--- | :--- |
| 1 char | 100 APT |
| 2 chars | 50 APT |
| 3 chars | 20 APT |
| 4 chars | 10 APT |
| 5 chars | 5 APT |
| 6+ chars | 1 APT |
