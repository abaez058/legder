# Legder, Fall 2026 plan

**Team:** 4 students, VCU
**Dates:** October 19 to December 12, 2026
**Working time:** Eight weeks, with a lighter Thanksgiving week (November 23 to 27)
**Seed repository:** https://github.com/GNAT-Academic-Program/legder

## 1. What are we trying to accomplish?

Legder is a small key-value database written in Ada/SPARK. It is intended for embedded systems that need to remember information after a restart: configuration values, counters, device settings, and similar data.

The difficult part is **power loss during a write**.

Imagine these operations:

```text
Put ("motor-speed", "100")
Put ("motor-speed", "120")
Delete ("motor-speed")
```

The database must preserve a consistent state even if the device loses power halfway through an operation. When it starts again, it reads its log and rebuilds the table of current values.

This semester, we are not writing a database from scratch. The seed already contains the main implementation, tests, and a crash simulator. Our job is to understand it, improve it, run it on actual storage, and start proving its behavior with SPARK.

**By December:** we should be able to write data, interrupt an operation, restart, recover, demonstrate which data survived, and explain the guarantees we can establish.

A note on the name: the project is described as a *transactional storage engine*, but this version commits **one record at a time**. It does not support transactions containing several operations. That is outside this semester's scope.

## 2. What is already in the seed?

Read `README.md`, `ARCHITECTURE.md`, and `CONTRIBUTING.md` before making changes.

The main packages are:

| Package | What it does | Status in the seed |
| --- | --- | --- |
| `Legder` | Defines bytes, 512-byte blocks, keys, values, sequence numbers, and CRC32 | Implemented |
| `Legder.Record_Format` | Converts one operation to a 512-byte record and back | Implemented; proof work remains |
| `Legder.Log` | Appends records, synchronizes storage, scans the log on recovery | Implemented; proof work remains |
| `Legder.Store` | Implements `Put`, `Delete`, `Get`, and `Count` | Implemented; lookup is a linear scan |
| `Legder.RAM_Device` | Simulates a block device and supports crash injection | Implemented |
| `tests/` | Exercises the record format, CRC, log, and store | Working baseline; extend it |
| `showcase/` | Demonstrates writes and recovery using the RAM device | RAM-specific; needs a portable demo path |

The records are fixed-size: one database record occupies one **512-byte block**. A key can contain up to 32 bytes and a value up to 256 bytes. The store holds at most **256 live keys**. The seed RAM device contains **256 blocks**, so its log fills after 256 appended records, even if some keys have been deleted or overwritten.

The layers are:

```text
Application
    |
Legder.Store          Put / Delete / Get / Count
    |
Legder.Log            append / Sync / recovery
    |
Legder.Record_Format  records / CRC32
    |
Device                Read / Write / Sync
```

**Ada concept to learn:** `Legder.Store` and `Legder.Log` are **generic packages**. A device is supplied by passing its `Read`, `Write`, and `Sync` procedures when the package is instantiated. There is no device class or runtime dispatch to build. For example, the existing showcase contains:

```ada
package KV is new Legder.Store
  (Dev.Block_Count, Dev.Read, Dev.Write, Dev.Sync);
```

The new file and board devices must satisfy this same interface.

## 3. Understand the write and recovery rules

For a successful `Put`, the intended order is:

```text
Encode record -> Write log block -> Sync -> Update in-memory table
```

The table must **never** change before the log record has been synchronized. Otherwise, the program might report a value that cannot be reconstructed after a crash.

On restart, `Legder.Log.Open` reads records in sequence, starting from block 0. It accepts the next record only if the checksum and record format are valid **and** the sequence number is the expected next number. It stops at the first invalid record or sequence gap. `Legder.Store.Open` then replays that accepted prefix to rebuild the table.

A CRC catches many forms of accidental corruption, including the deliberately damaged blocks in the existing tests. It is not a mathematical guarantee against all corruption: CRC collisions are possible.

### How to read the torn-write test

`Tear_Next_Write` in the RAM device models a power loss in the middle of a block write. Power loss means the program is dead at that moment. So in the showcase and the tests, the `Put` that follows `Tear_Next_Write` must be read as "the process died inside this call". Its `Success` flag is not observable by anyone: nothing after that line, until the store is reopened, is part of the scenario. The only thing the test checks is what `Open` finds afterwards.

Two situations must stay separate in your head:

- **Operation completed successfully:** `Write` and `Sync` returned normally and the device fulfilled its durability contract. Recovery must preserve that operation.
- **Crash before the operation completed:** the operation never returned. Its final record may be absent, damaged, or even fully present. Recovery must produce a consistent valid prefix; a fully written but unacknowledged final operation *may* appear.

The device interface has no error-status parameter. Therefore, a file or hardware `Write`/`Sync` must not return normally while silently violating its guarantee. If a device cannot promise the fault model (one block may be torn, writes before the last `Sync` are durable, writes after it may vanish), a translation layer goes under it; the log's promises do not change.

The seed's showcase and README are being updated by Olivier before week 1 to say this explicitly. You will be told to rebase; the diff is small.

## 4. How we work

We will work in two pairs.

**Pair P, proof and database meaning:** works on `Legder.Record_Format`, `Legder.Log`, and then the S1 model for `Legder.Store`.

**Pair D, devices and lookup:** builds the desktop file device, the board device, and a sorted-array index with binary search.

At each weekly meeting, **each pair reviews the other pair's code diff**. Everyone needs to understand both the storage behavior and the contracts that depend on it. Work in your own fork, as `CONTRIBUTING.md` describes. The seed repository is not the destination for the team's weekly pull requests.

A useful meeting report is short: **what changed, what works, what fails, and what you will do next**. Demonstrate the result rather than describing it from memory.

---

## Week 1, October 19 to 23: Build it, understand it, test it

**Everyone**

1. Fork the seed and get the Alire build, existing tests, showcase, and SPARK flow analysis running. From the repository root:

   ```sh
   alr build
   ```

   ```sh
   cd tests && alr build && ./bin/tests
   ```

   ```sh
   cd showcase && alr build && alr run
   ```

   ```sh
   alr with gnatprove
   alr exec -- gnatprove -P legder.gpr --mode=flow
   ```

   Confirm that CI is green.
2. Read the three project documents and trace one `Put` from `Legder.Store` through `Legder.Log`, `Legder.Record_Format`, and `Legder.RAM_Device`.
3. Each student adds **one distinct test** in `tests/`. Useful cases include an incorrect sequence number after a valid prefix, deleting an absent key, a record with nonzero unused bytes, and a crash scenario at a different point in the write path. A test that follows `Tear_Next_Write` or `Drop_Unsynced` asserts only on what `Open` finds afterwards, never on the `Success` flag of the interrupted call (see section 3).
4. Confirm the two pairs. Pair D should also begin checking which development boards and storage options are available.

**Meeting:** Four test cases, an explanation of the write path, and the pair assignments.

## Week 2, October 26 to 30: Record safety and a desktop file device

**Pair P, R2 and R1 specification**

- Run GNATprove with `alr exec -- gnatprove -P legder.gpr --mode=all`, and concentrate on the obligations in `Legder.Record_Format`.
- Target **R2: buffer index safety**. This means proving that encoding and decoding do not access a byte outside the block. It has nothing to do with the lookup index in `Legder.Store`.
- Examine **R1: round-trip correctness**. The seed describes it as `Decode (Encode (R)) = R`, but that is false as literal record equality: `Encode` copies only the live key bytes, skips the value entirely for a `Delete` record, and `Decode` leaves the padding bytes unspecified. Decide whether to prove equality of the meaningful fields (sequence, kind, key length and live key bytes, and for `Put` the value length and live value bytes) or to require a canonical record representation. Document the decision before trying to prove it.

**Pair D, file device**

- Create `devices/file/` and implement `Read`, `Write`, and `Sync` over a desktop file.
- Return erased-block contents (all `16#FF#`) for unread/uninitialized blocks, and define what happens on short reads and I/O failure.
- Make `Sync` a real persistence operation; flushing only an Ada-side buffer is not enough. Normal return must mean the device met its contract.
- Create a **portable smoke-test program** for normal write/reopen/read. The existing `showcase.adb` calls RAM-only fault-injection procedures, so it cannot be reused unchanged.

**Meeting:** R2 proof output, a clear R1 statement, and write/reopen/read on a file.

## Week 3, November 2 to 6: Round-trip proof and process-crash tests

**Pair P, R1**

Prove the meaningful parts of the record round trip, one field at a time: sequence number, operation kind, key length and live bytes, and (for `Put`) value length and live bytes. Use small supporting lemmas where necessary. If full proof is not finished, list each remaining obligation and explain what is missing.

**Pair D, crash harness and board decision**

- Write a repeatable external script that starts the file-backed program, interrupts it at controlled points in an operation, starts a new process, reopens the file, and checks the recovered state.
- Include interruptions before and after successful `Sync`. A process kill is not identical to physical power loss; document the difference.
- Select the board and persistent medium: **SD over SPI** or **internal flash**. Check the Ada toolchain, driver availability, block/erase behavior, and how `Sync` can be implemented. Order anything missing.

**Meeting:** R1 proof status, a repeatable file-crash demonstration, and a final hardware decision.

## Week 4, November 9 to 13: Recovery proof and board bring-up

**Pair P, L1**

Work on **L1: recovery accepts only the valid consecutive prefix of the log**.

`Legder.Log.Open` already carries two loop invariants, but they are bookkeeping only (`Head = I` and `Recovered = I`). They say nothing about the contents of the blocks. L1 needs a real invariant over the accepted prefix: every block below `Head` decodes as valid, and its sequence number is its position plus one. Writing that invariant so GNATprove accepts it is the week's work.

Pay attention to the relationship between `Open` and `Scan`: `Open` checks validity and sequence numbers; `Scan` replays the prefix identified by `Open`, checks only `Valid`, and assumes storage has not changed in between. State that assumption as a contract or strengthen the checks. Do not claim `Scan` independently checks sequence numbers when it does not.

**Pair D, hardware device**

Bring up the chosen board and implement its `Read`, `Write`, and `Sync` operations. Run the portable database demonstration using real persistent storage. If flash or SD cannot meet the expected write/sync semantics directly, document the necessary translation layer rather than changing the log's promises.

**Meeting:** L1 proof status (or the exact failing obligation) and a write/reopen/read demonstration on hardware.

## Week 5, November 16 to 20: Midpoint demonstration

**Pair P, begin S1, the store model**

A store's logical meaning is just a map from keys to values. For example:

```text
Put (A, 10)     -> {A: 10}
Put (B, 20)     -> {A: 10, B: 20}
Put (A, 30)     -> {A: 30, B: 20}
Delete (B)      -> {A: 30}
```

Build a **separate reference map in the tests** and compare it with the real store after sequences of `Put`, `Delete`, `Get`, and `Open`. It should also check failed operations and recovery cases. This reference implementation is a test oracle, not itself a formal proof.

Then begin declaring `Model (S)` in the `Legder.Store` specification as a **ghost model**: a description for SPARK of the logical contents of the store, rather than the physical array layout. The goal this week is a useful definition, not a complete proof.

**Pair D, sorted lookup index**

Replace the linear scan in `Legder.Store` with a sorted array and binary search.

- Define an ordering for `Legder.Key` that agrees with its existing equality operation (which compares only live key bytes).
- Choose how to keep live entries sorted when keys are inserted, updated, deleted, or reconstructed by `Open`.
- Test empty lookup, first/last key, missing key, insertion between keys, deletion, and a full table.
- Do not alter the `Append -> Sync -> Apply` commit ordering.

**Important test detail:** The seed RAM device has 256 log blocks and the store has 256 table entries. Therefore, filling the RAM device alone does **not** independently establish the table-capacity rule (S3): the log may fill first. Use a larger file-backed device, or a focused table test, to exercise that case separately.

**Midpoint meeting:** Interrupt a write on the board if hardware is ready, restart, and inspect recovery. Present the reference-model test results and indexed lookup tests. Be precise about whether the demonstration shows a process restart, simulated corruption, or a real power cut.

## Week 6, November 23 to 27: Thanksgiving, lighter week

**Whole team**

Write a **1 to 2 page compaction design note**. No implementation.

Compaction would remove obsolete log entries. One possible design uses two regions: keep the old log intact while writing a compacted replacement, then atomically switch which region is authoritative.

Explain what happens if power fails before, during, or after that switch. Explain what information recovery needs to identify the authoritative region and how the recovery scan would change.

Use any remaining time to finish delayed work. The meeting can be early in the week or skipped; submit the design note for review.

## Week 7, November 30 to December 4: Freeze and consolidate

**No new features.**

**Pair P, S1 contracts**

State postconditions against `Model (S)` for successful `Put`, successful `Delete`, and `Open`. For example:

- A successful `Put (K, V)` makes `K` map to `V` and preserves all other keys.
- A successful `Delete (K)` removes that key and preserves all other keys.
- `Open` produces the map obtained by replaying the accepted durable log prefix.
- A refused operation does not change the store's logical contents.

Try to prove what you can. Record unproved obligations and their causes. Do not claim a complete hardware durability proof: the device model (L2/L3) is outside our fall scope.

**Pair D, merge and document**

Merge the file device, hardware work, and lookup index into `main` once tests are passing. Document the board, medium, required tools, how to run each demonstration, and any limitations. Confirm the recovery tests still pass after the index changes.

**Meeting:** Review the proof table and the merged system.

| Property | Status to report |
| --- | --- |
| R2, record buffer safety | Proved, or Partial, or Not attempted |
| R1, record round trip | Proved, or Partial, or Not attempted |
| L1, recovery prefix | Proved, or Partial, or Not attempted |
| S1, store's logical meaning | Proved, or Partial, or Not attempted |

For every partial result, include the exact outstanding obligation. Tests passing is not the same as the obligation being proved.

## Week 8, December 7 to 11: Final delivery

Prepare the final report, clean README, proof summary, and demonstration. Confirm CI is green on `main` and rehearse the complete story:

1. Write and read values on persistent storage.
2. Explain the append, sync, and table-update order.
3. Interrupt an operation and demonstrate recovery.
4. Show the indexed lookup without changing the database's logical behavior.
5. Explain which statements SPARK proved, which were only tested, and which remain unfinished.

**December 12:** Final presentation.

---

## 5. What is out of scope this semester?

- **Compaction implementation:** design note only.
- **B-tree:** a sorted array with binary search is enough.
- **L2/L3:** ghost model of the storage device, including its durability behavior.
- **Multi-operation transactions:** no `Begin`/`Commit`, no atomic group of several `Put`/`Delete` calls.
- **Concurrent writers, wear levelling, and bad-block handling:** not part of this project phase.

If an earlier milestone slips, prioritize the correct write/recovery contract, the file device, and reproducible tests. Do not start an out-of-scope feature to compensate for incomplete core work. Keep the hardware target visible, and document any board blocker rather than hiding it.

## 6. Rules for the repository

1. **Never update the in-memory table before the corresponding log append has synchronized.**
2. **Never weaken a valid contract just to make GNATprove pass.** If a contract is wrong, correct it separately, explain the reason, and discuss it at the meeting.
3. **Keep CI green.** Warnings are errors. Add a test or proof alongside behavior changes.
4. **Keep `src/` in SPARK.** Low-level implementations for non-RAM devices belong under `devices/<name>/`; any needed `SPARK_Mode => Off` boundary stays there.
5. **Keep the work reproducible.** The fork must contain build instructions, dependencies, tests, proof results, and a clear way to run the demonstration.
6. **Be accurate about guarantees.** A process kill is not a power cut. A CRC is not a formal proof. A passing test is not a discharged GNATprove obligation. A successful operation must not be silently lost after recovery under the stated device contract.

## 7. What success looks like in December

A good final result is a small, understandable storage system, not an unfinished large database. We should have:

- A correct and documented durability/crash model, with the torn-write test read the way section 3 describes.
- Record-format safety proofs and clear progress on round-trip correctness.
- A working desktop file device and a demonstrated hardware storage path, with any limitations documented.
- Repeatable crash and recovery tests.
- A sorted lookup index with correct behavior after replay.
- A tested reference map and an initial SPARK ghost model for the store.
- A clear report of what was proved, what was tested, and what remains for the next semester.

The important outcome is that **all four students can explain what survives a crash, why it survives, and which assumptions that claim depends on**.