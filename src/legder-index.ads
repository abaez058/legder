--  The index: looks up which slot holds the value for a given key.
--
--  This package only keeps the lookup table in memory. It never talks
--  to the device or the log. Legder.Store decides when to call it:
--  only after a record is safely in the log, or while replaying the
--  log at startup. So the index is always a rebuild of what the log
--  says.
--
--  How it's built: a B-tree where each node holds 3 to 7 keys and has
--  4 to 8 children. Nodes come from a fixed pool, and a "pointer" is
--  just a node number in that pool, so there's no heap allocation at
--  all. Insert splits full nodes on its way down, and Remove makes
--  sure every node it enters has at least 4 keys (borrowing from a
--  neighbour or merging), so neither one ever has to climb back up.
--
--  The values themselves aren't stored in the tree. The tree only
--  maps each key to a slot number, and the store keeps the actual
--  values in a separate array indexed by slot. That way the tree only
--  ever shuffles small items around, never 256-byte values. Insert
--  hands out free slots and Remove gives them back.
--
--  Why 96 nodes is always enough: every node except the root holds at
--  least 3 keys, so 256 keys need at most 86 nodes. With 96 in the
--  pool, Insert can only fail because the index already holds 256
--  keys, never because it ran out of nodes. Pool_Size is calculated
--  from Capacity below, so the two can't get out of step.
--
--  What we want to prove about the index:
--    I1  Keys are in strictly increasing order (so no duplicates).
--    I2  Find (K) returns the slot from the most recent Insert (K),
--        or 0 if K was never inserted or has since been removed.
--    I3  Insert fails only when the index is already full.
--    I4  Well_Formed is true after every operation.
--
--  Status: none of I1 to I4 is proved yet; the tests check them. What
--  is proved so far is the internal helpers in the body (allocating,
--  freeing, splitting, merging and borrowing nodes): no runtime errors,
--  and each one does exactly what its contract says.

package Legder.Index with SPARK_Mode is

   pragma Unevaluated_Use_Of_Old (Allow);

   Capacity : constant := 256;
   --  Most keys the index can hold. Deliberately fixed: once it's
   --  full, new keys are refused.

   subtype Slot is Positive range 1 .. Capacity;
   subtype Slot_Or_None is Natural range 0 .. Capacity;

   type Table is private;

   procedure Clear (T : out Table)
     with Post => Count (T) = 0;

   function Count (T : Table) return Natural
     with Post => Count'Result <= Capacity;

   function Is_Full (T : Table) return Boolean is (Count (T) = Capacity);

   function Find (T : Table; K : Key) return Slot_Or_None;
   --  The slot holding K's value, or 0 if K isn't there. If the tree
   --  turns out to be corrupt (deeper than any healthy tree could be),
   --  it raises Program_Error instead of guessing.

   procedure Insert (T : in out Table; K : Key; S : out Slot; Ok : out Boolean)
     with Pre  => Find (T, K) = 0,
          Post => (if Ok then Count (T) = Count (T)'Old + 1
                              and then Find (T, K) = S
                   else Count (T)'Old = Capacity
                        and then Count (T) = Count (T)'Old);
   --  Adds K and gives back the slot to put its value in. Ok is False
   --  only when the index is full, and then nothing changes. K must not
   --  be there already: the store checks with Find first and, if the
   --  key exists, just overwrites the value in its slot. Raises
   --  Program_Error if the tree is corrupt; it never says Ok for a key
   --  it didn't actually add.

   procedure Remove (T : in out Table; K : Key; Removed : out Boolean)
     with Post => Find (T, K) = 0
                  and then Count (T) = Count (T)'Old - (if Removed then 1 else 0);
   --  Takes K out and frees its slot for reuse. Removing a key that
   --  isn't there does nothing and sets Removed to False. Raises
   --  Program_Error if the tree is corrupt; it never says Removed for
   --  a key it didn't actually remove.

   function Nth (T : Table; Pos : Positive) return Key
     with Pre => Pos <= Count (T);
   --  The Pos-th smallest key. The tests use it to check the keys come
   --  out in order, and a future range scan can build on it. Raises
   --  Program_Error if the tree holds fewer keys than Count claims.

   function Well_Formed (T : Table) return Boolean;
   --  A full health check of the tree. It confirms that:
   --    - every node has 3 to 7 keys (the root may have fewer),
   --    - keys go up in order inside each node,
   --    - every key sits between the limits set by the nodes above it,
   --    - all leaves are at the same depth,
   --    - the number of keys matches Count,
   --    - no node is reachable twice (no sharing, no loops),
   --    - nothing is both in use and on a free list,
   --    - the slot bookkeeping adds up.
   --  It walks the whole tree, so it's meant for tests and proofs, not
   --  for everyday use.

private

   Max_Keys  : constant := 7;    --  most keys a node can hold
   Min_Keys  : constant := 3;    --  fewest keys in any node except the root

   --  Most nodes a full tree can need: every non-root node holds at
   --  least Min_Keys keys and the root holds at least 1.
   Min_Pool  : constant := (Capacity - 1) / Min_Keys + 1;   --  86 nodes
   Pool_Size : constant := Min_Pool + 10;                   --  96, with spares
   Max_Depth : constant := 10;   --  generous; a real tree is at most 5 deep

   --  Compile-time sanity check: a tree deeper than Max_Depth would
   --  need more than Capacity keys, so Max_Depth levels are always
   --  enough. If someone raises Capacity too far, the build fails here.
   pragma Compile_Time_Error
     (2 * (Min_Keys + 1) ** Max_Depth - 1 <= Capacity,
      "Max_Depth too small for Capacity");

   subtype Node_Ref is Natural range 0 .. Pool_Size;   --  0 means "no node"
   subtype Node_Id  is Node_Ref range 1 .. Pool_Size;

   type Item is record
      K : Key;
      S : Slot := 1;
   end record;

   type Item_Array  is array (1 .. Max_Keys) of Item;
   type Child_Array is array (1 .. Max_Keys + 1) of Node_Ref;

   type Node is record
      N     : Natural range 0 .. Max_Keys := 0;
      Leaf  : Boolean := True;
      Items : Item_Array;
      Child : Child_Array := [others => 0];
   end record;
   --  Only the first N items are real, and they're kept sorted. If the
   --  node isn't a leaf, its first N + 1 children are real: everything
   --  under Child (I) is smaller than Items (I), and everything under
   --  Child (I + 1) is bigger.

   type Node_Array is array (Node_Id) of Node;
   type Node_Stack is array (Node_Id) of Node_Id;
   type Slot_Stack is array (Slot) of Slot;
   type Used_Array is array (Node_Id) of Boolean;

   type Table is record
      Nodes           : Node_Array;
      Root            : Node_Id := 1;
      Total           : Natural range 0 .. Capacity := 0;
      Node_Free       : Node_Stack := [others => 1];
      Node_Free_Count : Natural range 0 .. Pool_Size := 0;
      Slot_Free       : Slot_Stack := [others => 1];
      Slot_Free_Count : Natural range 0 .. Capacity := 0;
      Used            : Used_Array := [others => False];
   end record;
   --  Two stacks of spares: Node_Free holds the unused nodes (the first
   --  Node_Free_Count entries) and Slot_Free holds the unused slots.
   --  Spare nodes plus nodes in the tree always add up to Pool_Size,
   --  and spare slots plus Total always add up to Capacity.
   --
   --  Used (N) says whether node N is currently in the tree, so it's
   --  False for everything on the spare stack. The B-tree doesn't need
   --  it to work; it's there for the prover. Because a newly allocated
   --  node wasn't in use, the prover can tell it's not the same as any
   --  node the caller is already working on.

   function Count (T : Table) return Natural is (T.Total);

end Legder.Index;