package body Legder.Record_Format with SPARK_Mode is

   Off_Magic  : constant := 0;
   Off_Seq    : constant := 4;
   Off_Kind   : constant := 12;
   Off_KLen   : constant := 13;
   Off_VLen   : constant := 14;
   Off_Key    : constant := 16;
   Off_Value  : constant := 48;
   Off_CRC    : constant := 508;

   procedure Put_U32 (B : in out Block; At_Off : Block_Offset; V : CRC32)
     with Pre  => At_Off <= Block_Size - 4,
          Post => U32_At (B, At_Off) = V
                  and then (for all J in Block_Offset =>
                              (if J < At_Off or else J > At_Off + 3
                               then B (J) = B'Old (J)));
   function Get_U32 (B : Block; At_Off : Block_Offset) return CRC32
     with Pre  => At_Off <= Block_Size - 4,
          Post => Get_U32'Result = U32_At (B, At_Off);
   procedure Put_U64 (B : in out Block; At_Off : Block_Offset; V : Sequence)
     with Pre  => At_Off <= Block_Size - 8,
          Post => U64_At (B, At_Off) = V
                  and then (for all J in Block_Offset =>
                              (if J < At_Off or else J > At_Off + 7
                               then B (J) = B'Old (J)));
   function Get_U64 (B : Block; At_Off : Block_Offset) return Sequence
     with Pre  => At_Off <= Block_Size - 8,
          Post => Get_U64'Result = U64_At (B, At_Off);

   procedure Put_U32 (B : in out Block; At_Off : Block_Offset; V : CRC32) is
      X : CRC32 := V;
   begin
      for I in 0 .. 3 loop
         B (At_Off + I) := Byte (X and 16#FF#);
         X := X / 256;
      end loop;
   end Put_U32;

   function Get_U32 (B : Block; At_Off : Block_Offset) return CRC32 is
      X : CRC32 := 0;
   begin
      for I in reverse 0 .. 3 loop
         X := X * 256 + CRC32 (B (At_Off + I));
      end loop;
      return X;
   end Get_U32;

   procedure Put_U64 (B : in out Block; At_Off : Block_Offset; V : Sequence) is
      X : Sequence := V;
   begin
      for I in 0 .. 7 loop
         B (At_Off + I) := Byte (X and 16#FF#);
         X := X / 256;
      end loop;
   end Put_U64;

   function Get_U64 (B : Block; At_Off : Block_Offset) return Sequence is
      X : Sequence := 0;
   begin
      for I in reverse 0 .. 7 loop
         X := X * 256 + Sequence (B (At_Off + I));
      end loop;
      return X;
   end Get_U64;

   ------------
   -- Encode --
   ------------

   procedure Encode (R : Log_Record; B : out Block) is
   begin
      B := [others => 0];
      Put_U32 (B, Off_Magic, Magic);
      Put_U64 (B, Off_Seq, R.Seq);
      B (Off_Kind) := (case R.Kind is when Put => 0, when Delete => 1);
      B (Off_KLen) := Byte (R.K.Length);
      B (Off_VLen)     := Byte (R.V.Length mod 256);
      B (Off_VLen + 1) := Byte (R.V.Length / 256);
      for I in 1 .. R.K.Length loop
         B (Off_Key + I - 1) := R.K.Bytes (I);
         pragma Loop_Invariant
           (for all J in 1 .. I => B (Off_Key + J - 1) = R.K.Bytes (J));
         pragma Loop_Invariant
           (for all J in 0 .. Off_Key - 1 => B (J) = B'Loop_Entry (J));
      end loop;
      if R.Kind = Put then
         for I in 1 .. R.V.Length loop
            B (Off_Value + I - 1) := R.V.Bytes (I);
            pragma Loop_Invariant
              (for all J in 1 .. I => B (Off_Value + J - 1) = R.V.Bytes (J));
            pragma Loop_Invariant
              (for all J in 0 .. Off_Value - 1 => B (J) = B'Loop_Entry (J));
         end loop;
      end if;
      pragma Assert (Fields_Match (B, R));
      declare
         Body_Bytes : constant Byte_Array (0 .. Off_CRC - 1) := B (0 .. Off_CRC - 1);
      begin
         Put_U32 (B, Off_CRC, CRC (Body_Bytes));
         pragma Assert (B (0 .. Off_CRC - 1) = Body_Bytes);
      end;
   end Encode;

   ------------
   -- Decode --
   ------------

   procedure Decode (B : Block; R : out Log_Record; Valid : out Boolean) is
      KL : constant Natural := Natural (B (Off_KLen));
      VL : constant Natural := Natural (B (Off_VLen)) + 256 * Natural (B (Off_VLen + 1));
   begin
      R := (others => <>);
      Valid := False;
      if Get_U32 (B, Off_Magic) /= Magic then
         return;
      end if;
      if B (Off_Kind) > 1 or else KL > Max_Key or else VL > Max_Value then
         return;
      end if;
      --  From here on the lengths are in range, so the copy loops below
      --  stay inside the block and inside R.K.Bytes and R.V.Bytes.
      pragma Assert (KL in Key_Length and then VL in Value_Length);
      if Get_U32 (B, Off_CRC) /= CRC (B (0 .. Off_CRC - 1)) then
         return;
      end if;
      R.Seq  := Get_U64 (B, Off_Seq);
      R.Kind := (if B (Off_Kind) = 0 then Put else Delete);
      R.K.Length := KL;
      for I in 1 .. KL loop
         R.K.Bytes (I) := B (Off_Key + I - 1);
         pragma Loop_Invariant
           (for all J in 1 .. I => R.K.Bytes (J) = B (Off_Key + J - 1));
      end loop;
      if R.Kind = Put then
         R.V.Length := VL;
         for I in 1 .. VL loop
            R.V.Bytes (I) := B (Off_Value + I - 1);
            pragma Loop_Invariant
              (for all J in 1 .. I => R.V.Bytes (J) = B (Off_Value + J - 1));
         end loop;
      end if;
      Valid := True;
   end Decode;

   ----------------
   -- Round_Trip --
   ----------------

   procedure Round_Trip (R : Log_Record; D : out Log_Record; Valid : out Boolean) is
      B : Block;
   begin
      Encode (R, B);
      Decode (B, D, Valid);
      pragma Assert (Valid);                                        --  R1.1
      pragma Assert (D.Seq = R.Seq);                                --  R1.2
      pragma Assert (D.Kind = R.Kind);                              --  R1.3
      pragma Assert (D.K.Length = R.K.Length);                      --  R1.4
      pragma Assert
        (for all I in 1 .. R.K.Length => D.K.Bytes (I) = R.K.Bytes (I));  --  R1.5
      pragma Assert (if R.Kind = Put then D.V.Length = R.V.Length);  --  R1.6
      pragma Assert
        (if R.Kind = Put then
           (for all I in 1 .. R.V.Length => D.V.Bytes (I) = R.V.Bytes (I)));  --  R1.7
   end Round_Trip;

end Legder.Record_Format;
