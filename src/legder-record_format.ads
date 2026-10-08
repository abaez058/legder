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

   procedure Encode (R : Log_Record; B : out Block)
     with Global => null;

   procedure Decode (B : Block; R : out Log_Record; Valid : out Boolean)
     with Global => null;
   --  Valid = True only when Magic, lengths and CRC all check out.
   --  When Valid = False, R is unspecified.

end Legder.Record_Format;
