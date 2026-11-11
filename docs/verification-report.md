# Verification report

Status of SPARK verification for legder. Every claim here comes from a
`gnatprove` run; the command is next to each result so anyone can rerun it.

Toolchain: GNAT 16.1.0, gnatprove 16.1.0 (Why3 1.8.2, Alt-Ergo 2.6.1,
CVC5, Z3), all through Alire.

## Target 1: R2, the record format never reads or writes outside a block

**Scope:** `Legder` (`CRC`, key `"<"`) and `Legder.Record_Format`
(`Encode`, `Decode` and the `Put_U32`, `Get_U32`, `Put_U64`, `Get_U64`
helpers). This is the parsing core: every byte that comes back from the
device after a crash goes through `Decode`, so a runtime error here would
turn a torn block into a crash during recovery.

**Property:** absence of runtime errors (SPARK "silver"). Every array
index, range conversion and arithmetic operation in these units is proved
in bounds for every possible input, including a block of random bytes
handed to `Decode`. This is R2 in the proof plan of `ARCHITECTURE.md`.

**Result:** proved. 58 checks on a clean run, 0 unproved, no
`pragma Annotate` justifications, no contract changes. (The summary says
80 when flow analysis ran first, because it also counts the flow checks
of the other units.) Proved on macOS, Windows and Linux in CI.

One `pragma Assert` in `Decode` states that the key and value lengths are
in range after the early returns. It adds a fact the code already checks;
it does not weaken anything, and it is itself proved.

```sh
alr -n with gnatprove   # once; adds gnatprove to alire.toml locally
alr -n exec -- gnatprove -P legder.gpr --clean
alr -n exec -- gnatprove -P legder.gpr --mode=silver \
  --checks-as-errors=on -u legder.adb -u legder-record_format.adb
```

**Same answer on every machine.** `legder.gpr` sets the prover limits
(`--level=1 --timeout=0 --steps=2000`). Provers stop after a number of
steps, not seconds, so a slow Windows runner and a fast Mac reach the
same verdict. With the default one second limit, an early Windows CI run
reported unproved checks in `Decode` that proved everywhere else.

Run `--clean` first locally if you ran silver on the whole library
before. Otherwise gnatprove keeps the old unproved results of other units
and `--checks-as-errors` fails with no message pointing at target 1. CI
starts from a clean checkout and is not affected.

CI runs this command on every push (step "SPARK proof (target 1 ...)").
`--checks-as-errors=on` makes the job fail if a change introduces a check
the provers cannot discharge.

**What this does not prove:**

- R1 (round trip). That is target 2 below.
- CRC correctness. `CRC` is proved free of runtime errors, not proved to
  compute IEEE 802.3 CRC32. The tests check it against known vectors.
- R3 (a valid block was produced by `Encode`). It depends on CRC
  collisions and is documentation, not a proof obligation.

## Target 2: R1, a record survives Encode then Decode

**Scope:** `Legder.Record_Format`: `Encode`, `Decode`, the four byte
helpers, and the ghost procedure `Round_Trip`.

**Property:** for every record `R`, `Encode` then `Decode` returns
`Valid` and the same meaningful fields. This is R1 as decided in
`docs/r1-round-trip-decision.md` (option A, meaningful fields, not
literal record equality). Each field is a separate `pragma Assert` in
`Round_Trip`, so gnatprove reports them one at a time:

| Field | Statement | Status |
|---|---|---|
| R1.1 | `Valid` | Proved |
| R1.2 | `D.Seq = R.Seq` | Proved |
| R1.3 | `D.Kind = R.Kind` | Proved |
| R1.4 | `D.K.Length = R.K.Length` | Proved |
| R1.5 | live key bytes equal | Proved |
| R1.6 | for `Put`, `D.V.Length = R.V.Length` | Proved |
| R1.7 | for `Put`, live value bytes equal | Proved |

**How:** `Encode` and `Decode` now carry postconditions over a ghost
view of the block (`U32_At`, `U64_At`, `Well_Formed`, `Fields_Match` in
the spec). `Encode` promises `Well_Formed (B)` and that each meaningful
field sits at its offset. `Decode` promises `Valid = Well_Formed (B)`
and, when valid, that each field it returns is the one at its offset.
R1 follows by putting the two together. The byte helpers prove that
`Get_U64` reads back what `Put_U64` wrote (same for 32 bits) and that
they leave every other byte alone.

A side result: the `Decode` postcondition fully states when a block is
accepted (magic, kind, both lengths, CRC). Before, that was only a
comment.

**Result:** proved. 137 checks on a clean run of the target 1 command
above (it covers both targets), 0 unproved, no `pragma Assume` or
`pragma Annotate`, no contract weakened. As a sanity check, changing the
R1.2 assertion to `D.Seq = R.Seq + 1` makes gnatprove fail.

**What this does not prove:** anything about padding, reserved bytes,
or the value of a `Delete` after `Decode` (left unspecified on purpose,
see the decision note); anything about blocks not written by `Encode`
(R3).

## Flow analysis, whole library

```sh
alr -n exec -- gnatprove -P legder.gpr --mode=flow --checks-as-errors=on
```

Result: 35 checks, 0 failures (data dependencies, initialization,
termination). Already enforced by CI.

## Silver on the whole library: baseline, not yet a target

```sh
alr -n exec -- gnatprove -P legder.gpr --mode=silver
```

Result on 2026-10-15: 241 checks, 195 proved, 46 unproved.

| Unit | Unproved | Kind |
|---|---|---|
| `Legder.Index` (B-tree) | 44 | array index, child pointer range, free count preconditions, two `Insert` postconditions |
| `Legder.RAM_Device` | 2 | `N_Writes + 1` and `N_Syncs + 1` overflow (test counters) |
| `Legder`, `Legder.Record_Format` | 0 | targets 1 and 2 above |

`Legder.Log` and `Legder.Store` are generic packages. gnatprove analyzes
a generic only through an instance, and the library contains no instance,
so their bodies are not covered by these numbers. Proving them (L1, L2,
L3, S1) needs a SPARK instance over `RAM_Device` as a proof harness.

These are reported, not hidden: they are the reason silver runs only on
target 1 in CI for now. Each unit joins the CI proof step once its count
reaches 0.

## Next targets

1. L1 (scan stops at the first gap) through a proof instance of `Legder.Log`.
   The `Decode` postcondition from target 2 gives L1 a precise meaning
   for "valid block".
2. `RAM_Device` counters: bound or saturate `N_Writes`/`N_Syncs`.
