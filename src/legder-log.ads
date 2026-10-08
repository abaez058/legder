--  The write-ahead log: a sequence of records in consecutive blocks.
--
--  Block 0 .. Block_Count hold records. The log is append-only and
--  wraps never in v1 (when full, Append fails). Compaction is a
--  milestone.
--
--  Commit protocol, and why it is crash-safe:
--    1. Encode the record with Seq = Last_Seq + 1.
--    2. Write it to block Head.
--    3. Sync.
--    4. Head := Head + 1, Last_Seq := Seq.
--  A crash before 3 leaves block Head either untouched (stale data or
--  erased) or torn. In every case Decode says Valid = False, or Valid
--  with a Seq that is not Last_Seq + 1. Scan stops there. So the log
--  observed after recovery is exactly the committed prefix.
--
--  PROOF TARGET
--    L1  Scan visits blocks 0 .. N in order and stops at the first
--        block that is not Valid with Seq = previous + 1.
--    L2  After Append succeeds and Sync returns, Scan finds the new
--        record as the last one (needs a device model; see tests).
--    L3  Append never writes a block other than Head.

with Legder.Record_Format; use Legder.Record_Format;

generic
   Block_Count : Block_Index;
   with procedure Read  (Index : Block_Index; Data : out Block);
   with procedure Write (Index : Block_Index; Data : Block);
   with procedure Sync;
package Legder.Log with SPARK_Mode is

   subtype Position is Natural range 0 .. Max_Blocks;
   --  Head is the next block to write. Head > Block_Count means the
   --  log is full.

   type State is record
      Head     : Position := 0;
      Last_Seq : Sequence := 0;
      Opened   : Boolean  := False;
   end record;

   function Is_Full (S : State) return Boolean is
     (S.Head > Natural (Block_Count));

   procedure Open (S : out State; Recovered : out Natural)
     with Post => S.Opened;
   --  Scans from block 0, stops at the first gap, sets Head and
   --  Last_Seq. Recovered is how many valid records were found. The
   --  store replays them through Scan.

   procedure Append (S : in out State; Kind : Op_Kind; K : Key; V : Value; Success : out Boolean)
     with Pre  => S.Opened,
          Post => S.Opened
                  and then (if Success then S.Head = S.Head'Old + 1
                                          and then S.Last_Seq = S.Last_Seq'Old + 1
                            else S.Head = S.Head'Old
                                 and then S.Last_Seq = S.Last_Seq'Old);
   --  Commits one record. Success = False only when the log is full.
   --  On return with Success the record is durable (Sync was called).

   generic
      with procedure Visit (R : Log_Record);
   procedure Scan (S : State)
     with Pre => S.Opened;
   --  Calls Visit for each committed record, in order, from block 0
   --  to Head - 1. Used by Open (to count) and by the store (to replay).

end Legder.Log;
