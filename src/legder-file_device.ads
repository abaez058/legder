package Legder.File_Device with SPARK_Mode => Off is

   Block_Count : constant Legder.Block_Index := 255;

   procedure Open (Path : String; Reset : Boolean := False);
   procedure Close;
   procedure Erase;

   procedure Read (Index : Legder.Block_Index; Data : out Legder.Block);
   procedure Write (Index : Legder.Block_Index; Data : Legder.Block);
   procedure Sync;

end Legder.File_Device;