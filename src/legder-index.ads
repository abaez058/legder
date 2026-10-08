--  The ordered index: maps a Key to the slot that holds its value.
--
--  Pure. No device, no log. Legder.Store owns the commit order and
--  calls this package only after a record is durable (or while
--  replaying one), so the index is always a replay of the log.
--
--  Representation: an in-memory B-tree (minimum degree 4: 3 to 7
--  keys per node, 4 to 8 children). Nodes live in a fixed pool and
--  "pointers" are pool indices, so there is no heap and no access
--  type. Insert splits full nodes on the way down; Remove keeps every
--  node it enters at 4+ keys (borrow or merge), so neither ever walks
--  back up the tree.
--
--  Values are not in the tree. The tree maps Key -> Slot, and the
--  store keeps its values in a slab indexed by Slot, so the tree
--  moves small items and never a 256-byte value. Slots are handed
--  out by Insert and recycled by Remove through a free stack.
--
--  Why a fixed node pool is enough: every node except the root holds
--  at least 3 keys, so Capacity (256) keys need at most 86 nodes.
--  The pool has 96, so Insert can fail only when the index holds
--  Capacity keys, never because nodes ran out.
--
--  PROOF TARGETS
--    I1  Keys are strictly increasing under "<" (no duplicates).
--    I2  Find (K) is the slot of the last Insert (K) not followed by
--        Remove (K), or 0.
--    I3  Insert fails if and only if the index holds Capacity keys.
--    I4  Well_Formed holds after every operation (B-tree shape).

package Legder.Index with SPARK_Mode is

   pragma Unevaluated_Use_Of_Old (Allow);

   Capacity : constant := 256;
   --  Live keys. Bounded on purpose; a full index refuses new keys.

   subtype Slot is Positive range 1 .. Capacity;
   subtype Slot_Or_None is Natural range 0 .. Capacity;

   type Table is private;

   procedure Clear (T : out Table)
     with Post => Count (T) = 0;

   function Count (T : Table) return Natural
     with Post => Count'Result <= Capacity;

   function Is_Full (T : Table) return Boolean is (Count (T) = Capacity);

   function Find (T : Table; K : Key) return Slot_Or_None;
   --  The slot holding K, or 0 when K is absent.

   procedure Insert (T : in out Table; K : Key; S : out Slot; Ok : out Boolean)
     with Pre  => Find (T, K) = 0,
          Post => (if Ok then Count (T) = Count (T)'Old + 1
                              and then Find (T, K) = S
                   else Count (T)'Old = Capacity
                        and then Count (T) = Count (T)'Old);
   --  Adds K and returns the slot to store its value in. Ok = False
   --  only when the index is full; then T is unchanged. K must be
   --  absent (the store calls Find first and overwrites in place).

   procedure Remove (T : in out Table; K : Key; Removed : out Boolean)
     with Post => Find (T, K) = 0
                  and then Count (T) = Count (T)'Old - (if Removed then 1 else 0);
   --  Removes K and recycles its slot. Removing an absent key is a
   --  no-op with Removed = False.

   function Nth (T : Table; Pos : Positive) return Key
     with Pre => Pos <= Count (T);
   --  The Pos-th smallest key (in-order walk). Used by tests to check
   --  ordering and by future range scans.

   function Well_Formed (T : Table) return Boolean;
   --  Structural check of the whole B-tree: node fill (3 to 7 keys,
   --  root may have fewer), all leaves at the same depth, key count
   --  equals Count, no node lost or counted twice, and slot count
   --  consistent. Walks the tree, so it is for tests and proofs, not
   --  for use in production paths.

private

   Max_Keys  : constant := 7;    --  2 * degree - 1
   Min_Keys  : constant := 3;    --  degree - 1 (every non-root node)
   Pool_Size : constant := 96;   --  see the note above: 86 nodes max
   Max_Depth : constant := 10;   --  far above the real height (<= 5)

   subtype Node_Ref is Natural range 0 .. Pool_Size;   --  0 = none
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
   --  Items (1 .. N) sorted. Child (1 .. N + 1) are used when not Leaf;
   --  everything in Child (I) sorts before Items (I), everything in
   --  Child (I + 1) sorts after it.

   type Node_Array is array (Node_Id) of Node;
   type Node_Stack is array (Node_Id) of Node_Id;
   type Slot_Stack is array (Slot) of Slot;

   type Table is record
      Nodes           : Node_Array;
      Root            : Node_Id := 1;
      Total           : Natural range 0 .. Capacity := 0;
      Node_Free       : Node_Stack := [others => 1];
      Node_Free_Count : Natural range 0 .. Pool_Size := 0;
      Slot_Free       : Slot_Stack := [others => 1];
      Slot_Free_Count : Natural range 0 .. Capacity := 0;
   end record;
   --  Node_Free (1 .. Node_Free_Count) are the unused nodes and
   --  Slot_Free (1 .. Slot_Free_Count) the unused slots. Node_Free_Count
   --  plus the nodes reachable from Root is always Pool_Size, and
   --  Slot_Free_Count = Capacity - Total.

end Legder.Index;
