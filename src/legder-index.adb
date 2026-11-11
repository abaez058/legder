package body Legder.Index with SPARK_Mode is

   pragma Unevaluated_Use_Of_Old (Allow);

   subtype Position is Positive range 1 .. Max_Keys + 1;

   Empty_Node : constant Node :=
     (N => 0, Leaf => True, Items => [others => <>], Child => [others => 0]);

   --  Where K belongs in this node: the first slot whose key is K or
   --  bigger. If every key is smaller, it's N + 1 (just past the end).
   function Lower (Nd : Node; K : Key) return Position
     with Global => null;

   function Lower (Nd : Node; K : Key) return Position is
   begin
      for I in 1 .. Nd.N loop
         if not (Nd.Items (I).K < K) then
            return I;
         end if;
      end loop;
      return Nd.N + 1;
   end Lower;

   ------------------------
   -- Proof-only helpers --
   ------------------------

   --  These are "ghost" functions: they exist to describe what correct
   --  looks like, for the prover and for runtime checks when assertions
   --  are switched on. The B-tree itself never calls them.

   --  The free stack is healthy: no node appears on it twice, and
   --  nothing on it is currently part of the tree.
   --
   --  Why it takes three fields instead of the whole table: when we
   --  edit a node's keys, the prover can see straight away that the
   --  free stack wasn't touched, so this stays true for free.
   --
   --  Why the body is hidden: the "no duplicates" rule is a loop inside
   --  a loop, and provers get bogged down in it. Only Alloc_Node and
   --  Free_Node actually change the free stack, so only they look inside.
   function Free_List_Ok
     (Free : Node_Stack; Count : Node_Ref; Used : Used_Array) return Boolean
   is ((for all I in 1 .. Count => not Used (Free (I)))
       and then
         (for all I in 1 .. Count =>
            (for all J in 1 .. Count =>
               (if I /= J then Free (I) /= Free (J)))))
   with Ghost;
   pragma Annotate (GNATprove, Hide_Info, "Expression_Function_Body", Free_List_Ok);

   function Pool_Ok (T : Table) return Boolean is
     (Free_List_Ok (T.Node_Free, T.Node_Free_Count, T.Used))
   with Ghost;

   --  A and B agree on which value slots are taken and which are free.
   function Same_Slots (A, B : Table) return Boolean is
     (A.Total = B.Total
      and then A.Slot_Free_Count = B.Slot_Free_Count
      and then A.Slot_Free = B.Slot_Free)
   with Ghost;

   --  Everything Merge_Children needs before it can run: X's children
   --  I and I + 1 both exist, are real nodes in the tree, are three
   --  different nodes (X and the two children), and each holds exactly
   --  the minimum of 3 keys, so together they fit in one node.
   function Mergeable (T : Table; X : Node_Id; I : Position) return Boolean is
     (Pool_Ok (T)
      and then T.Node_Free_Count < Pool_Size
      and then I <= T.Nodes (X).N
      and then T.Used (X)
      and then T.Nodes (X).Child (I) /= 0
      and then T.Nodes (X).Child (I + 1) /= 0
      and then T.Nodes (X).Child (I) /= X
      and then T.Nodes (X).Child (I + 1) /= X
      and then T.Nodes (X).Child (I) /= T.Nodes (X).Child (I + 1)
      and then T.Used (T.Nodes (X).Child (I))
      and then T.Used (T.Nodes (X).Child (I + 1))
      and then T.Nodes (T.Nodes (X).Child (I)).N = Min_Keys
      and then T.Nodes (T.Nodes (X).Child (I + 1)).N = Min_Keys)
   with Ghost;

   ----------------------
   -- Node pool helpers --
   ----------------------

   procedure Alloc_Node (T : in out Table; R : out Node_Id)
     with Pre  => T.Node_Free_Count > 0 and then Pool_Ok (T),
          Post => Pool_Ok (T)
                  and then Same_Slots (T, T'Old)
                  and then T.Root = T.Root'Old
                  and then T.Node_Free_Count = T.Node_Free_Count'Old - 1
                  and then not T.Used'Old (R)
                  and then T.Used (R)
                  and then T.Nodes (R) = Empty_Node
                  and then (for all J in Node_Id =>
                              (if J /= R then T.Used (J) = T.Used'Old (J)
                                              and then T.Nodes (J) = T.Nodes'Old (J)));
   --  Takes a spare node off the free stack, wipes it clean and marks
   --  it as part of the tree. Nothing else in the tree changes.

   procedure Alloc_Node (T : in out Table; R : out Node_Id) is
      pragma Annotate (GNATprove, Unhide_Info, "Expression_Function_Body", Free_List_Ok);
      C : constant Node_Id := T.Node_Free_Count;
   begin
      R := T.Node_Free (C);
      --  R came off the top of the stack. Because the stack has no
      --  duplicates, R isn't anywhere further down. We spell that out
      --  step by step so the prover doesn't have to work it out alone.
      pragma Assert (Free_List_Ok (T.Node_Free, C, T.Used));
      pragma Assert
        (for all I in 1 .. C - 1 =>
           (for all J in 1 .. C => (if I /= J then T.Node_Free (I) /= T.Node_Free (J))));
      pragma Assert (for all I in 1 .. C - 1 => T.Node_Free (I) /= R);
      pragma Assert (for all I in 1 .. C - 1 => not T.Used (T.Node_Free (I)));
      T.Node_Free_Count := C - 1;
      T.Nodes (R) := Empty_Node;
      T.Used (R) := True;
      --  The stack is one shorter now. Show it's still healthy, one
      --  rule at a time: nothing on it is in use, and no duplicates.
      pragma Assert
        (for all I in 1 .. T.Node_Free_Count => not T.Used (T.Node_Free (I)));
      pragma Assert
        (for all I in 1 .. T.Node_Free_Count =>
           (for all J in 1 .. T.Node_Free_Count =>
              (if I /= J then T.Node_Free (I) /= T.Node_Free (J))));
      pragma Assert (Free_List_Ok (T.Node_Free, T.Node_Free_Count, T.Used));
   end Alloc_Node;

   procedure Free_Node (T : in out Table; R : Node_Id)
     with Pre  => T.Node_Free_Count < Pool_Size
                  and then T.Used (R)
                  and then Pool_Ok (T),
          Post => Pool_Ok (T)
                  and then Same_Slots (T, T'Old)
                  and then T.Root = T.Root'Old
                  and then T.Nodes = T.Nodes'Old
                  and then T.Node_Free_Count = T.Node_Free_Count'Old + 1
                  and then not T.Used (R)
                  and then (for all J in Node_Id =>
                              (if J /= R then T.Used (J) = T.Used'Old (J)));
   --  Puts a node that's no longer in the tree back on the free stack
   --  so it can be reused later.

   procedure Free_Node (T : in out Table; R : Node_Id) is
      pragma Annotate (GNATprove, Unhide_Info, "Expression_Function_Body", Free_List_Ok);
   begin
      T.Node_Free_Count := T.Node_Free_Count + 1;
      T.Node_Free (T.Node_Free_Count) := R;
      T.Used (R) := False;
   end Free_Node;

   -----------------
   -- Split_Child --
   -----------------

   --  Y (child I of X) is full with 7 keys, and X has room for one more.
   --  Split Y down the middle: Y keeps its first 3 keys, a brand-new
   --  node Z gets the last 3, and the middle key moves up into X so it
   --  can sit between them.
   procedure Split_Child (T : in out Table; X : Node_Id; I : Position)
     with Pre  => Pool_Ok (T)
                  and then T.Node_Free_Count > 0
                  and then T.Used (X)
                  and then T.Nodes (X).N < Max_Keys
                  and then I <= T.Nodes (X).N + 1
                  and then T.Nodes (X).Child (I) /= 0
                  and then T.Nodes (X).Child (I) /= X
                  and then T.Used (T.Nodes (X).Child (I))
                  and then T.Nodes (T.Nodes (X).Child (I)).N = Max_Keys,
          Post => Pool_Ok (T)
                  and then Same_Slots (T, T'Old)
                  and then T.Root = T.Root'Old
                  and then T.Node_Free_Count = T.Node_Free_Count'Old - 1
                  and then T.Used (X)
                  and then T.Nodes (X).Leaf = T.Nodes'Old (X).Leaf
                  and then T.Nodes (X).N = T.Nodes'Old (X).N + 1
                  and then T.Nodes (X).Child (I) = T.Nodes'Old (X).Child (I)
                  and then T.Nodes (X).Child (I + 1) /= 0
                  and then T.Nodes (X).Child (I + 1) /= X
                  and then T.Nodes (X).Child (I + 1) /= T.Nodes (X).Child (I)
                  and then not T.Used'Old (T.Nodes (X).Child (I + 1))
                  and then T.Used (T.Nodes (X).Child (I))
                  and then T.Used (T.Nodes (X).Child (I + 1))
                  and then T.Nodes (T.Nodes (X).Child (I)).N = Min_Keys
                  and then T.Nodes (T.Nodes (X).Child (I + 1)).N = Min_Keys
                  and then (for all J in Node_Id =>
                              (if J /= T.Nodes (X).Child (I + 1)
                               then T.Used (J) = T.Used'Old (J)))
                  and then (for all J in Node_Id =>
                              (if J /= X
                                 and then J /= T.Nodes (X).Child (I)
                                 and then J /= T.Nodes (X).Child (I + 1)
                               then T.Nodes (J) = T.Nodes'Old (J)));
   --  Uses up exactly one spare node (the new right half). Only X, Y
   --  and that new node change; the rest of the tree is left alone.

   procedure Split_Child (T : in out Table; X : Node_Id; I : Position) is
      Y      : constant Node_Id := T.Nodes (X).Child (I);
      Old_X  : constant Node := T.Nodes (X);
      Full   : constant Node := T.Nodes (Y);
      NX     : constant Natural := Old_X.N;
      Parent : Node := Old_X;
      Right  : Node := Empty_Node;
      Z      : Node_Id;
   begin
      --  We do all the shuffling on local copies of the nodes and only
      --  write them back into the table at the very end. The result is
      --  the same, but the prover has far less to keep track of: none of
      --  the loops below touches the big table.
      Alloc_Node (T, Z);
      --  Z was on the free stack and X and Y are in the tree, so Z
      --  can't be either of them.
      pragma Assert (Z /= X and then Z /= Y);

      --  Build the new right half from the last 3 keys of the full
      --  node, plus its last 4 children if it has any.
      Right.Leaf := Full.Leaf;
      Right.N := Min_Keys;
      for J in 1 .. Min_Keys loop
         Right.Items (J) := Full.Items (J + Min_Keys + 1);
      end loop;
      if not Full.Leaf then
         for J in 1 .. Min_Keys + 1 loop
            Right.Child (J) := Full.Child (J + Min_Keys + 1);
         end loop;
      end if;

      --  Open a gap in the parent for the new child and the middle key:
      --  shift children right first, then keys.
      for J in reverse I + 1 .. NX + 1 loop
         pragma Loop_Invariant
           (for all M in 1 .. J => Parent.Child (M) = Old_X.Child (M));
         Parent.Child (J + 1) := Parent.Child (J);
      end loop;
      pragma Assert (Parent.Child (I) = Old_X.Child (I));
      Parent.Child (I + 1) := Z;
      for J in reverse I .. NX loop
         Parent.Items (J + 1) := Parent.Items (J);
      end loop;
      Parent.Items (I) := Full.Items (Min_Keys + 1);
      Parent.N := NX + 1;

      T.Nodes (Z) := Right;
      T.Nodes (X) := Parent;
      T.Nodes (Y).N := Min_Keys;
   end Split_Child;

   --------------------
   -- Merge_Children --
   --------------------

   --  The opposite of a split. Children I and I + 1 of X both have
   --  only 3 keys, so we fold them into one: the left child takes X's
   --  separating key plus everything from the right child, and the
   --  right child goes back on the free stack. X ends up with one key
   --  and one child fewer.
   procedure Merge_Children (T : in out Table; X : Node_Id; I : Position)
     with Pre  => Mergeable (T, X, I),
          Post => Pool_Ok (T)
                  and then Same_Slots (T, T'Old)
                  and then T.Root = T.Root'Old
                  and then T.Node_Free_Count = T.Node_Free_Count'Old + 1
                  and then T.Used (X)
                  and then T.Used (T.Nodes'Old (X).Child (I))
                  and then not T.Used (T.Nodes'Old (X).Child (I + 1))
                  and then (for all J in Node_Id =>
                              (if J /= T.Nodes'Old (X).Child (I + 1)
                               then T.Used (J) = T.Used'Old (J)))
                  and then T.Nodes (X).N = T.Nodes'Old (X).N - 1
                  and then T.Nodes (X).Leaf = T.Nodes'Old (X).Leaf
                  and then T.Nodes (X).Child (I) = T.Nodes'Old (X).Child (I)
                  and then T.Nodes (T.Nodes (X).Child (I)).N = Max_Keys
                  and then (for all J in Node_Id =>
                              (if J /= X and then J /= T.Nodes'Old (X).Child (I)
                               then T.Nodes (J) = T.Nodes'Old (J)));
   --  Gives back exactly one node (the old right child). Only X and
   --  the left child change.

   procedure Merge_Children (T : in out Table; X : Node_Id; I : Position) is
      Y      : constant Node_Id := T.Nodes (X).Child (I);
      Z      : constant Node_Id := T.Nodes (X).Child (I + 1);
      Old_X  : constant Node := T.Nodes (X);
      Right  : constant Node := T.Nodes (Z);
      NX     : constant Natural := Old_X.N;
      Left   : Node := T.Nodes (Y);
      Parent : Node := Old_X;
   begin
      --  Same trick as Split_Child: work on local copies, then write
      --  each node back once at the end.
      Left.Items (Min_Keys + 1) := Old_X.Items (I);
      for J in 1 .. Min_Keys loop
         Left.Items (J + Min_Keys + 1) := Right.Items (J);
      end loop;
      if not Left.Leaf then
         for J in 1 .. Min_Keys + 1 loop
            Left.Child (J + Min_Keys + 1) := Right.Child (J);
         end loop;
      end if;
      Left.N := Max_Keys;

      for J in I .. NX - 1 loop
         Parent.Items (J) := Parent.Items (J + 1);
      end loop;
      for J in I + 1 .. NX loop
         pragma Loop_Invariant
           (for all M in 1 .. I => Parent.Child (M) = Old_X.Child (M));
         Parent.Child (J) := Parent.Child (J + 1);
      end loop;
      Parent.Child (NX + 1) := 0;
      Parent.N := NX - 1;

      T.Nodes (Y) := Left;
      T.Nodes (X) := Parent;
      Free_Node (T, Z);
   end Merge_Children;

   --  Merge two children, and if that leaves the root with no keys,
   --  drop the old root so the tree gets one level shorter.
   --  Merged returns the node that now holds the combined keys.
   procedure Merge_And_Shrink
     (T : in out Table; X : Node_Id; I : Position; Merged : out Node_Id)
     with Pre  => Mergeable (T, X, I)
                  and then T.Node_Free_Count < Pool_Size - 1
                  and then T.Used (T.Root)
                  and then T.Nodes (X).Child (I + 1) /= T.Root,
          Post => Pool_Ok (T)
                  and then Same_Slots (T, T'Old)
                  and then Merged = T.Nodes'Old (X).Child (I)
                  and then T.Used (Merged)
                  and then T.Nodes (Merged).N = Max_Keys
                  and then T.Used (T.Root)
                  and then (T.Root = T.Root'Old or else T.Root = Merged);
   --  Afterwards Merged is in the tree and full, and the root is
   --  either the same as before or is now Merged.

   procedure Merge_And_Shrink
     (T : in out Table; X : Node_Id; I : Position; Merged : out Node_Id) is
   begin
      Merged := T.Nodes (X).Child (I);
      Merge_Children (T, X, I);
      if X = T.Root and then T.Nodes (X).N = 0 then
         T.Root := Merged;
         Free_Node (T, X);
      end if;
   end Merge_And_Shrink;

   ------------------------
   -- Borrow from sibling --
   ------------------------

   --  Child P of X is down to 3 keys, but its left neighbour has
   --  4 or more to spare. Pass one key across: the neighbour's biggest
   --  key moves up into X, and X's old separating key moves down into
   --  child P.
   procedure Borrow_From_Left (T : in out Table; X : Node_Id; P : Position)
     with Pre  => P >= 2 and then P <= T.Nodes (X).N + 1
                  and then T.Nodes (X).Child (P) /= 0
                  and then T.Nodes (X).Child (P - 1) /= 0
                  and then T.Nodes (X).Child (P) /= X
                  and then T.Nodes (X).Child (P - 1) /= X
                  and then T.Nodes (X).Child (P) /= T.Nodes (X).Child (P - 1)
                  and then T.Nodes (T.Nodes (X).Child (P)).N = Min_Keys
                  and then T.Nodes (T.Nodes (X).Child (P - 1)).N > Min_Keys,
          Post => Same_Slots (T, T'Old)
                  and then T.Root = T.Root'Old
                  and then T.Used = T.Used'Old
                  and then T.Node_Free = T.Node_Free'Old
                  and then T.Node_Free_Count = T.Node_Free_Count'Old
                  and then T.Nodes (X).N = T.Nodes'Old (X).N
                  and then T.Nodes (X).Leaf = T.Nodes'Old (X).Leaf
                  and then T.Nodes (X).Child = T.Nodes'Old (X).Child
                  and then T.Nodes (T.Nodes (X).Child (P)).N = Min_Keys + 1
                  and then (for all J in Node_Id =>
                              (if J /= X
                                 and then J /= T.Nodes (X).Child (P)
                                 and then J /= T.Nodes (X).Child (P - 1)
                               then T.Nodes (J) = T.Nodes'Old (J)));
   --  Only X, child P and its left neighbour change. No nodes are
   --  created or freed.

   procedure Borrow_From_Left (T : in out Table; X : Node_Id; P : Position) is
      C  : constant Node_Id := T.Nodes (X).Child (P);
      S  : constant Node_Id := T.Nodes (X).Child (P - 1);
      Ch : Node := T.Nodes (C);
      Sb : Node := T.Nodes (S);
      Pa : Node := T.Nodes (X);
   begin
      for J in reverse 1 .. Ch.N loop
         Ch.Items (J + 1) := Ch.Items (J);
      end loop;
      if not Ch.Leaf then
         for J in reverse 1 .. Ch.N + 1 loop
            Ch.Child (J + 1) := Ch.Child (J);
         end loop;
         Ch.Child (1) := Sb.Child (Sb.N + 1);
         Sb.Child (Sb.N + 1) := 0;
      end if;
      Ch.Items (1) := Pa.Items (P - 1);
      Pa.Items (P - 1) := Sb.Items (Sb.N);
      Sb.N := Sb.N - 1;
      Ch.N := Ch.N + 1;

      T.Nodes (C) := Ch;
      T.Nodes (S) := Sb;
      T.Nodes (X) := Pa;
   end Borrow_From_Left;

   --  Same idea from the other side: child P is down to 3 keys and its
   --  right neighbour has one to spare.
   procedure Borrow_From_Right (T : in out Table; X : Node_Id; P : Position)
     with Pre  => P <= T.Nodes (X).N
                  and then T.Nodes (X).Child (P) /= 0
                  and then T.Nodes (X).Child (P + 1) /= 0
                  and then T.Nodes (X).Child (P) /= X
                  and then T.Nodes (X).Child (P + 1) /= X
                  and then T.Nodes (X).Child (P) /= T.Nodes (X).Child (P + 1)
                  and then T.Nodes (T.Nodes (X).Child (P)).N = Min_Keys
                  and then T.Nodes (T.Nodes (X).Child (P + 1)).N > Min_Keys,
          Post => Same_Slots (T, T'Old)
                  and then T.Root = T.Root'Old
                  and then T.Used = T.Used'Old
                  and then T.Node_Free = T.Node_Free'Old
                  and then T.Node_Free_Count = T.Node_Free_Count'Old
                  and then T.Nodes (X).N = T.Nodes'Old (X).N
                  and then T.Nodes (X).Leaf = T.Nodes'Old (X).Leaf
                  and then T.Nodes (X).Child = T.Nodes'Old (X).Child
                  and then T.Nodes (T.Nodes (X).Child (P)).N = Min_Keys + 1
                  and then (for all J in Node_Id =>
                              (if J /= X
                                 and then J /= T.Nodes (X).Child (P)
                                 and then J /= T.Nodes (X).Child (P + 1)
                               then T.Nodes (J) = T.Nodes'Old (J)));
   --  Only X, child P and its right neighbour change. No nodes are
   --  created or freed.

   procedure Borrow_From_Right (T : in out Table; X : Node_Id; P : Position) is
      C  : constant Node_Id := T.Nodes (X).Child (P);
      S  : constant Node_Id := T.Nodes (X).Child (P + 1);
      NS : constant Positive := T.Nodes (S).N;
      Ch : Node := T.Nodes (C);
      Sb : Node := T.Nodes (S);
      Pa : Node := T.Nodes (X);
   begin
      Ch.Items (Ch.N + 1) := Pa.Items (P);
      if not Ch.Leaf then
         Ch.Child (Ch.N + 2) := Sb.Child (1);
         for J in 1 .. NS loop
            Sb.Child (J) := Sb.Child (J + 1);
         end loop;
         Sb.Child (NS + 1) := 0;
      end if;
      Pa.Items (P) := Sb.Items (1);
      for J in 1 .. NS - 1 loop
         Sb.Items (J) := Sb.Items (J + 1);
      end loop;
      Sb.N := NS - 1;
      Ch.N := Ch.N + 1;

      T.Nodes (C) := Ch;
      T.Nodes (S) := Sb;
      T.Nodes (X) := Pa;
   end Borrow_From_Right;

   -----------
   -- Clear --
   -----------

   procedure Clear (T : out Table) is
   begin
      T.Nodes := [others => Empty_Node];
      T.Node_Free := [others => 1];
      T.Root := 1;
      T.Total := 0;
      T.Used := [1 => True, others => False];   --  just the (empty) root
      for I in 1 .. Pool_Size - 1 loop
         pragma Loop_Invariant
           (for all J in 1 .. I - 1 => T.Node_Free (J) = Pool_Size - J + 1);
         T.Node_Free (I) := Pool_Size - I + 1;   --  node 2 ends up on top
      end loop;
      T.Node_Free_Count := Pool_Size - 1;          --  all but node 1, the root
      for I in Slot loop
         T.Slot_Free (I) := Capacity - I + 1;      --  slot 1 ends up on top
      end loop;
      T.Slot_Free_Count := Capacity;
   end Clear;

   ----------
   -- Find --
   ----------

   function Find (T : Table; K : Key) return Slot_Or_None is
      X : Node_Id := T.Root;
   begin
      for Depth in 1 .. Max_Depth loop
         declare
            P : constant Position := Lower (T.Nodes (X), K);
         begin
            if P <= T.Nodes (X).N and then T.Nodes (X).Items (P).K = K then
               return T.Nodes (X).Items (P).S;
            elsif T.Nodes (X).Leaf then
               return 0;
            else
               X := T.Nodes (X).Child (P);
            end if;
         end;
      end loop;
      --  A healthy tree is never this deep, so getting here means the
      --  tree is broken. Fail loudly rather than pretend the key is
      --  simply missing.
      raise Program_Error with "Find: descent exceeded Max_Depth";
   end Find;

   ------------
   -- Insert --
   ------------

   procedure Insert (T : in out Table; K : Key; S : out Slot; Ok : out Boolean) is
      X        : Node_Id;
      P        : Position;
      Inserted : Boolean := False;
   begin
      if T.Total = Capacity then
         S := 1;
         Ok := False;
         return;
      end if;

      S := T.Slot_Free (T.Slot_Free_Count);
      T.Slot_Free_Count := T.Slot_Free_Count - 1;

      --  If the root is full, split it first. This is the only place
      --  the tree ever gets taller.
      if T.Nodes (T.Root).N = Max_Keys then
         declare
            Old_Root : constant Node_Id := T.Root;
            New_Root : Node_Id;
         begin
            Alloc_Node (T, New_Root);
            T.Nodes (New_Root).Leaf := False;
            T.Nodes (New_Root).Child (1) := Old_Root;
            Split_Child (T, New_Root, 1);
            T.Root := New_Root;
         end;
      end if;

      --  Walk down towards the right leaf. Any full child gets split
      --  before we step into it, so when we reach the leaf it's
      --  guaranteed to have room.
      X := T.Root;
      for Depth in 1 .. Max_Depth loop
         P := Lower (T.Nodes (X), K);
         if T.Nodes (X).Leaf then
            for J in reverse P .. T.Nodes (X).N loop
               T.Nodes (X).Items (J + 1) := T.Nodes (X).Items (J);
            end loop;
            T.Nodes (X).Items (P) := (K => K, S => S);
            T.Nodes (X).N := T.Nodes (X).N + 1;
            Inserted := True;
            exit;
         else
            if T.Nodes (T.Nodes (X).Child (P)).N = Max_Keys then
               Split_Child (T, X, P);
               if T.Nodes (X).Items (P).K < K then
                  P := P + 1;
               end if;
            end if;
            X := T.Nodes (X).Child (P);
         end if;
      end loop;

      --  Never say "done" unless the key really went in.
      if not Inserted then
         raise Program_Error with "Insert: no leaf reached within Max_Depth";
      end if;

      T.Total := T.Total + 1;
      Ok := True;
   end Insert;

   ------------
   -- Remove --
   ------------

   procedure Remove (T : in out Table; K : Key; Removed : out Boolean) is
      Old_Slot : constant Slot_Or_None := Find (T, K);
      Target   : Key := K;
      X        : Node_Id;
      Deleted  : Boolean := False;
   begin
      if Old_Slot = 0 then
         Removed := False;
         return;
      end if;

      --  Delete on the way down. Before stepping into a node we make
      --  sure it has at least 4 keys (the root is the exception), so
      --  taking one away never leaves it below the minimum.
      X := T.Root;
      for Depth in 1 .. Max_Depth loop
         declare
            P   : constant Position := Lower (T.Nodes (X), Target);
            Hit : constant Boolean :=
              P <= T.Nodes (X).N and then T.Nodes (X).Items (P).K = Target;
         begin
            if T.Nodes (X).Leaf then
               --  The key should be right here: we know it's in the tree
               --  and this is the only leaf it could be in. Still, check
               --  rather than assume.
               if not Hit then
                  raise Program_Error
                    with "Remove: key not found at the leaf it was routed to";
               end if;
               for J in P .. T.Nodes (X).N - 1 loop
                  T.Nodes (X).Items (J) := T.Nodes (X).Items (J + 1);
               end loop;
               T.Nodes (X).N := T.Nodes (X).N - 1;
               Deleted := True;
               exit;

            elsif Hit then
               --  The key is in an inner node, not a leaf. Swap in its
               --  closest neighbour from a leaf below (just smaller or
               --  just bigger), then go and delete that one instead.
               declare
                  Y : constant Node_Id := T.Nodes (X).Child (P);
                  Z : constant Node_Id := T.Nodes (X).Child (P + 1);
                  W : Node_Id;
               begin
                  if T.Nodes (Y).N > Min_Keys then
                     W := Y;
                     while not T.Nodes (W).Leaf loop
                        W := T.Nodes (W).Child (T.Nodes (W).N + 1);
                     end loop;
                     T.Nodes (X).Items (P) := T.Nodes (W).Items (T.Nodes (W).N);
                     Target := T.Nodes (X).Items (P).K;
                     X := Y;
                  elsif T.Nodes (Z).N > Min_Keys then
                     W := Z;
                     while not T.Nodes (W).Leaf loop
                        W := T.Nodes (W).Child (1);
                     end loop;
                     T.Nodes (X).Items (P) := T.Nodes (W).Items (1);
                     Target := T.Nodes (X).Items (P).K;
                     X := Z;
                  else
                     Merge_And_Shrink (T, X, P, W);
                     X := W;
                  end if;
               end;

            else
               --  The key is somewhere under child P. Top that child up
               --  to at least 4 keys (borrow from a neighbour, or merge)
               --  before going down into it.
               declare
                  C : Node_Id := T.Nodes (X).Child (P);
               begin
                  if T.Nodes (C).N = Min_Keys then
                     if P > 1
                       and then T.Nodes (T.Nodes (X).Child (P - 1)).N > Min_Keys
                     then
                        Borrow_From_Left (T, X, P);
                     elsif P <= T.Nodes (X).N
                       and then T.Nodes (T.Nodes (X).Child (P + 1)).N > Min_Keys
                     then
                        Borrow_From_Right (T, X, P);
                     elsif P <= T.Nodes (X).N then
                        Merge_And_Shrink (T, X, P, C);
                     else
                        Merge_And_Shrink (T, X, P - 1, C);
                     end if;
                  end if;
                  X := C;
               end;
            end if;
         end;
      end loop;

      --  Only hand the slot back and report success if a key was
      --  really removed.
      if not Deleted then
         raise Program_Error with "Remove: no leaf reached within Max_Depth";
      end if;

      T.Slot_Free_Count := T.Slot_Free_Count + 1;
      T.Slot_Free (T.Slot_Free_Count) := Old_Slot;
      T.Total := T.Total - 1;
      Removed := True;
   end Remove;

   ---------
   -- Nth --
   ---------

   --  Returns the Pos-th smallest key. Walks the tree in sorted order,
   --  keeping its own stack of "which node, which key next" instead of
   --  using recursion.
   function Nth (T : Table; Pos : Positive) return Key is
      Fr_Node : array (1 .. Max_Depth) of Node_Id := [others => 1];
      Fr_Idx  : array (1 .. Max_Depth) of Positive := [others => 1];
      Sp      : Natural := 0;
      Seen    : Natural := 0;
      X       : Node_Id := T.Root;
   begin
      for Level in 1 .. Max_Depth loop
         Sp := Sp + 1;
         Fr_Node (Sp) := X;
         Fr_Idx (Sp) := 1;
         exit when T.Nodes (X).Leaf;
         X := T.Nodes (X).Child (1);
      end loop;

      for Step in 1 .. 4 * Capacity loop
         exit when Sp = 0;
         declare
            Cur : constant Node_Id := Fr_Node (Sp);
            I   : constant Positive := Fr_Idx (Sp);
         begin
            if I > T.Nodes (Cur).N then
               Sp := Sp - 1;
            else
               Seen := Seen + 1;
               if Seen = Pos then
                  return T.Nodes (Cur).Items (I).K;
               end if;
               Fr_Idx (Sp) := I + 1;
               if not T.Nodes (Cur).Leaf then
                  X := T.Nodes (Cur).Child (I + 1);
                  for Level in 1 .. Max_Depth loop
                     Sp := Sp + 1;
                     Fr_Node (Sp) := X;
                     Fr_Idx (Sp) := 1;
                     exit when T.Nodes (X).Leaf;
                     X := T.Nodes (X).Child (1);
                  end loop;
               end if;
            end if;
         end;
      end loop;
      --  We were promised at least Pos keys, so we should have found
      --  one above. Getting here means the tree and its key count
      --  disagree. Fail loudly rather than hand back a blank key that
      --  looks real.
      raise Program_Error with "Nth: tree holds fewer keys than Count";
   end Nth;

   -----------------
   -- Well_Formed --
   -----------------

   function Well_Formed (T : Table) return Boolean is
      subtype Item_Idx is Positive range 1 .. Max_Keys;
      Stack_Size : constant := Max_Depth * (Max_Keys + 1);
      St_Node  : array (1 .. Stack_Size) of Node_Id := [others => 1];
      St_Depth : array (1 .. Stack_Size) of Positive := [others => 1];
      --  For each node waiting on the stack: the keys it must stay
      --  between, given by its ancestors. Stored as (node, position)
      --  of the bounding key; node 0 means "no limit on this side".
      St_Lo_N  : array (1 .. Stack_Size) of Node_Ref := [others => 0];
      St_Lo_I  : array (1 .. Stack_Size) of Item_Idx := [others => 1];
      St_Hi_N  : array (1 .. Stack_Size) of Node_Ref := [others => 0];
      St_Hi_I  : array (1 .. Stack_Size) of Item_Idx := [others => 1];
      Seen_Node  : array (Node_Id) of Boolean := [others => False];
      Seen_Slot  : array (Slot) of Boolean := [others => False];
      Sp         : Natural := 1;
      Nodes_Seen : Natural := 0;
      Keys_Seen  : Natural := 0;
      Leaf_Depth : Natural := 0;
   begin
      St_Node (1) := T.Root;
      St_Depth (1) := 1;
      for Step in 1 .. Pool_Size + 1 loop
         exit when Sp = 0;
         declare
            X    : constant Node_Id := St_Node (Sp);
            D    : constant Positive := St_Depth (Sp);
            Lo_N : constant Node_Ref := St_Lo_N (Sp);
            Lo_I : constant Item_Idx := St_Lo_I (Sp);
            Hi_N : constant Node_Ref := St_Hi_N (Sp);
            Hi_I : constant Item_Idx := St_Hi_I (Sp);
         begin
            Sp := Sp - 1;
            if Seen_Node (X) then   --  seen it already: shared node or a loop
               return False;
            end if;
            if not T.Used (X) then   --  in the tree but marked as spare
               return False;
            end if;
            Seen_Node (X) := True;
            Nodes_Seen := Nodes_Seen + 1;
            Keys_Seen := Keys_Seen + T.Nodes (X).N;

            if X /= T.Root and then T.Nodes (X).N < Min_Keys then
               return False;
            end if;
            if X = T.Root and then not T.Nodes (X).Leaf and then T.Nodes (X).N < 1 then
               return False;
            end if;

            for J in 1 .. T.Nodes (X).N loop
               --  keys inside a node must go up in order
               if J > 1
                 and then not (T.Nodes (X).Items (J - 1).K < T.Nodes (X).Items (J).K)
               then
                  return False;
               end if;
               --  and stay between the limits set by its ancestors
               if Lo_N /= 0
                 and then not (T.Nodes (Lo_N).Items (Lo_I).K < T.Nodes (X).Items (J).K)
               then
                  return False;
               end if;
               if Hi_N /= 0
                 and then not (T.Nodes (X).Items (J).K < T.Nodes (Hi_N).Items (Hi_I).K)
               then
                  return False;
               end if;
               --  no two keys may share a value slot
               if Seen_Slot (T.Nodes (X).Items (J).S) then
                  return False;
               end if;
               Seen_Slot (T.Nodes (X).Items (J).S) := True;
            end loop;

            if T.Nodes (X).Leaf then
               if Leaf_Depth = 0 then
                  Leaf_Depth := D;
               elsif Leaf_Depth /= D then
                  return False;
               end if;
            else
               if D >= Max_Depth or else Sp + T.Nodes (X).N + 1 > Stack_Size then
                  return False;
               end if;
               for J in 1 .. T.Nodes (X).N + 1 loop
                  if T.Nodes (X).Child (J) = 0 then
                     return False;
                  end if;
                  Sp := Sp + 1;
                  St_Node (Sp) := T.Nodes (X).Child (J);
                  St_Depth (Sp) := D + 1;
                  if J > 1 then
                     St_Lo_N (Sp) := X;
                     St_Lo_I (Sp) := J - 1;
                  else
                     St_Lo_N (Sp) := Lo_N;
                     St_Lo_I (Sp) := Lo_I;
                  end if;
                  if J <= T.Nodes (X).N then
                     St_Hi_N (Sp) := X;
                     St_Hi_I (Sp) := J;
                  else
                     St_Hi_N (Sp) := Hi_N;
                     St_Hi_I (Sp) := Hi_I;
                  end if;
               end loop;
            end if;
         end;
      end loop;

      if Sp /= 0 then
         return False;
      end if;

      --  Spare nodes and spare slots must not also be in use, and
      --  nothing may be on a free stack twice.
      for I in 1 .. T.Node_Free_Count loop
         if Seen_Node (T.Node_Free (I)) or else T.Used (T.Node_Free (I)) then
            return False;
         end if;
         Seen_Node (T.Node_Free (I)) := True;
      end loop;
      for I in 1 .. T.Slot_Free_Count loop
         if Seen_Slot (T.Slot_Free (I)) then
            return False;
         end if;
         Seen_Slot (T.Slot_Free (I)) := True;
      end loop;

      return Keys_Seen = T.Total
        and then Nodes_Seen + T.Node_Free_Count = Pool_Size
        and then T.Slot_Free_Count + T.Total = Capacity;
   end Well_Formed;

end Legder.Index;