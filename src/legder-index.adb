package body Legder.Index with SPARK_Mode is

   subtype Position is Positive range 1 .. Max_Keys + 1;

   Empty_Node : constant Node :=
     (N => 0, Leaf => True, Items => [others => <>], Child => [others => 0]);

   --  First position in a node whose key is not smaller than K
   --  (N + 1 when every key is smaller).
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

   ----------------------
   -- Node pool helpers --
   ----------------------

   procedure Alloc_Node (T : in out Table; R : out Node_Id)
     with Pre => T.Node_Free_Count > 0;

   procedure Alloc_Node (T : in out Table; R : out Node_Id) is
   begin
      R := T.Node_Free (T.Node_Free_Count);
      T.Node_Free_Count := T.Node_Free_Count - 1;
      T.Nodes (R) := Empty_Node;
   end Alloc_Node;

   procedure Free_Node (T : in out Table; R : Node_Id)
     with Pre => T.Node_Free_Count < Pool_Size;

   procedure Free_Node (T : in out Table; R : Node_Id) is
   begin
      T.Node_Free_Count := T.Node_Free_Count + 1;
      T.Node_Free (T.Node_Free_Count) := R;
   end Free_Node;

   -----------------
   -- Split_Child --
   -----------------

   --  X is not full; its I-th child Y is full (7 keys). Y keeps its
   --  first 3 keys, a new node Z takes the last 3, and the middle key
   --  moves up into X at position I.
   procedure Split_Child (T : in out Table; X : Node_Id; I : Position)
     with Pre => T.Node_Free_Count > 0
                 and then T.Nodes (X).N < Max_Keys
                 and then I <= T.Nodes (X).N + 1
                 and then T.Nodes (X).Child (I) /= 0
                 and then T.Nodes (T.Nodes (X).Child (I)).N = Max_Keys;

   procedure Split_Child (T : in out Table; X : Node_Id; I : Position) is
      Y : constant Node_Id := T.Nodes (X).Child (I);
      Z : Node_Id;
   begin
      Alloc_Node (T, Z);
      T.Nodes (Z).Leaf := T.Nodes (Y).Leaf;
      T.Nodes (Z).N := Min_Keys;
      for J in 1 .. Min_Keys loop
         T.Nodes (Z).Items (J) := T.Nodes (Y).Items (J + Min_Keys + 1);
      end loop;
      if not T.Nodes (Y).Leaf then
         for J in 1 .. Min_Keys + 1 loop
            T.Nodes (Z).Child (J) := T.Nodes (Y).Child (J + Min_Keys + 1);
         end loop;
      end if;

      --  Make room in X: children first (I + 1 .. N + 1), then items.
      for J in reverse I + 1 .. T.Nodes (X).N + 1 loop
         T.Nodes (X).Child (J + 1) := T.Nodes (X).Child (J);
      end loop;
      T.Nodes (X).Child (I + 1) := Z;
      for J in reverse I .. T.Nodes (X).N loop
         T.Nodes (X).Items (J + 1) := T.Nodes (X).Items (J);
      end loop;
      T.Nodes (X).Items (I) := T.Nodes (Y).Items (Min_Keys + 1);
      T.Nodes (X).N := T.Nodes (X).N + 1;
      T.Nodes (Y).N := Min_Keys;
   end Split_Child;

   --------------------
   -- Merge_Children --
   --------------------

   --  Children I and I + 1 of X both hold exactly 3 keys. Child I
   --  absorbs X's key I and all of child I + 1; the latter is freed.
   --  X loses one key and one child.
   procedure Merge_Children (T : in out Table; X : Node_Id; I : Position)
     with Pre => I <= T.Nodes (X).N
                 and then T.Node_Free_Count < Pool_Size
                 and then T.Nodes (X).Child (I) /= 0
                 and then T.Nodes (X).Child (I + 1) /= 0
                 and then T.Nodes (T.Nodes (X).Child (I)).N = Min_Keys
                 and then T.Nodes (T.Nodes (X).Child (I + 1)).N = Min_Keys;

   procedure Merge_Children (T : in out Table; X : Node_Id; I : Position) is
      Y : constant Node_Id := T.Nodes (X).Child (I);
      Z : constant Node_Id := T.Nodes (X).Child (I + 1);
   begin
      T.Nodes (Y).Items (Min_Keys + 1) := T.Nodes (X).Items (I);
      for J in 1 .. Min_Keys loop
         T.Nodes (Y).Items (J + Min_Keys + 1) := T.Nodes (Z).Items (J);
      end loop;
      if not T.Nodes (Y).Leaf then
         for J in 1 .. Min_Keys + 1 loop
            T.Nodes (Y).Child (J + Min_Keys + 1) := T.Nodes (Z).Child (J);
         end loop;
      end if;
      T.Nodes (Y).N := Max_Keys;

      for J in I .. T.Nodes (X).N - 1 loop
         T.Nodes (X).Items (J) := T.Nodes (X).Items (J + 1);
      end loop;
      for J in I + 1 .. T.Nodes (X).N loop
         T.Nodes (X).Child (J) := T.Nodes (X).Child (J + 1);
      end loop;
      T.Nodes (X).Child (T.Nodes (X).N + 1) := 0;
      T.Nodes (X).N := T.Nodes (X).N - 1;
      Free_Node (T, Z);
   end Merge_Children;

   --  Merge_Children, then drop the root if it just became empty.
   --  Merged is the node that now holds the combined keys.
   procedure Merge_And_Shrink
     (T : in out Table; X : Node_Id; I : Position; Merged : out Node_Id)
     with Pre => I <= T.Nodes (X).N
                 and then T.Node_Free_Count < Pool_Size
                 and then T.Nodes (X).Child (I) /= 0
                 and then T.Nodes (X).Child (I + 1) /= 0
                 and then T.Nodes (T.Nodes (X).Child (I)).N = Min_Keys
                 and then T.Nodes (T.Nodes (X).Child (I + 1)).N = Min_Keys;

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

   --  Child P of X has 3 keys and its left sibling has 4 or more:
   --  rotate one key through X from the left sibling into the child.
   procedure Borrow_From_Left (T : in out Table; X : Node_Id; P : Position)
     with Pre => P >= 2 and then P <= T.Nodes (X).N + 1
                 and then T.Nodes (X).Child (P) /= 0
                 and then T.Nodes (X).Child (P - 1) /= 0
                 and then T.Nodes (T.Nodes (X).Child (P)).N = Min_Keys
                 and then T.Nodes (T.Nodes (X).Child (P - 1)).N > Min_Keys;

   procedure Borrow_From_Left (T : in out Table; X : Node_Id; P : Position) is
      C : constant Node_Id := T.Nodes (X).Child (P);
      S : constant Node_Id := T.Nodes (X).Child (P - 1);
   begin
      for J in reverse 1 .. T.Nodes (C).N loop
         T.Nodes (C).Items (J + 1) := T.Nodes (C).Items (J);
      end loop;
      if not T.Nodes (C).Leaf then
         for J in reverse 1 .. T.Nodes (C).N + 1 loop
            T.Nodes (C).Child (J + 1) := T.Nodes (C).Child (J);
         end loop;
         T.Nodes (C).Child (1) := T.Nodes (S).Child (T.Nodes (S).N + 1);
         T.Nodes (S).Child (T.Nodes (S).N + 1) := 0;
      end if;
      T.Nodes (C).Items (1) := T.Nodes (X).Items (P - 1);
      T.Nodes (X).Items (P - 1) := T.Nodes (S).Items (T.Nodes (S).N);
      T.Nodes (S).N := T.Nodes (S).N - 1;
      T.Nodes (C).N := T.Nodes (C).N + 1;
   end Borrow_From_Left;

   --  Mirror image: child P has 3 keys, its right sibling has 4 or more.
   procedure Borrow_From_Right (T : in out Table; X : Node_Id; P : Position)
     with Pre => P <= T.Nodes (X).N
                 and then T.Nodes (X).Child (P) /= 0
                 and then T.Nodes (X).Child (P + 1) /= 0
                 and then T.Nodes (T.Nodes (X).Child (P)).N = Min_Keys
                 and then T.Nodes (T.Nodes (X).Child (P + 1)).N > Min_Keys;

   procedure Borrow_From_Right (T : in out Table; X : Node_Id; P : Position) is
      C : constant Node_Id := T.Nodes (X).Child (P);
      S : constant Node_Id := T.Nodes (X).Child (P + 1);
   begin
      T.Nodes (C).Items (T.Nodes (C).N + 1) := T.Nodes (X).Items (P);
      if not T.Nodes (C).Leaf then
         T.Nodes (C).Child (T.Nodes (C).N + 2) := T.Nodes (S).Child (1);
         for J in 1 .. T.Nodes (S).N loop
            T.Nodes (S).Child (J) := T.Nodes (S).Child (J + 1);
         end loop;
         T.Nodes (S).Child (T.Nodes (S).N + 1) := 0;
      end if;
      T.Nodes (X).Items (P) := T.Nodes (S).Items (1);
      for J in 1 .. T.Nodes (S).N - 1 loop
         T.Nodes (S).Items (J) := T.Nodes (S).Items (J + 1);
      end loop;
      T.Nodes (S).N := T.Nodes (S).N - 1;
      T.Nodes (C).N := T.Nodes (C).N + 1;
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
      for I in 1 .. Pool_Size - 1 loop
         T.Node_Free (I) := Pool_Size - I + 1;   --  top of stack is node 2
      end loop;
      T.Node_Free_Count := Pool_Size - 1;          --  node 1 is the root
      for I in Slot loop
         T.Slot_Free (I) := Capacity - I + 1;      --  top of stack is slot 1
      end loop;
      T.Slot_Free_Count := Capacity;
   end Clear;

   function Count (T : Table) return Natural is (T.Total);

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
      return 0;
   end Find;

   ------------
   -- Insert --
   ------------

   procedure Insert (T : in out Table; K : Key; S : out Slot; Ok : out Boolean) is
      X : Node_Id;
      P : Position;
   begin
      if T.Total = Capacity then
         S := 1;
         Ok := False;
         return;
      end if;

      S := T.Slot_Free (T.Slot_Free_Count);
      T.Slot_Free_Count := T.Slot_Free_Count - 1;

      --  A full root is split first, which is the only way the tree
      --  grows taller.
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

      --  Walk down, splitting any full child before entering it, so
      --  the node we insert into always has room.
      X := T.Root;
      for Depth in 1 .. Max_Depth loop
         P := Lower (T.Nodes (X), K);
         if T.Nodes (X).Leaf then
            for J in reverse P .. T.Nodes (X).N loop
               T.Nodes (X).Items (J + 1) := T.Nodes (X).Items (J);
            end loop;
            T.Nodes (X).Items (P) := (K => K, S => S);
            T.Nodes (X).N := T.Nodes (X).N + 1;
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
   begin
      if Old_Slot = 0 then
         Removed := False;
         return;
      end if;

      --  Top-down delete. Every node we step into has 4+ keys (or is
      --  the root), so removing a key from it never leaves it short.
      X := T.Root;
      for Depth in 1 .. Max_Depth loop
         declare
            P   : constant Position := Lower (T.Nodes (X), Target);
            Hit : constant Boolean :=
              P <= T.Nodes (X).N and then T.Nodes (X).Items (P).K = Target;
         begin
            if T.Nodes (X).Leaf then
               --  Hit is true here: the key is present and we followed
               --  the only path it can be on.
               for J in P .. T.Nodes (X).N - 1 loop
                  T.Nodes (X).Items (J) := T.Nodes (X).Items (J + 1);
               end loop;
               T.Nodes (X).N := T.Nodes (X).N - 1;
               exit;

            elsif Hit then
               --  Key is in an internal node: replace it with its
               --  predecessor or successor and delete that instead.
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
               --  Key is below child P. Make sure that child has 4+
               --  keys before stepping into it.
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

      T.Slot_Free_Count := T.Slot_Free_Count + 1;
      T.Slot_Free (T.Slot_Free_Count) := Old_Slot;
      T.Total := T.Total - 1;
      Removed := True;
   end Remove;

   ---------
   -- Nth --
   ---------

   --  In-order walk with an explicit stack of (node, next item) frames.
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
      return (others => <>);
   end Nth;

   -----------------
   -- Well_Formed --
   -----------------

   function Well_Formed (T : Table) return Boolean is
      Stack_Size : constant := Max_Depth * (Max_Keys + 1);
      St_Node  : array (1 .. Stack_Size) of Node_Id := [others => 1];
      St_Depth : array (1 .. Stack_Size) of Positive := [others => 1];
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
            X : constant Node_Id := St_Node (Sp);
            D : constant Positive := St_Depth (Sp);
         begin
            Sp := Sp - 1;
            Nodes_Seen := Nodes_Seen + 1;
            Keys_Seen := Keys_Seen + T.Nodes (X).N;

            if X /= T.Root and then T.Nodes (X).N < Min_Keys then
               return False;
            end if;
            if X = T.Root and then not T.Nodes (X).Leaf and then T.Nodes (X).N < 1 then
               return False;
            end if;

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
               end loop;
            end if;
         end;
      end loop;

      return Sp = 0
        and then Keys_Seen = T.Total
        and then Nodes_Seen + T.Node_Free_Count = Pool_Size
        and then T.Slot_Free_Count + T.Total = Capacity;
   end Well_Formed;

end Legder.Index;
