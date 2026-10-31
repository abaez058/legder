package body Legder.RAM_Device with SPARK_Mode is

   subtype Idx is Block_Index range 0 .. Block_Count;
   type Blocks is array (Idx) of Block;

   Durable   : Blocks := [others => [others => 16#FF#]];
   Pending   : Blocks := [others => [others => 16#FF#]];
   Dirty     : array (Idx) of Boolean := [others => False];
   Tear      : Boolean := False;
   N_Writes  : Natural := 0;
   N_Syncs   : Natural := 0;
   Crash_On_Next_Sync     : Boolean := False;
   Crash_Before_Sync_Flag : Boolean := False;

   procedure Read (Index : Block_Index; Data : out Block) is
   begin
      if Index > Block_Count then
         Data := [others => 16#FF#];
      elsif Dirty (Index) then
         Data := Pending (Index);
      else
         Data := Durable (Index);
      end if;
   end Read;

   procedure Write (Index : Block_Index; Data : Block) is
   begin
      if Index > Block_Count then
         return;
      end if;

      N_Writes := N_Writes + 1;

      if Tear then
         Tear := False;

         declare
            Torn : Block := Data;
         begin
            for I in Block_Size / 2 .. Block_Size - 1 loop
               Torn (I) := Byte ((I * 7 + 13) mod 256);
            end loop;

            Pending (Index) := Torn;
         end;
      else
         Pending (Index) := Data;
      end if;

      Dirty (Index) := True;
   end Write;

   procedure Sync is
      --  Remember which crash points were requested.
      Crash_Before : constant Boolean := Crash_Before_Sync_Flag;
      Crash_After  : constant Boolean := Crash_On_Next_Sync;
   begin
      --  Consume both one-shot crash flags.
      Crash_Before_Sync_Flag := False;
      Crash_On_Next_Sync := False;

      --  Crash before pending writes become durable.
      if Crash_Before then
         Drop_Unsynced;
         raise Simulated_Crash;
      end if;

      N_Syncs := N_Syncs + 1;

      for I in Idx loop
         if Dirty (I) then
            Durable (I) := Pending (I);
            Dirty (I) := False;
         end if;
      end loop;

      --  Crash after writes become durable.
      if Crash_After then
         raise Simulated_Crash;
      end if;
   end Sync;

   procedure Erase is
   begin
      Durable := [others => [others => 16#FF#]];
      Pending := Durable;
      Dirty := [others => False];
      Tear := False;
      Crash_On_Next_Sync := False;
      Crash_Before_Sync_Flag := False;
      N_Writes := 0;
      N_Syncs := 0;
   end Erase;

   procedure Tear_Next_Write is
   begin
      Tear := True;
   end Tear_Next_Write;

   procedure Drop_Unsynced is
   begin
      for I in Idx loop
         if Dirty (I) then
            Pending (I) := Durable (I);
            Dirty (I) := False;
         end if;
      end loop;
   end Drop_Unsynced;

   procedure Crash_After_Next_Sync is
   begin
      Crash_On_Next_Sync := True;
   end Crash_After_Next_Sync;

   procedure Crash_Before_Next_Sync is
   begin
      Crash_Before_Sync_Flag := True;
   end Crash_Before_Next_Sync;
   function Writes return Natural is (N_Writes);
   function Syncs  return Natural is (N_Syncs);

end Legder.RAM_Device;
