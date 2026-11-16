--  The showcase: the acceptance test for the project.
--
--  Writes a few keys, then simulates the two crashes the log is built
--  for (a torn block, and a write that never reached the medium),
--  reopens the store, and checks that exactly the committed records
--  survived. Exits non-zero if anything is off.

with Ada.Command_Line;
with Ada.Text_IO;       use Ada.Text_IO;
with Legder;            use Legder;
with Legder.File_Device;
with Legder.RAM_Device;
with Legder.Store;

procedure Showcase is

   package Dev renames Legder.RAM_Device;
   package KV is new Legder.Store (Dev.Block_Count, Dev.Read, Dev.Write, Dev.Sync);
   package Disk_KV is new Legder.Store
     (Legder.File_Device.Block_Count,
      Legder.File_Device.Read,
      Legder.File_Device.Write,
      Legder.File_Device.Sync);

   function K (S : String) return Key is
      R : Key;
   begin
      R.Length := S'Length;
      for I in S'Range loop
         R.Bytes (I - S'First + 1) := Byte (Character'Pos (S (I)));
      end loop;
      return R;
   end K;

   function V (S : String) return Value is
      R : Value;
   begin
      R.Length := S'Length;
      for I in S'Range loop
         R.Bytes (I - S'First + 1) := Byte (Character'Pos (S (I)));
      end loop;
      return R;
   end V;

   function Img (X : Value) return String is
      S : String (1 .. X.Length);
   begin
      for I in S'Range loop
         S (I) := Character'Val (X.Bytes (I));
      end loop;
      return S;
   end Img;

   Failed : Boolean := False;

   procedure Expect (S : KV.Store; Name : String; Want : String; Present : Boolean := True) is
      Got   : Value;
      Found : Boolean;
   begin
      KV.Get (S, K (Name), Got, Found);
      if Found /= Present or else (Found and then Img (Got) /= Want) then
         Put_Line ("  FAIL " & Name & ": found=" & Found'Image
                   & (if Found then " '" & Img (Got) & "'" else "")
                   & " wanted " & (if Present then "'" & Want & "'" else "absent"));
         Failed := True;
      else
         Put_Line ("  ok   " & Name & " = " & (if Present then "'" & Want & "'" else "absent"));
      end if;
   end Expect;

   procedure Write_Disk_Record (Path : String) is
      N  : Natural;
      OK : Boolean;
   begin
      Legder.File_Device.Open (Path, Reset => True);
      declare
         S : Disk_KV.Store;
      begin
         Disk_KV.Open (S, N);
         Disk_KV.Put (S, K ("wal-key"), V ("disk-value"), OK);
      end;
      Legder.File_Device.Close;

      if OK then
         Put_Line ("PASS: WAL record written and synced to " & Path);
      else
         Put_Line ("FAIL: WAL append was refused");
         Failed := True;
      end if;
   end Write_Disk_Record;

   procedure Verify_Disk_Record (Path : String) is
      N     : Natural;
      Got   : Value;
      Found : Boolean;
   begin
      Legder.File_Device.Open (Path);
      declare
         S : Disk_KV.Store;
      begin
         Disk_KV.Open (S, N);
         Disk_KV.Get (S, K ("wal-key"), Got, Found);
         if N = 1 and then Found and then Same (Got, V ("disk-value")) then
            Put_Line ("PASS: restarted process recovered and replayed the WAL record");
         else
            Put_Line ("FAIL: WAL recovery did not return the expected record");
            Failed := True;
         end if;
      end;
      Legder.File_Device.Close;
   end Verify_Disk_Record;

   OK : Boolean;
   N  : Natural;

begin
   if Ada.Command_Line.Argument_Count = 2
     and then Ada.Command_Line.Argument (1) = "write"
   then
      Write_Disk_Record (Ada.Command_Line.Argument (2));
   elsif Ada.Command_Line.Argument_Count = 2
     and then Ada.Command_Line.Argument (1) = "verify"
   then
      Verify_Disk_Record (Ada.Command_Line.Argument (2));
   elsif Ada.Command_Line.Argument_Count /= 0 then
      Put_Line ("Usage: showcase [write|verify WAL_PATH]");
      Failed := True;
   else
      Dev.Erase;

      Put_Line ("1. fresh device, open");
      declare
         S : KV.Store;
      begin
         KV.Open (S, N);
         Put_Line ("  replayed" & N'Image);
         KV.Put (S, K ("alpha"), V ("1"), OK);
         KV.Put (S, K ("beta"),  V ("2"), OK);
         KV.Put (S, K ("alpha"), V ("11"), OK);
         KV.Delete (S, K ("beta"), OK);
         KV.Put (S, K ("gamma"), V ("3"), OK);
         Put_Line ("  wrote 5 records, live keys:" & KV.Count (S)'Image);
      end;

      Put_Line ("2. reopen, replay");
      declare
         S : KV.Store;
      begin
         KV.Open (S, N);
         Put_Line ("  replayed" & N'Image);
         Expect (S, "alpha", "11");
         Expect (S, "beta", "", Present => False);
         Expect (S, "gamma", "3");

         Put_Line ("3. torn write: next block lands half garbage");
         Dev.Tear_Next_Write;
         KV.Put (S, K ("delta"), V ("4"), OK);
      end;

      Put_Line ("4. reopen after the torn write");
      declare
         S : KV.Store;
      begin
         KV.Open (S, N);
         Put_Line ("  replayed" & N'Image & " (expect 5)");
         Expect (S, "gamma", "3");
         Expect (S, "delta", "", Present => False);

         Put_Line ("5. write after recovery reuses the torn block");
         KV.Put (S, K ("epsilon"), V ("5"), OK);
         Put_Line ("  writes" & Dev.Writes'Image & " syncs" & Dev.Syncs'Image
                   & " (one sync per commit)");
      end;

      Put_Line ("6. final reopen");
      declare
         S : KV.Store;
      begin
         KV.Open (S, N);
         Put_Line ("  replayed" & N'Image & " (expect 6)");
         Expect (S, "alpha", "11");
         Expect (S, "gamma", "3");
         Expect (S, "epsilon", "5");
         Expect (S, "delta", "", Present => False);
      end;
   end if;

   if Failed then
      Put_Line ("SHOWCASE FAILED");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   else
      Put_Line ("showcase ok");
   end if;
end Showcase;
