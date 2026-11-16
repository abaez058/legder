# ledger-project-2026

A from-scratch database storage system built using **Ada** and **SPARK**.

## WAL process-restart check

The Ada WAL and bounded store are implemented. `Legder.File_Device` stores
fixed-size blocks in a binary file, while `Legder.RAM_Device` remains the
fault-injection device used by the unit tests.

From PowerShell at the repository root, run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\crash_recovery.ps1
```

The script builds the showcase with Alire, starts one process to append and
sync a key/value record, then starts a second process to reopen the file-backed
WAL and verify that replay recovered the value. The temporary WAL file is
removed after the check. The test verifies process-restart persistence; it is
not a sudden-power-loss durability guarantee or a SPARK proof of file I/O.

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

The WAL, record format, bounded store, RAM fault-injection device, and unit
tests are implemented. The file device and process-restart showcase cover
host-file persistence. Compaction, physical-device durability guarantees,
and complete SPARK proofs remain future work.
