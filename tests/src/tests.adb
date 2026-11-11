--  Unit tests. Plain Ada, no framework, non-zero exit on failure.
--  Covers the record format round trip, CRC vectors, log recovery
--  under the device's fault injection, and the store API.
--
--  Tests run bottom-up, in the same order as the code is layered, so
--  the first failing group points at the lowest broken layer:
--    1 Foundations      2 Record format   3 Index and B-tree  4 Log
--    5 Store            6 Hand-picked crashes
--    7 Store against an independent model   8 Crash sweep

with Ada.Command_Line;
with Ada.Text_IO;           use Ada.Text_IO;
with Legder;                use Legder;
with Legder.Record_Format;  use Legder.Record_Format;
with Legder.RAM_Device;
with Legder.Log;
with Legder.Index;
with Legder.Index.Test_Hooks;
with Legder.Store;

procedure Tests is

   package Dev renames Legder.RAM_Device;
   package L  is new Legder.Log   (Dev.Block_Count, Dev.Read, Dev.Write, Dev.Sync);
   package KV is new Legder.Store (Dev.Block_Count, Dev.Read, Dev.Write, Dev.Sync);

   Failures : Natural := 0;
   Passes   : Natural := 0;
   Group_Passes, Group_Failures : Natural := 0;

   procedure Check (Name : String; Cond : Boolean) is
   begin
      Put_Line ((if Cond then "PASS  " else "FAIL  ") & Name);
      if Cond then
         Passes := Passes + 1;
         Group_Passes := Group_Passes + 1;
      else
         Failures := Failures + 1;
         Group_Failures := Group_Failures + 1;
      end if;
   end Check;

   procedure Begin_Group (Title : String) is
   begin
      New_Line;
      Put_Line ("== " & Title & " ==");
      Group_Passes := 0;
      Group_Failures := 0;
   end Begin_Group;

   procedure End_Group is
   begin
      Put_Line ("   ->" & Group_Passes'Image & " passed,"
                & Group_Failures'Image & " failed");
   end End_Group;

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


   procedure Test_Store_Crash is
      N       : Natural;
      OK      : Boolean;
      Got     : Value;
      Found   : Boolean;
      Crashed : Boolean := False;
   begin
      Dev.Erase;

      --  Simulate a crash after the log record is durable.
      begin
         declare
            S : KV.Store;
         begin
            KV.Open (S, N);
            Dev.Crash_After_Next_Sync;
            KV.Put (S, K ("crash"), V ("durable"), OK);
         end;
      exception
         when Dev.Simulated_Crash =>
            Crashed := True;
      end;

      Check ("crash interrupts put after sync", Crashed);

      --  Opening a fresh store must replay the durable record.
      declare
         S : KV.Store;
      begin
         KV.Open (S, N);
         Check ("crash recovery replays one committed record", N = 1);

         KV.Get (S, K ("crash"), Got, Found);
         Check
           ("crash recovery preserves committed value",
            Found and then Same (Got, V ("durable")));
      end;
   end Test_Store_Crash;

   procedure Test_Store_Crash_Before_Sync is
      N       : Natural;
      OK      : Boolean;
      Got     : Value;
      Found   : Boolean;
      Crashed : Boolean := False;
   begin
      Dev.Erase;

      declare
         S : KV.Store;
      begin
         KV.Open (S, N);

         --  First write is successfully committed.
         KV.Put (S, K ("safe"), V ("persisted"), OK);
         Check ("baseline record committed", OK);

         --  Second write crashes before synchronization.
         Dev.Crash_Before_Next_Sync;

         begin
            KV.Put (S, K ("lost"), V ("pending"), OK);
         exception
            when Dev.Simulated_Crash =>
               Crashed := True;
         end;
      end;

      Check ("crash occurs before sync", Crashed);

      --  Simulate a restart using a fresh store.
      declare
         S : KV.Store;
      begin
         KV.Open (S, N);

         Check ("only committed record replayed", N = 1);

         KV.Get (S, K ("safe"), Got, Found);
         Check
           ("previous committed value survives",
            Found and then Same (Got, V ("persisted")));

         KV.Get (S, K ("lost"), Got, Found);
         Check ("unsynced record not recovered", not Found);
      end;
   end Test_Store_Crash_Before_Sync;

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

   --  Fire drill for the checker: deliberately corrupt a healthy tree
   --  (through the test-only hooks) and confirm that Well_Formed notices
   --  and that Find and Nth fail loudly instead of returning a quiet
   --  default. Without this, a checker that always said "fine" would
   --  pass every other test.
   procedure Test_Checker_Catches_Corruption is
      package Ix   renames Legder.Index;
      package Hook renames Legder.Index.Test_Hooks;
      T      : Ix.Table;
      S      : Ix.Slot;
      OK     : Boolean;
      Raised : Boolean;

      procedure Fill is
         All_OK : Boolean := True;
      begin
         Ix.Clear (T);
         for I in 1 .. 100 loop
            Ix.Insert (T, Num_Key (I), S, OK);
            if not OK then All_OK := False; end if;
         end loop;
         Check ("checker: test tree filled", All_OK and then Ix.Count (T) = 100);
      end Fill;
   begin
      Fill;
      Check ("checker: healthy tree passes", Ix.Well_Formed (T));

      Fill;
      Hook.Swap_Leftmost_Leaf_Keys (T);
      Check ("checker: unsorted keys inside a node are caught",
             not Ix.Well_Formed (T));

      Fill;
      Hook.Swap_Root_Children (T);
      Check ("checker: key ranges crossing nodes are caught",
             not Ix.Well_Formed (T));

      Fill;
      Hook.Make_Root_Cycle (T);
      Check ("checker: a node reached twice is caught", not Ix.Well_Formed (T));
      Raised := False;
      begin
         declare
            Found : constant Ix.Slot_Or_None := Ix.Find (T, K ("zzz"));
         begin
            Put_Line ("  Find unexpectedly returned" & Found'Image);
         end;
      exception
         when Program_Error => Raised := True;
      end;
      Check ("Find on a corrupt tree fails loudly", Raised);

      Fill;
      Hook.Inflate_Count (T);
      Check ("checker: count mismatch is caught", not Ix.Well_Formed (T));
      Raised := False;
      begin
         declare
            Found : constant Key := Ix.Nth (T, Ix.Count (T));
         begin
            Put_Line ("  Nth unexpectedly returned a key of length" & Found.Length'Image);
         end;
      exception
         when Program_Error => Raised := True;
      end;
      Check ("Nth on a corrupt tree fails loudly", Raised);
   end Test_Checker_Catches_Corruption;

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

   --  Crash sweep.
   --
   --  CRITERION (stated before measuring): for a fixed workload of
   --  Sweep_Ops operations, crash at every operation index P, in each
   --  of four fault modes. After Open, the store must equal the
   --  independent model after exactly the P acknowledged operations.
   --  Mode Intact_Durable may also equal the model after P + 1, because
   --  that record reached the medium before the crash (allowed, not
   --  required). Anything else is a violation. Target: 0 violations.
   --  After recovery a further Put must commit and survive a reopen.
   procedure Test_Crash_Sweep is
      Sweep_Ops  : constant := 16;
      Sweep_Keys : constant := 5;

      type Mode is (Lost_Write, Intact_Durable, Torn_Durable, Torn_Lost);

      type Model_Entry is record
         Live : Boolean := False;
         Val  : Natural := 0;
      end record;
      type Model_Array is array (0 .. Sweep_Keys - 1) of Model_Entry;

      function Key_Of (I : Natural) return Natural is ((I * 3) mod Sweep_Keys);
      function Is_Delete (I : Natural) return Boolean is (I mod 4 = 3);

      --  Independent oracle: apply the first N operations to a plain array.
      function Expect (N : Natural) return Model_Array is
         M : Model_Array;
      begin
         for I in 0 .. N - 1 loop
            if Is_Delete (I) then
               M (Key_Of (I)).Live := False;
            else
               M (Key_Of (I)) := (Live => True, Val => I);
            end if;
         end loop;
         return M;
      end Expect;

      procedure Run_Op (S : in out KV.Store; I : Natural; OK : out Boolean) is
      begin
         if Is_Delete (I) then
            KV.Delete (S, Num_Key (Key_Of (I)), OK);
         else
            KV.Put (S, Num_Key (Key_Of (I)), V (I'Image), OK);
         end if;
      end Run_Op;

      function Equals (S : KV.Store; M : Model_Array) return Boolean is
         Got   : Value;
         Found : Boolean;
         Live  : Natural := 0;
         Good  : Boolean := True;
      begin
         for I in M'Range loop
            KV.Get (S, Num_Key (I), Got, Found);
            if M (I).Live then
               Live := Live + 1;
               if not (Found and then Same (Got, V (M (I).Val'Image))) then
                  Good := False;
               end if;
            elsif Found then
               Good := False;
            end if;
         end loop;
         return Good and then KV.Count (S) = Live;
      end Equals;

      Points     : Natural := 0;
      Violations : Natural := 0;
      Tail_Bad   : Natural := 0;
      Refused    : Natural := 0;   --  acknowledged-phase ops that failed
      Replayed_Total : Natural := 0;
   begin
      for M in Mode loop
         for P in 0 .. Sweep_Ops - 1 loop
            Dev.Erase;
            Points := Points + 1;

            --  Run P operations that are acknowledged.
            declare
               S  : KV.Store;
               N  : Natural;
               OK : Boolean := False;
            begin
               KV.Open (S, N);
               Replayed_Total := Replayed_Total + N;
               for I in 0 .. P - 1 loop
                  Run_Op (S, I, OK);
                  if not OK then Refused := Refused + 1; end if;
               end loop;

               --  Arm the fault, then run operation P, which the crash
               --  interrupts. Its result is never observed.
               case M is
                  when Lost_Write     => Dev.Crash_Before_Next_Sync;
                  when Intact_Durable => Dev.Crash_After_Next_Sync;
                  when Torn_Durable   => Dev.Tear_Next_Write;
                                         Dev.Crash_After_Next_Sync;
                  when Torn_Lost      => Dev.Tear_Next_Write;
                                         Dev.Crash_Before_Next_Sync;
               end case;
               begin
                  Run_Op (S, P, OK);
               exception
                  when Dev.Simulated_Crash => OK := False;
               end;
               --  OK is deliberately not asserted: the process died here.
               if OK then Replayed_Total := Replayed_Total + 0; end if;
            end;

            --  Recover with a fresh store and compare with the oracle.
            declare
               S    : KV.Store;
               N    : Natural;
               OK   : Boolean;
               Good : Boolean;
            begin
               KV.Open (S, N);
               Good := Equals (S, Expect (P))
                 or else (M = Intact_Durable and then Equals (S, Expect (P + 1)));
               if not Good then
                  Violations := Violations + 1;
                  Put_Line ("  violation: mode " & M'Image & " crash at op" & P'Image
                            & " replayed" & N'Image);
               end if;

               --  The log must keep working after recovery.
               KV.Put (S, K ("after-crash"), V ("ok"), OK);
               declare
                  S2    : KV.Store;
                  N2    : Natural;
                  Got   : Value;
                  Found : Boolean;
               begin
                  KV.Open (S2, N2);
                  KV.Get (S2, K ("after-crash"), Got, Found);
                  if not (OK and then Found and then Same (Got, V ("ok"))) then
                     Tail_Bad := Tail_Bad + 1;
                  end if;
               end;
            end;
         end loop;
      end loop;

      Put_Line ("  crash sweep:" & Points'Image & " crash points,"
                & Violations'Image & " violations,"
                & Tail_Bad'Image & " post-recovery append failures,"
                & Refused'Image & " refused acknowledged ops");
      Check ("crash sweep: recovered state is an acknowledged prefix at every point",
             Violations = 0);
      Check ("crash sweep: log accepts and keeps a write after every recovery",
             Tail_Bad = 0);
      Check ("crash sweep: workload ops before the crash all acknowledged",
             Refused = 0 and then Replayed_Total = 0);
   end Test_Crash_Sweep;

   ---------------------------------------------------------------------
   --  Edge-case tests added during the reorganisation
   ---------------------------------------------------------------------

   --  Limits of the record format. Reseal recomputes the CRC so that the
   --  one field we damaged on purpose is the only thing wrong.
   procedure Test_Record_Limits is
      Long_K : constant Key   := K (String'(1 .. Max_Key   => 'k'));
      Long_V : constant Value := V (String'(1 .. Max_Value => 'v'));
      R, D   : Log_Record;
      B      : Block;
      Valid  : Boolean;

      procedure Reseal (X : in out Block) is
         C : constant CRC32 := CRC (X (0 .. 507));
      begin
         for I in 0 .. 3 loop
            X (508 + I) := Byte ((C / CRC32 (2) ** (8 * I)) mod 256);
         end loop;
      end Reseal;
   begin
      R := (Seq => 7, Kind => Put, K => Long_K, V => Long_V);
      Encode (R, B);
      Decode (B, D, Valid);
      Check ("limits: max-size key and value round trip",
             Valid and then D.K = Long_K and then Same (D.V, Long_V));

      R := (Seq => 8, Kind => Put, K => K (""), V => V (""));
      Encode (R, B);
      Decode (B, D, Valid);
      Check ("limits: empty key and value round trip",
             Valid and then D.K = K ("") and then Same (D.V, V ("")));

      R := (Seq => Sequence'Last, Kind => Put, K => K ("k"), V => V ("v"));
      Encode (R, B);
      Decode (B, D, Valid);
      Check ("limits: largest sequence number round trips",
             Valid and then D.Seq = Sequence'Last);

      R := (Seq => 1, Kind => Put, K => K ("k"), V => V ("v"));
      Encode (R, B);
      Reseal (B);
      Decode (B, D, Valid);
      Check ("limits: resealing a good block keeps it valid", Valid);

      Encode (R, B);
      B (0) := B (0) xor 16#FF#;
      Reseal (B);
      Decode (B, D, Valid);
      Check ("limits: wrong magic with a correct CRC is rejected", not Valid);

      Encode (R, B);
      B (12) := 2;
      Reseal (B);
      Decode (B, D, Valid);
      Check ("limits: unknown kind with a correct CRC is rejected", not Valid);

      Encode (R, B);
      B (13) := 33;
      Reseal (B);
      Decode (B, D, Valid);
      Check ("limits: key length 33 with a correct CRC is rejected", not Valid);

      Encode (R, B);
      B (14) := 1;
      B (15) := 1;
      Reseal (B);
      Decode (B, D, Valid);
      Check ("limits: value length 257 with a correct CRC is rejected", not Valid);
   end Test_Record_Limits;

   --  Unused bytes: key padding, value padding and the reserved area
   --  (offsets 304 .. 507). Encode writes them as zero; Decode does not
   --  look at them. These checks pin down the behaviour that the R1
   --  decision in docs/r1-round-trip-decision.md relies on: only the
   --  meaningful fields of a record take part in the round trip.
   procedure Test_Record_Unused_Bytes is
      R, D   : Log_Record;
      B, B2  : Block;
      Valid  : Boolean;
      Dirty  : Key;

      procedure Reseal (X : in out Block) is
         C : constant CRC32 := CRC (X (0 .. 507));
      begin
         for I in 0 .. 3 loop
            X (508 + I) := Byte ((C / CRC32 (2) ** (8 * I)) mod 256);
         end loop;
      end Reseal;
   begin
      R := (Seq => 5, Kind => Put, K => K ("abc"), V => V ("hello"));

      --  Nonzero bytes in key padding (offset 16 + 3), value padding
      --  (offset 48 + 5) and the reserved area, with the CRC recomputed.
      Encode (R, B);
      B (19)  := 16#AA#;
      B (53)  := 16#BB#;
      B (400) := 16#CC#;
      Reseal (B);
      Decode (B, D, Valid);
      Check ("unused bytes: nonzero padding with a correct CRC still decodes",
             Valid);
      Check ("unused bytes: meaningful fields unchanged by nonzero padding",
             Valid and then D.Seq = 5 and then D.Kind = Put
             and then D.K = K ("abc") and then Same (D.V, V ("hello")));

      --  The CRC covers the reserved area, so damage there without a
      --  reseal is a torn or corrupted block.
      Encode (R, B);
      B (400) := 16#CC#;
      Decode (B, D, Valid);
      Check ("unused bytes: damaged reserved byte without reseal is rejected",
             not Valid);

      --  Encode ignores whatever the caller left in the key padding.
      Dirty := K ("abc");
      Dirty.Bytes (10) := 16#EE#;
      Encode (R, B);
      Encode ((Seq => 5, Kind => Put, K => Dirty, V => V ("hello")), B2);
      Check ("unused bytes: Encode output ignores key padding", B = B2);

      --  A Delete record carries no value: a nonzero value length and
      --  value bytes on disk are ignored by Decode.
      Encode ((Seq => 6, Kind => Delete, K => K ("abc"), V => V ("")), B);
      B (14) := 5;
      B (48) := 16#DD#;
      Reseal (B);
      Decode (B, D, Valid);
      Check ("unused bytes: delete ignores a stored value length",
             Valid and then D.Kind = Delete and then D.K = K ("abc")
             and then D.V.Length = 0);
   end Test_Record_Unused_Bytes;

   --  Log edges: a completely full log, a gap in the numbering, and
   --  torn blocks that keep old data in their second half.
   procedure Test_Log_Edges is
      S  : L.State;
      N  : Natural;
      OK : Boolean;
      B  : Block;
      Writes_Before : Natural;
   begin
      Dev.Erase;
      L.Open (S, N);
      declare
         All_OK : Boolean := True;
      begin
         for I in 0 .. Natural (Dev.Block_Count) loop
            L.Append (S, Put, K ("f"), V ("x"), OK);
            if not OK then All_OK := False; end if;
         end loop;
         Check ("log edge: every block can be filled",
                All_OK and then S.Head = Natural (Dev.Block_Count) + 1);
      end;
      Check ("log edge: a filled log reports full", L.Is_Full (S));
      Writes_Before := Dev.Writes;
      L.Append (S, Put, K ("late"), V ("x"), OK);
      Check ("log edge: append on a full log is refused", not OK);
      Check ("log edge: a refused append writes nothing", Dev.Writes = Writes_Before);
      L.Open (S, N);
      Check ("log edge: a full log reopens with every record",
             N = Natural (Dev.Block_Count) + 1 and then L.Is_Full (S));

      --  A valid record whose number skips ahead must stop recovery.
      Dev.Erase;
      L.Open (S, N);
      for I in 1 .. 3 loop
         L.Append (S, Put, K ("g"), V ("x"), OK);
      end loop;
      Encode ((Seq => 5, Kind => Put, K => K ("gap"), V => V ("x")), B);
      Dev.Write (3, B);
      Dev.Sync;
      L.Open (S, N);
      Check ("log edge: a gap in the numbering stops recovery",
             N = 3 and then S.Head = 3);

      --  Torn blocks: first half new, second half old.
      Dev.Erase;
      L.Open (S, N);
      for I in 1 .. 3 loop
         L.Append (S, Put, K ("t"), V ("x"), OK);
      end loop;
      declare
         New_B, Old_B, Mixed : Block;
      begin
         Encode ((Seq => 4, Kind => Put, K => K ("new"), V => V ("n")), New_B);
         Encode ((Seq => 4, Kind => Put, K => K ("old"), V => V ("o")), Old_B);

         Mixed := New_B;
         for I in Block_Size / 2 .. Block_Size - 1 loop
            Mixed (I) := 16#FF#;
         end loop;
         Dev.Write (3, Mixed);
         Dev.Sync;
         L.Open (S, N);
         Check ("log edge: torn block with an erased second half is rejected",
                N = 3);

         Dev.Write (3, Old_B);
         Dev.Sync;
         Mixed := New_B;
         for I in Block_Size / 2 .. Block_Size - 1 loop
            Mixed (I) := Old_B (I);
         end loop;
         Dev.Write (3, Mixed);
         Dev.Sync;
         L.Open (S, N);
         Check ("log edge: torn block with an old second half is rejected",
                N = 3);

         L.Append (S, Put, K ("after"), V ("x"), OK);
         L.Open (S, N);
         Check ("log edge: a new append replaces the torn block",
                OK and then N = 4);
      end;
   end Test_Log_Edges;

   --  Store edges: deleting a key that was never stored, and a store
   --  whose log is completely full.
   procedure Test_Store_Edges is
      N     : Natural;
      OK    : Boolean;
      Got   : Value;
      Found : Boolean;
      Last  : constant Natural := Natural (Dev.Block_Count) + 1;
   begin
      Dev.Erase;
      declare
         S : KV.Store;
      begin
         KV.Open (S, N);
         KV.Delete (S, K ("ghost"), OK);
         Check ("store edge: delete of a missing key succeeds", OK);
         Check ("store edge: delete of a missing key leaves the count at 0",
                KV.Count (S) = 0);
      end;
      declare
         S : KV.Store;
      begin
         KV.Open (S, N);
         Check ("store edge: that delete is recorded in the log",
                N = 1 and then KV.Count (S) = 0);
      end;

      Dev.Erase;
      declare
         S      : KV.Store;
         All_OK : Boolean := True;
      begin
         KV.Open (S, N);
         for I in 1 .. Last loop
            KV.Put (S, K ("hot"), V (Natural'Image (I)), OK);
            if not OK then All_OK := False; end if;
         end loop;
         Check ("store edge: log filled by overwriting one key",
                All_OK and then KV.Count (S) = 1);
         KV.Put (S, K ("hot"), V ("late"), OK);
         Check ("store edge: put on a full log is refused", not OK);
         KV.Delete (S, K ("hot"), OK);
         Check ("store edge: delete on a full log is refused", not OK);
         KV.Get (S, K ("hot"), Got, Found);
         Check ("store edge: refused operations leave the value alone",
                Found and then Same (Got, V (Natural'Image (Last)))
                and then KV.Count (S) = 1);
      end;
      declare
         S : KV.Store;
      begin
         KV.Open (S, N);
         KV.Get (S, K ("hot"), Got, Found);
         Check ("store edge: same value after reopening a full log",
                N = Last and then Found and then Same (Got, V (Natural'Image (Last))));
      end;
   end Test_Store_Edges;

begin
   Begin_Group ("1. Foundations (CRC, key order)");
   Test_CRC;
   Test_Key_Order;
   End_Group;

   Begin_Group ("2. Record format");
   Test_Record;
   Test_Record_Limits;
   Test_Record_Unused_Bytes;
   End_Group;

   Begin_Group ("3. Index and B-tree");
   Test_Index;
   Test_BTree_Stress;
   Test_Checker_Catches_Corruption;
   End_Group;

   Begin_Group ("4. Log");
   Test_Log;
   Test_Log_Edges;
   End_Group;

   Begin_Group ("5. Store");
   Test_Store;
   Test_Capacity;
   Test_Store_Edges;
   End_Group;

   Begin_Group ("6. Hand-picked crashes");
   Test_Store_Crash;
   Test_Store_Crash_Before_Sync;
   End_Group;

   Begin_Group ("7. Store against an independent model");
   Test_Store_Random;
   End_Group;

   Begin_Group ("8. Crash sweep");
   Test_Crash_Sweep;
   End_Group;

   New_Line;
   Put_Line ("TOTAL:" & Passes'Image & " passed," & Failures'Image & " failed");
   if Failures = 0 then
      Put_Line ("all tests passed");
   else
      Put_Line (Failures'Image & " failure(s)");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   end if;
end Tests;