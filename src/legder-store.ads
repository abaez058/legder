--  The store: a bounded key-value map, durable through Legder.Log.
--
--  This is what applications use. Put and Delete commit to the log
--  before they touch the in-memory table, so the table is always a
--  replay of the log. Open replays the log to rebuild the table.
--
--  The in-memory table is a Legder.Index (sorted array + binary
--  search) plus a slab of values indexed by the slot the index hands
--  out. The index is the part to swap for a B-tree; the commit order
--  below does not change when it is swapped.
--
--  PROOF TARGET (the whole point of the project)
--    S1  After Open, for every key K: Get (K) is the value of the last
--        Put (K) in the committed log, or absent if the last operation
--        on K was Delete or there was none.
--    S2  Put/Delete change the table only after Append returned
--        Success, so a crash at any point leaves the table rebuilt by
--        Open equal to what the log says (S1 applied to the prefix).
--    S3  Capacity: the table never overflows; Put on a full table with
--        a new key fails before writing to the log.
--  S1 is the target for the year. State it as a ghost model (a
--  functional map) and prove Put, Delete and Open against it.

with Legder.Index;
with Legder.Log;

generic
   Block_Count : Block_Index;
   with procedure Read  (Index : Block_Index; Data : out Block);
   with procedure Write (Index : Block_Index; Data : Block);
   with procedure Sync;
package Legder.Store with SPARK_Mode is

   Max_Entries : constant := Legder.Index.Capacity;
   --  Live keys the table can hold. Bounded; a full table refuses new
   --  keys rather than allocating.

   type Store is limited private;

   procedure Open (S : out Store; Replayed : out Natural);
   --  Recovers from the device. Replayed is the number of committed
   --  records found and applied.

   procedure Put (S : in out Store; K : Key; V : Value; Success : out Boolean);
   --  Durable on return with Success. False when the log is full or
   --  the table is full and K is new.

   procedure Delete (S : in out Store; K : Key; Success : out Boolean);
   --  Durable on return with Success. Deleting an absent key is a
   --  successful no-op that still writes a record (simplest correct
   --  behaviour; optimising it away is fine once S1 is proved).

   procedure Get (S : Store; K : Key; V : out Value; Found : out Boolean);

   function Count (S : Store) return Natural;
   --  Live keys.

private

   type Value_Slab is array (Legder.Index.Slot) of Value;

   package L is new Legder.Log (Block_Count, Read, Write, Sync);

   type Store is limited record
      Log    : L.State;
      Idx    : Legder.Index.Table;
      Values : Value_Slab;
   end record;
   --  Idx maps key -> slot; Values (slot) is that key's value.

end Legder.Store;
