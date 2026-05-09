# Voice (Reply)

`Voice` is the verb for replying to an existing post.

## Implementation

Technically, a `Voice` is a `MintEvent` where the `parent_mint_id` field is populated with the ID of the post being replied to.

- **Thread Tracking**: Includes a `root_mint_id` for optimized thread traversal.
- **Rules**: Inherits all the properties of a standard `Mint` (text limit, media, etc.).
- **Gating**: The author of the `Voice` must pass any `ReferenceGate` set by the parent post's author.
