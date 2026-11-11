--  The on-disk record: one block, one committed operation.
--
--    offset  size  field
--         0     4  Magic     16#4C444752# ("LDGR")
--         4     8  Sequence  little-endian
--        12     1  Kind      0 = Put, 1 = Delete
--        13     1  Key_Len   0 .. Max_Key
--        14     2  Val_Len   0 .. Max_Value, little-endian
--        16    32  Key       padded with zero
--        48   256  Value     padded with zero
--       304   204  Reserved  zero
--       508     4  CRC       CRC-32 of bytes 0 .. 507, little-endian
--
--  Fixed layout, one record per block. Encode never fails. Decode is
--  total: it returns Valid = False for anything that is not a record,
--  including all-zero and all-FF blocks (erased flash), and a record
--  whose CRC does not match (torn write).
--
--  PROOF TARGET
--    R1  Decode (Encode (R)) = R for every R (round trip).
--    R2  Decode never reads outside the block (index safety).
--    R3  A block that Decodes as Valid with CRC matching was produced
--        by Encode, up to CRC collision.  (R3 is documentation, not a
--        proof obligation: CRC is not a proof.)

package Legder.Record_Format with SPARK_Mode is

   Magic : constant := 16#4C444752#;

   type Op_Kind is (Put, Delete);

   type Log_Record is record
      Seq  : Sequence := 0;
      Kind : Op_Kind  := Put;
      K    : Key;
      V    : Value;   --  ignored when Kind = Delete
   end record;

   ---------------------------------------------------------------------
   --  Ghost view of a block, used only by the R1 proof. Offsets are the
   --  ones in the layout table above. See docs/r1-round-trip-decision.md.
   ---------------------------------------------------------------------

   function U32_At (B : Block; Off : Block_Offset) return CRC32 is
     (CRC32 (B (Off))
      + CRC32 (B (Off + 1)) * 2 ** 8
      + CRC32 (B (Off + 2)) * 2 ** 16
      + CRC32 (B (Off + 3)) * 2 ** 24)
   with Ghost, Pre => Off <= Block_Size - 4;
   --  Little-endian 32-bit field at Off.

   function U64_At (B : Block; Off : Block_Offset) return Sequence is
     (Sequence (B (Off))
      + Sequence (B (Off + 1)) * 2 ** 8
      + Sequence (B (Off + 2)) * 2 ** 16
      + Sequence (B (Off + 3)) * 2 ** 24
      + Sequence (B (Off + 4)) * 2 ** 32
      + Sequence (B (Off + 5)) * 2 ** 40
      + Sequence (B (Off + 6)) * 2 ** 48
      + Sequence (B (Off + 7)) * 2 ** 56)
   with Ghost, Pre => Off <= Block_Size - 8;
   --  Little-endian 64-bit field at Off.

   function Value_Length_Of (B : Block) return Natural is
     (Natural (B (14)) + 256 * Natural (B (15)))
   with Ghost;

   function Well_Formed (B : Block) return Boolean is
     (U32_At (B, 0) = Magic
      and then B (12) <= 1
      and then Natural (B (13)) <= Max_Key
      and then Value_Length_Of (B) <= Max_Value
      and then U32_At (B, 508) = CRC (B (0 .. 507)))
   with Ghost;
   --  The checks Decode makes before it accepts a block.

   function Fields_Match (B : Block; R : Log_Record) return Boolean is
     (U64_At (B, 4) = R.Seq
      and then B (12) = (if R.Kind = Put then 0 else 1)
      and then Natural (B (13)) = R.K.Length
      and then (for all I in 1 .. R.K.Length => B (15 + I) = R.K.Bytes (I))
      and then
        (if R.Kind = Put then
           Value_Length_Of (B) = R.V.Length
           and then
             (for all I in 1 .. R.V.Length => B (47 + I) = R.V.Bytes (I))))
   with Ghost;
   --  The meaningful fields of R sit at their offsets in B. Padding,
   --  reserved bytes and the value of a Delete are not mentioned.

   function Same_Record (L, R : Log_Record) return Boolean is
     (L.Seq = R.Seq
      and then L.Kind = R.Kind
      and then L.K = R.K
      and then (if L.Kind = Put then Same (L.V, R.V)))
   with Ghost;
   --  R1 equality: the meaningful fields agree (R1.2 .. R1.7).

   procedure Encode (R : Log_Record; B : out Block)
     with Global => null,
          Post   => Well_Formed (B) and then Fields_Match (B, R);

   procedure Decode (B : Block; R : out Log_Record; Valid : out Boolean)
     with Global => null,
          Post   => Valid = Well_Formed (B)
                    and then (if Valid then Fields_Match (B, R));
   --  Valid = True only when Magic, lengths and CRC all check out.
   --  When Valid = False, R is unspecified.

   procedure Round_Trip (R : Log_Record; D : out Log_Record; Valid : out Boolean)
     with Ghost,
          Global => null,
          Post   => Valid and then Same_Record (D, R);
   --  R1: Decode (Encode (R)) gives back the meaningful fields of R.
   --  Proved, not executed: it exists so that gnatprove checks R1.

end Legder.Record_Format;
