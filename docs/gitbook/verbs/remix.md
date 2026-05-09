# Remix (Quote)

`Remix` is the verb for quote-posting — sharing another user's post with your own commentary.

## Implementation

A `Remix` is a `MintEvent` where the `quote_mint_id` field is populated.

- **Non-recursive**: A post cannot have both a `parent_mint_id` and a `quote_mint_id`. It is either a reply or a quote.
- **Engagement**: Like other verbs, it is written to the actor's history and creates a social link to the target author.
