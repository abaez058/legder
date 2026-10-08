package body Legder with SPARK_Mode is

   function CRC (Data : Byte_Array) return CRC32 is
      Poly : constant CRC32 := 16#EDB88320#;
      C    : CRC32 := 16#FFFFFFFF#;
   begin
      for I in Data'Range loop
         C := C xor CRC32 (Data (I));
         for Bit in 1 .. 8 loop
            if (C and 1) = 1 then
               C := (C / 2) xor Poly;
            else
               C := C / 2;
            end if;
         end loop;
      end loop;
      return C xor 16#FFFFFFFF#;
   end CRC;

   function "<" (L, R : Key) return Boolean is
      N : constant Natural := Natural'Min (L.Length, R.Length);
   begin
      --  The first byte that differs decides the order.
      for I in 1 .. N loop
         if L.Bytes (I) /= R.Bytes (I) then
            return L.Bytes (I) < R.Bytes (I);
         end if;
      end loop;
      --  All shared bytes match, so the shorter key is smaller.
      return L.Length < R.Length;
   end "<";

end Legder;