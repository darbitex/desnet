# Spark (Like)

`Spark` is the primary positive reaction primitive on DeSNet, equivalent to a "Like".

## On-Chain Signal

A `Spark` is an event-based signal. When a user sparks a post:
1.  An event is emitted with `reaction_kind: SPARK` and `state: ADD`.
2.  The actor's `PidReactionRegistry` is updated to prevent duplicates.

## Un-sparking

To undo a spark, the protocol emits the same event with `state: REMOVE`. Both the addition and removal are recorded in the actor's append-only history.

## Gating

Users must pass the target post's `ReferenceGate` (if any) to spark it.
