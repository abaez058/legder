package body Legder.Index.Test_Hooks with SPARK_Mode => Off is

   --  Two keys inside one node out of order.
   procedure Swap_Leftmost_Leaf_Keys (T : in out Table) is
      X   : Node_Id := T.Root;
      Tmp : Item;
   begin
      while not T.Nodes (X).Leaf loop
         X := T.Nodes (X).Child (1);
      end loop;
      Tmp := T.Nodes (X).Items (1);
      T.Nodes (X).Items (1) := T.Nodes (X).Items (2);
      T.Nodes (X).Items (2) := Tmp;
   end Swap_Leftmost_Leaf_Keys;

   --  Every node stays sorted, but the key ranges between nodes are wrong.
   procedure Swap_Root_Children (T : in out Table) is
      Tmp : constant Node_Ref := T.Nodes (T.Root).Child (1);
   begin
      T.Nodes (T.Root).Child (1) := T.Nodes (T.Root).Child (2);
      T.Nodes (T.Root).Child (2) := Tmp;
   end Swap_Root_Children;

   --  The root's last child points back at the root.
   procedure Make_Root_Cycle (T : in out Table) is
   begin
      T.Nodes (T.Root).Child (T.Nodes (T.Root).N + 1) := T.Root;
   end Make_Root_Cycle;

   --  Count claims one more key than the tree holds.
   procedure Inflate_Count (T : in out Table) is
   begin
      T.Total := T.Total + 1;
   end Inflate_Count;

end Legder.Index.Test_Hooks;