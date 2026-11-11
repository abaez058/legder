# R1 decision: what "round trip" means for a record

Status: **proposed** by Annette Garcia (Pair P), to confirm at the weekly
meeting before the R1 proof starts.

## The problem

`legder-record_format.ads` states R1 as `Decode (Encode (R)) = R`. Taken
literally, that is false, and a proof of it would fail:

1. **Delete records drop the value.** `Encode` never writes value bytes
   for a `Delete`, and `Decode` returns `V.Length = 0`. So
   `(Seq => 1, Kind => Delete, K => "gone", V => "ignored")` comes back
   with an empty value. The existing test "delete carries no value"
   already shows this.
2. **Padding is not carried.** `Encode` copies only the live key and
   value bytes. `Decode` starts from a default record, so every padding
   byte comes back as zero, whatever the caller had there. `Value` has
   no equality of its own, so `=` on `Log_Record` compares all 256 value
   bytes, padding included.
3. **Decode does not check unused bytes.** A block with nonzero key
   padding, value padding or reserved bytes (304 .. 507) and a correct
   CRC decodes as `Valid`. On disk, then, there is no single canonical
   form that `Decode` enforces.

## The two options from the plan

**A. Meaningful fields.** Prove that the fields that carry meaning come
back unchanged. Leave padding and the value of a `Delete` unspecified.

**B. Canonical representation.** Require every record (and every block)
to have zero padding: a precondition on `Encode`, and a `Decode` that
rejects nonzero unused bytes.

## Decision: option A

R1 is stated as: for every record `R`, after `Encode (R, B)` and
`Decode (B, D, Valid)`:

| # | Field | Required |
|---|---|---|
| R1.1 | validity | `Valid` |
| R1.2 | sequence | `D.Seq = R.Seq` |
| R1.3 | kind | `D.Kind = R.Kind` |
| R1.4 | key length | `D.K.Length = R.K.Length` |
| R1.5 | key bytes | `D.K.Bytes (I) = R.K.Bytes (I)` for `I in 1 .. R.K.Length` |
| R1.6 | value length, Put only | `D.V.Length = R.V.Length` |
| R1.7 | value bytes, Put only | `D.V.Bytes (I) = R.V.Bytes (I)` for `I in 1 .. R.V.Length` |

R1.4 and R1.5 together are the existing `"="` on `Key`. R1.6 and R1.7
together are the existing `Same` on `Value`. The proof will go through
a ghost function, roughly:

```ada
function Same_Record (L, R : Log_Record) return Boolean is
  (L.Seq = R.Seq and then L.Kind = R.Kind and then L.K = R.K
   and then (if L.Kind = Put then Same (L.V, R.V)))
with Ghost;
```

## Why A and not B

- **The store already works this way.** Keys compare on live bytes
  only, and `Same` ignores value padding. Nothing above the record
  format reads padding, so A proves what the rest of the system relies
  on.
- **B changes recovery behaviour.** A stricter `Decode` would reject
  blocks that are accepted today. That is a change to which log prefix
  `Open` recovers. It would need its own discussion and its own tests,
  and the plan says not to change contracts just to make a proof go
  through.
- **B adds a precondition on every caller.** `Legder.Log` and
  `Legder.Store` would then have to prove that they never hand `Encode`
  a record with dirty padding.
- **A is smaller.** It can be proved one field at a time, which is the
  week 3 plan.

## What A does not claim

- Nothing about padding or reserved bytes after `Decode`.
- Nothing about the value of a `Delete` record.
- Nothing about blocks that were not produced by `Encode`. A block with
  nonzero padding and a correct CRC decodes as `Valid`. Such a block can
  only come from another writer or a CRC collision (R3, which is
  documentation, not a proof).

## Side note for the team (no change made)

For a `Delete`, `Encode` still writes `R.V.Length` into the value length
bytes (offsets 14 and 15), although the value is ignored. Two `Delete`
records that differ only in their ignored value give different blocks.
That is harmless under option A. Writing 0 there would make `Delete`
encoding deterministic, but it is a code change and belongs in its own
pull request.

## How the proof will be built

1. A postcondition on `Encode`: each meaningful field sits at its
   offset in `B`, the magic is right, and the CRC field equals
   `CRC (B (0 .. 507))`.
2. A postcondition on `Decode`: `Valid` is true exactly when magic,
   kind, lengths and CRC check out, and when it is true each meaningful
   field of `D` equals the bytes at its offset.
3. R1 follows by composing 1 and 2, one field at a time (R1.1 to
   R1.7). Small lemmas cover the little-endian `Put_U64`/`Get_U64` and
   `Put_U32`/`Get_U32` pairs.

## Tests that pin this behaviour

`Test_Record_Unused_Bytes` in `tests/src/tests.adb`:

- Nonzero key padding, value padding and reserved bytes with a correct
  CRC still decode, and the meaningful fields are unchanged.
- A damaged reserved byte without a correct CRC is rejected.
- `Encode` output does not depend on key padding.
- A `Delete` block with a nonzero stored value length decodes with an
  empty value.
