# ledger-project-2026

A from-scratch database storage system built using **Ada** and **SPARK**.

## Current learning milestone: one crash and one recovered record

The runnable starter uses a temporary one-record WAL/storage demo. The team's
real WAL and storage components are not implemented yet. The original broader
project goals below describe the intended system, not completed features.

From PowerShell in the folder containing `alire.toml`:

```powershell
alr build
alr exec -- powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\crash_recovery.ps1
```

The test writes one record, forcibly kills Ledger after closing the WAL and
before updating storage, restarts Ledger to replay, and checks the recovered
storage against an independent expected value. It prints PASS/FAIL and keeps
evidence in a new `test-output/` subfolder on every run.

Read [the first-test walkthrough](docs/crash-recovery-first-test.md) for the
code explanation, Windows steps, limits, and teammate integration points.
This is a process-crash demonstration, not a power-loss durability guarantee
or a SPARK proof.

## Project Description

This project implements a database storage engine centered around two fundamental concepts: a **write-ahead log (WAL)** and a **B-tree index**.

The write-ahead log records operations before they are applied, providing a foundation for durability and crash recovery. The B-tree provides indexed data storage and retrieval.

A major focus of the project is **crash recovery and formal correctness**. The system will be intentionally interrupted at critical points and repeatedly tested to demonstrate that recovery produces the state required by a stated recovery guarantee.

**SPARK** will be used to specify and verify important correctness properties, including the absence of runtime errors across the parsing and page-management core. Verification results will be reported honestly, including what was not proved and why.

## Required Goals

The project is expected to provide:

- A **write-ahead log (WAL)** with a stated durability guarantee.
- A **B-tree index** built over the log.
- B-tree operations for:
  - Insert
  - Lookup
  - Delete
  - Range scan
- A **crash-injection harness** that can interrupt the engine at every persistent-state transition.
- An **oracle** that verifies recovered data against the expected correct state.
- **SPARK proofs** demonstrating the absence of runtime errors across the parsing and page-management core.
- A **recovery-guarantee document** explaining:
  - What survives a crash.
  - What does not survive a crash.
  - How the recovery guarantee is established.
- A **verification report** documenting the proof results, including properties that could not be proved and why.
  
## Stretch Goals

If the required goals are completed, additional work may include:

- Concurrent readers alongside a single writer.
- Checkpointing to bound recovery time.
- Measuring recovery time against log length.
- Documenting a significant SPARK proof obligation that initially failed and explaining what was changed to satisfy it.
- Additional features proposed by the team.

## Technologies

- **Ada** — Primary programming language
- **SPARK** — Formal specification and verification
- **Alire** — Ada project and dependency management
- **GitHub** — Version control and team collaboration
  
## Project Components

### Write-Ahead Log

Records operations before they are applied and provides the persistence mechanism required for crash recovery.

### B-Tree

Provides indexed storage and retrieval over the log, supporting insertion, lookup, deletion, and range scanning.

### Crash Recovery

Recovers the database after an interruption and verifies that the resulting state satisfies the project's recovery guarantee.

### Crash-Injection Testing

Intentionally interrupts the system at persistent-state transitions to test recovery behavior under failure conditions.

### Formal Verification

Uses SPARK to specify and verify critical properties of the implementation, with verification results documented rather than assumed.

## Team

| Member | Responsibility |
| ------ | -------------- |
| Rene Rodriguez    | Crash Testing & Recovery |
| Ruth Velasquez    | Write-ahead log |
| Andrew Baez    | B-tree / storage engine |
| Annette Garcia    | SPARK / integration |

## Project Structure

```text
src/       Main project source code
tests/     Functional, recovery, and crash-injection tests
docs/      Design, requirements, recovery, and verification documentation
```

## Status

**In Development**

The project is currently in the planning and design phase. Architecture, interfaces, implementation, formal verification, and crash-recovery testing will be developed incrementally throughout the project.
