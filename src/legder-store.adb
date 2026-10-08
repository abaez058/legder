with Legder.Record_Format;
package body Legder.Store with SPARK_Mode is

   use Legder.Record_Format;

   --  Apply one record to the index and value slab. Used by Open
   --  (replay) and by Put/Delete (after commit). One code path, so
   --  replay and live updates cannot drift apart.
   procedure Apply (S : in out Store; R : Log_Record);

   procedure Apply (S : in out Store; R : Log_Record) is
      Slot : constant Legder.Index.Slot_Or_None := Legder.Index.Find (S.Idx, R.K);
   begin
      case R.Kind is
         when Put =>
            if Slot /= 0 then
               S.Values (Slot) := R.V;
            else
               declare
                  New_Slot : Legder.Index.Slot;
                  Ok       : Boolean;
               begin
                  Legder.Index.Insert (S.Idx, R.K, New_Slot, Ok);
                  if Ok then
                     S.Values (New_Slot) := R.V;
                  end if;
                  --  not Ok: index full during replay. Cannot happen
                  --  if Put refused the key when it was first written
                  --  (S3), unless Max_Entries shrank between runs.
               end;
            end if;
         when Delete =>
            if Slot /= 0 then
               declare
                  Removed : Boolean;
               begin
                  Legder.Index.Remove (S.Idx, R.K, Removed);
               end;
            end if;
      end case;
   end Apply;

   ----------
   -- Open --
   ----------

   procedure Open (S : out Store; Replayed : out Natural) is
      procedure Visit (R : Log_Record);
      procedure Visit (R : Log_Record) is
      begin
         Apply (S, R);
      end Visit;
      procedure Replay_All is new L.Scan (Visit);
   begin
      Legder.Index.Clear (S.Idx);
      S.Values := [others => <>];
      L.Open (S.Log, Replayed);
      Replay_All (S.Log);
   end Open;

   ---------
   -- Put --
   ---------

   procedure Put (S : in out Store; K : Key; V : Value; Success : out Boolean) is
   begin
      if Legder.Index.Find (S.Idx, K) = 0 and then Legder.Index.Is_Full (S.Idx) then
         Success := False;  --  S3: refuse before touching the log
         return;
      end if;
      L.Append (S.Log, Record_Format.Put, K, V, Success);
      if Success then
         Apply (S, (Seq => S.Log.Last_Seq, Kind => Record_Format.Put, K => K, V => V));
      end if;
   end Put;

   ------------
   -- Delete --
   ------------

   procedure Delete (S : in out Store; K : Key; Success : out Boolean) is
      None : Value;
   begin
      L.Append (S.Log, Record_Format.Delete, K, None, Success);
      if Success then
         Apply (S, (Seq => S.Log.Last_Seq, Kind => Record_Format.Delete, K => K, V => None));
      end if;
   end Delete;

   ---------
   -- Get --
   ---------

   procedure Get (S : Store; K : Key; V : out Value; Found : out Boolean) is
      Slot : constant Legder.Index.Slot_Or_None := Legder.Index.Find (S.Idx, K);
   begin
      if Slot = 0 then
         V := (others => <>);
         Found := False;
      else
         V := S.Values (Slot);
         Found := True;
      end if;
   end Get;

   function Count (S : Store) return Natural is (Legder.Index.Count (S.Idx));

end Legder.Store;
