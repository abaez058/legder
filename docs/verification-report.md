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

**Result:** proved. 57 checks on a clean run, 0 unproved, no
`pragma Annotate` justifications, no contract changes needed. (The
summary says 79 when flow analysis ran first, because it also counts the
flow checks of the other units.)

```sh
alr -n with gnatprove   # once; adds gnatprove to alire.toml locally
alr -n exec -- gnatprove -P legder.gpr --clean
alr -n exec -- gnatprove -P legder.gpr --mode=silver --level=1 -j0 \
  --checks-as-errors=on -u legder.adb -u legder-record_format.adb
```

Run `--clean` first locally if you ran silver on the whole library
before. Otherwise gnatprove keeps the old unproved results of other units
and `--checks-as-errors` fails with no message pointing at target 1. CI
starts from a clean checkout and is not affected.

CI runs this command on every push (step "SPARK proof (target 1 ...)").
`--checks-as-errors=on` makes the job fail if a change introduces a check
the provers cannot discharge.

**What this does not prove:**

- R1 (round trip, `Decode (Encode (R)) = R`). `Encode` and `Decode` have
  no postconditions yet, so nothing functional is claimed. R1 is the
  natural target 2.
- CRC correctness. `CRC` is proved free of runtime errors, not proved to
  compute IEEE 802.3 CRC32. The tests check it against known vectors.
- R3 (a valid block was produced by `Encode`). It depends on CRC
  collisions and is documentation, not a proof obligation.

## Flow analysis, whole library

```sh
alr -n exec -- gnatprove -P legder.gpr --mode=flow --checks-as-errors=on
```

Result: 35 checks, 0 failures (data dependencies, initialization,
termination). Already enforced by CI.

## Silver on the whole library: baseline, not yet a target

```sh
alr -n exec -- gnatprove -P legder.gpr --mode=silver --level=1 -j0
```

Result on 2026-10-14: 240 checks, 194 proved, 46 unproved.

| Unit | Unproved | Kind |
|---|---|---|
| `Legder.Index` (B-tree) | 44 | array index, child pointer range, free count preconditions, two `Insert` postconditions |
| `Legder.RAM_Device` | 2 | `N_Writes + 1` and `N_Syncs + 1` overflow (test counters) |
| `Legder`, `Legder.Record_Format` | 0 | target 1 above |

`Legder.Log` and `Legder.Store` are generic packages. gnatprove analyzes
a generic only through an instance, and the library contains no instance,
so their bodies are not covered by these numbers. Proving them (L1, L2,
L3, S1) needs a SPARK instance over `RAM_Device` as a proof harness.

These are reported, not hidden: they are the reason silver runs only on
target 1 in CI for now. Each unit joins the CI proof step once its count
reaches 0.

## Next targets

1. R1 round trip: postconditions on `Encode`/`Decode` plus a lemma per field.
2. `RAM_Device` counters: bound or saturate `N_Writes`/`N_Syncs`.
3. L1 (scan stops at the first gap) through a proof instance of `Legder.Log`.
