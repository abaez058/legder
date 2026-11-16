with Ada.Directories;
with Ada.Direct_IO;
with Ada.Strings.Unbounded;

package body Legder.File_Device is

   package Block_IO is new Ada.Direct_IO (Legder.Block);
   use type Block_IO.Count;
   use Ada.Strings.Unbounded;

   File      : Block_IO.File_Type;
   File_Path : Unbounded_String;

   procedure Open (Path : String; Reset : Boolean := False) is
   begin
      Close;

      if Reset and then Ada.Directories.Exists (Path) then
         Ada.Directories.Delete_File (Path);
      end if;

      if Ada.Directories.Exists (Path) then
         Block_IO.Open (File, Block_IO.Inout_File, Path);
      else
         Block_IO.Create (File, Block_IO.Inout_File, Path);
      end if;

      File_Path := To_Unbounded_String (Path);
   end Open;

   procedure Close is
   begin
      if Block_IO.Is_Open (File) then
         Block_IO.Close (File);
      end if;
   end Close;

   procedure Erase is
   begin
      Close;
      if Length (File_Path) > 0 and then Ada.Directories.Exists (To_String (File_Path)) then
         Ada.Directories.Delete_File (To_String (File_Path));
      end if;
      File_Path := Null_Unbounded_String;
   end Erase;

   procedure Read (Index : Legder.Block_Index; Data : out Legder.Block) is
   begin
      Data := [others => 16#FF#];
      if not Block_IO.Is_Open (File) then
         raise Block_IO.Status_Error;
      end if;

      if Block_IO.Positive_Count (Natural (Index) + 1) <= Block_IO.Size (File) then
         Block_IO.Read (File, Data, Block_IO.Positive_Count (Natural (Index) + 1));
      end if;
   end Read;

   procedure Write (Index : Legder.Block_Index; Data : Legder.Block) is
   begin
      if not Block_IO.Is_Open (File) then
         raise Block_IO.Status_Error;
      end if;

      Block_IO.Write (File, Data, Block_IO.Positive_Count (Natural (Index) + 1));
   end Write;

   procedure Sync is
   begin
      if not Block_IO.Is_Open (File) then
         raise Block_IO.Status_Error;
      end if;

      Block_IO.Close (File);
      Block_IO.Open (File, Block_IO.Inout_File, To_String (File_Path));
   end Sync;

end Legder.File_Device;