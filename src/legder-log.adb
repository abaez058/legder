package body Legder.Log with SPARK_Mode is

   ----------
   -- Open --
   ----------

   procedure Open (S : out State; Recovered : out Natural) is
      B     : Block;
      R     : Log_Record;
      Valid : Boolean;
      Seq   : Sequence := 0;
      Head  : Position := 0;
   begin
      Recovered := 0;
      for I in Block_Index range 0 .. Block_Count loop
         pragma Loop_Invariant (Head = Natural (I));
         pragma Loop_Invariant (Recovered = Natural (I));
         Read (I, B);
         Decode (B, R, Valid);
         exit when not Valid or else R.Seq /= Seq + 1;
         Seq := R.Seq;
         Head := Head + 1;
         Recovered := Recovered + 1;
      end loop;
      S := (Head => Head, Last_Seq => Seq, Opened => True);
   end Open;

   ------------
   -- Append --
   ------------

   procedure Append (S : in out State; Kind : Op_Kind; K : Key; V : Value; Success : out Boolean) is
      B : Block;
      R : Log_Record;
   begin
      if Is_Full (S) then
         Success := False;
         return;
      end if;
      R := (Seq => S.Last_Seq + 1, Kind => Kind, K => K, V => V);
      Encode (R, B);
      Write (Block_Index (S.Head), B);
      Sync;
      S.Head := S.Head + 1;
      S.Last_Seq := R.Seq;
      Success := True;
   end Append;

   ----------
   -- Scan --
   ----------

   procedure Scan (S : State) is
      B     : Block;
      R     : Log_Record;
      Valid : Boolean;
   begin
      for P in 0 .. S.Head - 1 loop
         Read (Block_Index (P), B);
         Decode (B, R, Valid);
         --  Open established every block below Head is valid and
         --  consecutive. A False here means the device changed under
         --  us; stop rather than replay garbage.
         exit when not Valid;
         Visit (R);
      end loop;
   end Scan;

end Legder.Log;
