package Legder.Index.Test_Hooks with SPARK_Mode => Off is
   --  Test-only: deliberately corrupt a Table so tests can prove that
   --  Well_Formed and the loud failures really fire.
   procedure Swap_Leftmost_Leaf_Keys (T : in out Table);
   procedure Swap_Root_Children (T : in out Table);
   procedure Make_Root_Cycle (T : in out Table);
   procedure Inflate_Count (T : in out Table);
end Legder.Index.Test_Hooks;