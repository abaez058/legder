--  Unit tests. Plain Ada, no framework, non-zero exit on failure.
--  Covers the record format round trip, CRC vectors, log recovery
--  under the device's fault injection, and the store API.

with Ada.Command_Line;
with Ada.Text_IO;           use Ada.Text_IO;
with Legder;                use Legder;
with Legder.Record_Format;  use Legder.Record_Format;
with Legder.RAM_Device;
with Legder.Log;
with Legder.Index;
with Legder.Store;

procedure Tests is

   package Dev renames Legder.RAM_Device;
   package L  is new Legder.Log   (Dev.Block_Count, Dev.Read, Dev.Write, Dev.Sync);
   package KV is new Legder.Store (Dev.Block_Count, Dev.Read, Dev.Write, Dev.Sync);

   Failures : Natural := 0;

   procedure Check (Name : String; Cond : Boolean) is
   begin
      Put_Line ((if Cond then "PASS  " else "FAIL  ") & Name);
      if not Cond then Failures := Failures + 1; end if;
   end Check;

   function K (S : String) return Key is
      R : Key;
   begin
      R.Length := S'Length;
      for I in S'Range loop R.Bytes (I - S'First + 1) := Byte (Character'Pos (S (I))); end loop;
      return R;
   end K;

   function V (S : String) return Value is
      R : Value;
   begin
      R.Length := S'Length;
      for I in S'Range loop R.Bytes (I - S'First + 1) := Byte (Character'Pos (S (I))); end loop;
      return R;
   end V;

   ---------------------------------------------------------------------

   procedure Test_CRC is
      Empty : constant Byte_Array (1 .. 0) := [];
      Check_Str : constant Byte_Array (1 .. 9) :=
        [16#31#, 16#32#, 16#33#, 16#34#, 16#35#, 16#36#, 16#37#, 16#38#, 16#39#];  --  "123456789"
   begin
      Check ("CRC empty", CRC (Empty) = 0);
      Check ("CRC '123456789' = CBF43926", CRC (Check_Str) = 16#CBF43926#);
   end Test_CRC;

   procedure Test_Record is
      R, D  : Log_Record;
      B     : Block;
      Valid : Boolean;
   begin
      R := (Seq => 42, Kind => Put, K => K ("key"), V => V ("value"));
      Encode (R, B);
      Decode (B, D, Valid);
      Check ("round trip valid", Valid);
      Check ("round trip seq",   D.Seq = 42);
      Check ("round trip kind",  D.Kind = Put);
      Check ("round trip key",   D.K = K ("key"));
      Check ("round trip value", Same (D.V, V ("value")));

      B (100) := B (100) xor 1;
      Decode (B, D, Valid);
      Check ("bit flip rejected", not Valid);

      B := [others => 16#FF#];
      Decode (B, D, Valid);
      Check ("erased block rejected", not Valid);

      B := [others => 0];
      Decode (B, D, Valid);
      Check ("zero block rejected", not Valid);

      R := (Seq => 1, Kind => Delete, K => K ("gone"), V => V ("ignored"));
      Encode (R, B);
      Decode (B, D, Valid);
      Check ("delete round trip", Valid and then D.Kind = Delete and then D.K = K ("gone"));
      Check ("delete carries no value", D.V.Length = 0);
   end Test_Record;

   procedure Test_Log is
      S  : L.State;
      N  : Natural;
      OK : Boolean;
      Seen : Natural := 0;
      procedure Visit (R : Log_Record) is
      begin
         Seen := Seen + 1;
         if Seen = 2 then
            Check ("scan order: second is b", R.K = K ("b"));
         end if;
      end Visit;
      procedure Scan is new L.Scan (Visit);
   begin
      Dev.Erase;
      L.Open (S, N);
      Check ("empty log opens with 0", N = 0 and S.Head = 0);

      L.Append (S, Put, K ("a"), V ("1"), OK);
      L.Append (S, Put, K ("b"), V ("2"), OK);
      L.Append (S, Put, K ("c"), V ("3"), OK);
      Check ("three appends", OK and S.Head = 3 and S.Last_Seq = 3);
      Check ("one sync per append", Dev.Syncs = 3);

      L.Open (S, N);
      Check ("reopen finds 3", N = 3 and S.Head = 3 and S.Last_Seq = 3);
      Scan (S);
      Check ("scan visits 3", Seen = 3);

      Dev.Tear_Next_Write;
      L.Append (S, Put, K ("d"), V ("4"), OK);
      L.Open (S, N);
      Check ("torn record not recovered", N = 3 and S.Head = 3);

      L.Append (S, Put, K ("e"), V ("5"), OK);
      L.Open (S, N);
      Check ("append after torn overwrites it", N = 4 and S.Last_Seq = 4);

      --  Stale record: an old valid block beyond the head with the
      --  wrong sequence must not be picked up.
      declare
         B : Block;
         R : constant Log_Record := (Seq => 99, Kind => Put, K => K ("stale"), V => V ("x"));
      begin
         Encode (R, B);
         Dev.Write (4, B); Dev.Sync;
      end;
      L.Open (S, N);
      Check ("stale valid block with wrong seq stops recovery", N = 4);
   end Test_Log;

   procedure Test_Store is
      N  : Natural;
      OK : Boolean;
      Got : Value;
      Found : Boolean;
   begin
      Dev.Erase;
      declare
         S : KV.Store;
      begin
         KV.Open (S, N);
         KV.Put (S, K ("x"), V ("1"), OK);
         KV.Put (S, K ("y"), V ("2"), OK);
         KV.Put (S, K ("x"), V ("3"), OK);
         Check ("count after overwrite", KV.Count (S) = 2);
         KV.Delete (S, K ("y"), OK);
         Check ("count after delete", KV.Count (S) = 1);
         KV.Get (S, K ("x"), Got, Found);
         Check ("get latest", Found and then Same (Got, V ("3")));
         KV.Get (S, K ("y"), Got, Found);
         Check ("get deleted", not Found);
      end;
      declare
         S : KV.Store;
      begin
         KV.Open (S, N);
         Check ("replayed 4", N = 4);
         KV.Get (S, K ("x"), Got, Found);
         Check ("survives reopen", Found and then Same (Got, V ("3")));
         Check ("count after reopen", KV.Count (S) = 1);
      end;
   end Test_Store;

   procedure Test_Capacity is
      N  : Natural;
      OK : Boolean;
      S  : KV.Store;
      Writes_Before : Natural;
   begin
      Dev.Erase;
      KV.Open (S, N);
      for I in 1 .. KV.Max_Entries loop
         KV.Put (S, K ("k" & I'Image), V ("v"), OK);
         exit when not OK;
      end loop;
      --  Max_Entries = 256 but the RAM device has 256 blocks: the log
      --  fills first. Either way Put reports failure, never raises.
      Writes_Before := Dev.Writes;
      KV.Put (S, K ("one more"), V ("v"), OK);
      Check ("put on full store fails cleanly", not OK);
      Check ("no write on refused put", Dev.Writes = Writes_Before);
   end Test_Capacity;

   procedure Test_Key_Order is
      NUL : constant Character := Character'Val (0);
      FF  : constant Character := Character'Val (255);
      Samples : constant array (1 .. 8) of Key :=
        [K (""), K ("a"), K ("a" & NUL), K ("ab"), K ("abc"), K ("b"),
         K ("b" & FF), K ("" & FF)];
      Total, Irrefl, Trans : Boolean := True;
   begin
      Check ("key <: a < b", K ("a") < K ("b"));
      Check ("key <: b not < a", not (K ("b") < K ("a")));
      Check ("key <: empty is smallest", K ("") < K ("a"));
      Check ("key <: prefix is smaller", K ("ab") < K ("abc"));
      Check ("key <: padding not significant", K ("a") < K ("a" & NUL));
      Check ("key <: first differing byte wins", K ("a" & FF) < K ("b"));
      for A of Samples loop
         if A < A then Irrefl := False; end if;
         for B of Samples loop
            --  Every pair must be less, equal, or greater, never two at once.
            if (if A < B then 1 else 0) + (if A = B then 1 else 0)
               + (if B < A then 1 else 0) /= 1
            then
               Total := False;
            end if;
            for C of Samples loop
               if A < B and then B < C and then not (A < C) then
                  Trans := False;
               end if;
            end loop;
         end loop;
      end loop;
      Check ("key <: irreflexive", Irrefl);
      Check ("key <: trichotomy with =", Total);
      Check ("key <: transitive", Trans);
   end Test_Key_Order;

   ---------------------------------------------------------------------
   --  Index tests
   ---------------------------------------------------------------------

   --  Deterministic pseudo-random numbers (no Ada.Numerics needed).
   Seed : Natural := 12345;
   function Rand (Bound : Positive) return Natural is
   begin
      Seed := (Seed * 1103 + 12345) mod 1_000_003;
      return (Seed / 7) mod Bound;
   end Rand;

   function Num_Key (N : Natural) return Key is
      Img : constant String := N'Image;
   begin
      return K ("key" & Img (Img'First + 1 .. Img'Last));
   end Num_Key;

   procedure Test_Index is
      package Ix renames Legder.Index;
      T      : Ix.Table;
      S      : Ix.Slot;
      OK     : Boolean;
      Sorted : Boolean := True;
      Slots_Unique : Boolean := True;
      Seen   : array (Ix.Slot) of Boolean := [others => False];
      Present : array (0 .. 399) of Boolean := [others => False];
      Expected : Natural := 0;
      N      : Natural;
   begin
      Ix.Clear (T);
      Check ("index: empty", Ix.Count (T) = 0 and then Ix.Find (T, K ("a")) = 0);

      --  Insert out of order, expect sorted order through Nth.
      declare
         Names : constant array (1 .. 5) of Key :=
           [K ("m"), K ("c"), K ("x"), K ("a"), K ("b")];
      begin
         for Name of Names loop
            Ix.Insert (T, Name, S, OK);
         end loop;
      end;
      Check ("index: five inserted", Ix.Count (T) = 5);
      Check ("index: sorted a", Ix.Nth (T, 1) = K ("a"));
      Check ("index: sorted b", Ix.Nth (T, 2) = K ("b"));
      Check ("index: sorted x last", Ix.Nth (T, 5) = K ("x"));

      declare
         Gone : Boolean;
      begin
         Ix.Remove (T, K ("c"), Gone);
         Check ("index: remove present", Gone and then Ix.Find (T, K ("c")) = 0);
         Ix.Remove (T, K ("zzz"), Gone);
         Check ("index: remove absent is a no-op", not Gone and then Ix.Count (T) = 4);
      end;

      --  Fill to capacity, then one more must fail cleanly.
      Ix.Clear (T);
      for I in 1 .. Ix.Capacity loop
         Ix.Insert (T, Num_Key (I), S, OK);
         exit when not OK;
         if Seen (S) then Slots_Unique := False; end if;
         Seen (S) := True;
      end loop;
      Check ("index: fills to capacity", Ix.Count (T) = Ix.Capacity and then Ix.Is_Full (T));
      Check ("index: every slot handed out once", Slots_Unique);
      Ix.Insert (T, K ("overflow"), S, OK);
      Check ("index: insert on full fails, count unchanged",
             not OK and then Ix.Count (T) = Ix.Capacity);
      declare
         Gone : Boolean;
      begin
         Ix.Remove (T, Num_Key (7), Gone);
         Ix.Insert (T, K ("overflow"), S, OK);
         Check ("index: slot recycled after remove", Gone and then OK);
      end;

      --  Random insert/remove against a boolean model.
      Ix.Clear (T);
      for Step in 1 .. 6000 loop
         N := Rand (400);
         if Rand (2) = 0 then
            if Ix.Find (T, Num_Key (N)) = 0 then
               Ix.Insert (T, Num_Key (N), S, OK);
               if OK then
                  Present (N) := True;
               end if;
            end if;
         else
            declare
               Gone : Boolean;
            begin
               Ix.Remove (T, Num_Key (N), Gone);
               Present (N) := False;
            end;
         end if;
      end loop;
      for I in Present'Range loop
         if Present (I) then Expected := Expected + 1; end if;
      end loop;
      Check ("index: random count matches model", Ix.Count (T) = Expected);
      declare
         Model_OK : Boolean := True;
      begin
         for I in Present'Range loop
            if Present (I) /= (Ix.Find (T, Num_Key (I)) /= 0) then
               Model_OK := False;
            end if;
         end loop;
         Check ("index: random membership matches model", Model_OK);
      end;
      for Pos in 2 .. Ix.Count (T) loop
         if not (Ix.Nth (T, Pos - 1) < Ix.Nth (T, Pos)) then Sorted := False; end if;
      end loop;
      Check ("index: random ops keep keys strictly sorted", Sorted);
      Check ("index: well formed after random ops", Ix.Well_Formed (T));
   end Test_Index;

   --  B-tree stress: check the tree's shape after EVERY operation, in
   --  ascending, descending and random order, including emptying the
   --  tree completely and refilling it.
   procedure Test_BTree_Stress is
      package Ix renames Legder.Index;
      T    : Ix.Table;
      S    : Ix.Slot;
      OK   : Boolean;
      Gone : Boolean;
      Shape_OK : Boolean := True;
      Order_OK : Boolean := True;
      Order : array (1 .. Ix.Capacity) of Positive;

      procedure Check_Shape is
      begin
         if not Ix.Well_Formed (T) then Shape_OK := False; end if;
      end Check_Shape;

      procedure Check_Order is
      begin
         for Pos in 2 .. Ix.Count (T) loop
            if not (Ix.Nth (T, Pos - 1) < Ix.Nth (T, Pos)) then
               Order_OK := False;
            end if;
         end loop;
      end Check_Order;

      --  Insert 1 .. Capacity in the given order, check, then remove in
      --  the given order, check.
      procedure Fill_And_Drain (Name : String) is
         Gone_All : Boolean := True;
      begin
         Shape_OK := True;
         Order_OK := True;
         Ix.Clear (T);
         for I in Order'Range loop
            Ix.Insert (T, Num_Key (Order (I)), S, OK);
            if not OK then Shape_OK := False; end if;
            Check_Shape;
         end loop;
         Check_Order;
         Check (Name & ": full, well formed, sorted",
                Ix.Count (T) = Ix.Capacity and then Shape_OK and then Order_OK);
         for I in Order'Range loop
            Ix.Remove (T, Num_Key (Order (I)), Gone);
            if not Gone then Gone_All := False; end if;
            Check_Shape;
         end loop;
         Check (Name & ": drained to empty, well formed",
                Gone_All and then Ix.Count (T) = 0 and then Shape_OK
                and then Ix.Well_Formed (T));
      end Fill_And_Drain;
   begin
      for I in Order'Range loop Order (I) := I; end loop;
      Fill_And_Drain ("btree ascending");

      for I in Order'Range loop Order (I) := Ix.Capacity + 1 - I; end loop;
      Fill_And_Drain ("btree descending");

      --  Fisher-Yates shuffle of 1 .. Capacity, a few different shuffles.
      for Round in 1 .. 4 loop
         for I in Order'Range loop Order (I) := I; end loop;
         for I in reverse 2 .. Order'Last loop
            declare
               J   : constant Positive := Rand (I) + 1;
               Tmp : constant Positive := Order (I);
            begin
               Order (I) := Order (J);
               Order (J) := Tmp;
            end;
         end loop;
         Fill_And_Drain ("btree shuffle" & Round'Image);
      end loop;

      --  Insert in one order, remove in another (forces borrows and merges
      --  in both directions).
      Shape_OK := True;
      Ix.Clear (T);
      for I in 1 .. Ix.Capacity loop
         Ix.Insert (T, Num_Key (I), S, OK);
      end loop;
      for I in 1 .. Ix.Capacity / 2 loop      --  remove the middle outwards
         Ix.Remove (T, Num_Key (Ix.Capacity / 2 + I), Gone);
         Check_Shape;
         Ix.Remove (T, Num_Key (Ix.Capacity / 2 + 1 - I), Gone);
         Check_Shape;
      end loop;
      Check ("btree middle-out removal: empty, well formed",
             Ix.Count (T) = 0 and then Shape_OK);

      --  Long random run, shape checked at every step, against a model.
      declare
         Present : array (0 .. 599) of Boolean := [others => False];
         Model_N : Natural := 0;
         Model_OK : Boolean := True;
         N : Natural;
      begin
         Shape_OK := True;
         Ix.Clear (T);
         for Step in 1 .. 20000 loop
            N := Rand (600);
            if Rand (100) < 55 then
               if Ix.Find (T, Num_Key (N)) = 0 then
                  Ix.Insert (T, Num_Key (N), S, OK);
                  if OK then
                     Present (N) := True;
                     Model_N := Model_N + 1;
                  end if;
               end if;
            else
               Ix.Remove (T, Num_Key (N), Gone);
               if Gone then
                  Present (N) := False;
                  Model_N := Model_N - 1;
               end if;
            end if;
            Check_Shape;
            if Ix.Count (T) /= Model_N then Model_OK := False; end if;
         end loop;
         for I in Present'Range loop
            if Present (I) /= (Ix.Find (T, Num_Key (I)) /= 0) then
               Model_OK := False;
            end if;
         end loop;
         Order_OK := True;
         Check_Order;
         Check ("btree 20000 random ops: shape OK at every step", Shape_OK);
         Check ("btree 20000 random ops: count and membership match model", Model_OK);
         Check ("btree 20000 random ops: keys strictly sorted", Order_OK);
      end;
   end Test_BTree_Stress;

   --  Store against a naive oracle (linear scan, the old placeholder's
   --  behaviour), then crash/reopen and compare again.
   procedure Test_Store_Random is
      type Model_Entry is record
         Live : Boolean := False;
         Val  : Natural := 0;
      end record;
      Model : array (0 .. 39) of Model_Entry;
      N     : Natural;
      OK    : Boolean;
      Got   : Value;
      Found : Boolean;
      Ops   : Natural := 0;

      function Matches (S : KV.Store) return Boolean is
         Good : Boolean := True;
         Live : Natural := 0;
      begin
         for I in Model'Range loop
            KV.Get (S, Num_Key (I), Got, Found);
            if Model (I).Live then
               Live := Live + 1;
               if not (Found and then Same (Got, V (Model (I).Val'Image))) then
                  Good := False;
               end if;
            elsif Found then
               Good := False;
            end if;
         end loop;
         return Good and then KV.Count (S) = Live;
      end Matches;
   begin
      Dev.Erase;
      declare
         S : KV.Store;
         M : Natural;
      begin
         KV.Open (S, M);
         for Step in 1 .. 200 loop
            N := Rand (40);
            if Rand (3) /= 0 then
               KV.Put (S, Num_Key (N), V (Step'Image), OK);
               if OK then Model (N) := (Live => True, Val => Step); Ops := Ops + 1; end if;
            else
               KV.Delete (S, Num_Key (N), OK);
               if OK then Model (N).Live := False; Ops := Ops + 1; end if;
            end if;
         end loop;
         Check ("store random: live state matches oracle", Matches (S));
      end;
      declare
         S : KV.Store;
         M : Natural;
      begin
         KV.Open (S, M);
         Check ("store random: replayed every committed op", M = Ops);
         Check ("store random: reopened state matches oracle", Matches (S));
      end;
   end Test_Store_Random;

begin
   Test_CRC;
   Test_Record;
   Test_Log;
   Test_Store;
   Test_Capacity;
   Test_Key_Order;
   Test_Index;
   Test_BTree_Stress;
   Test_Store_Random;
   New_Line;
   if Failures = 0 then
      Put_Line ("all tests passed");
   else
      Put_Line (Failures'Image & " failure(s)");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   end if;
end Tests;