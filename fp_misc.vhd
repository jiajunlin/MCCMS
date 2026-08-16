library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Non-arithmetic FP operations (no rounding required): sign injection (fsgnj/n/x),
-- fmin/fmax, comparisons (feq/flt/fle) and fclass. Handles both single (fmt=0) and double
-- (fmt=1). Single operands are NaN-unboxed on entry (a non-boxed single is treated as the
-- canonical qNaN); single results are NaN-boxed on exit. Produces an FP result (sgnj/min/max),
-- an integer result (cmp/class) and the NV exception flag.
entity fp_misc is
    port(
        is_double  : in  std_logic;
        funct5     : in  std_logic_vector(4 downto 0); -- funct7(6:2): op group
        funct3     : in  std_logic_vector(2 downto 0);
        a_raw      : in  std_logic_vector(63 downto 0);
        b_raw      : in  std_logic_vector(63 downto 0);
        fp_result  : out std_logic_vector(63 downto 0);
        int_result : out std_logic_vector(31 downto 0);
        flags      : out std_logic_vector(4 downto 0)  -- NV DZ OF UF NX
        );
end entity;

architecture behavioral of fp_misc is

    constant QNAN_S : std_logic_vector(31 downto 0) := x"7FC00000";
    constant QNAN_D : std_logic_vector(63 downto 0) := x"7FF8000000000000";

    -- Unbox a single: valid NaN-box (upper 32 all ones) -> low 32; otherwise canonical qNaN.
    function unbox_s(x : std_logic_vector(63 downto 0)) return std_logic_vector is
    begin
        if x(63 downto 32) = x"FFFFFFFF" then
            return x(31 downto 0);
        else
            return QNAN_S;
        end if;
    end function;

begin

    process(is_double, funct5, funct3, a_raw, b_raw)
        -- Operand working values (single uses low 32 bits)
        variable av, bv : std_logic_vector(63 downto 0);
        variable sa, sb : std_logic;
        variable expa, expb : unsigned(11 downto 0);
        variable fraca, fracb : unsigned(51 downto 0);
        variable maga, magb : unsigned(62 downto 0); -- magnitude = exp:frac as one unsigned
        variable za, zb, ia, ib, na, nb, sna, snb : boolean; -- zero/inf/nan/snan per operand
        variable eq, lt : boolean;
        variable nv : std_logic;
        variable res_fp : std_logic_vector(63 downto 0);
        variable res_int : std_logic_vector(31 downto 0);
        variable sgn : std_logic;
        variable cls : std_logic_vector(9 downto 0);
        variable pick_a : boolean;

        -- Decode one operand's fields/classes for the active precision.
        procedure classify(v : std_logic_vector(63 downto 0);
                            variable s : out std_logic;
                            variable ex : out unsigned(11 downto 0);
                            variable fr : out unsigned(51 downto 0);
                            variable mg : out unsigned(62 downto 0);
                            variable is_z, is_i : out boolean;
                            variable is_n : inout boolean;
                            variable is_sn : out boolean) is
            variable e : unsigned(11 downto 0);
            variable f : unsigned(51 downto 0);
            variable emax : boolean;
        begin
            if is_double = '1' then
                s := v(63);
                e := resize(unsigned(v(62 downto 52)), 12);
                f := unsigned(v(51 downto 0));
                mg := unsigned(v(62 downto 0));
                emax := (v(62 downto 52) = "11111111111");
            else
                s := v(31);
                e := resize(unsigned(v(30 downto 23)), 12);
                f := resize(unsigned(v(22 downto 0)), 52);
                mg := resize(unsigned(v(30 downto 0)), 63);
                emax := (v(30 downto 23) = "11111111");
            end if;
            ex := e; fr := f;
            is_z := (e = 0) and (f = 0);
            is_i := emax and (f = 0);
            is_n := emax and (f /= 0);
            -- signaling NaN: NaN with the top fraction bit clear
            if is_double = '1' then
                is_sn := is_n and (v(51) = '0');
            else
                is_sn := is_n and (v(22) = '0');
            end if;
        end procedure;

    begin
        -- Select / unbox operands
        if is_double = '1' then
            av := a_raw; bv := b_raw;
        else
            av := (63 downto 32 => '0') & unbox_s(a_raw);
            bv := (63 downto 32 => '0') & unbox_s(b_raw);
        end if;

        classify(av, sa, expa, fraca, maga, za, ia, na, sna);
        classify(bv, sb, expb, fracb, magb, zb, ib, nb, snb);

        -- Ordered comparison (valid only when neither is NaN)
        if za and zb then
            eq := true;  lt := false;                 -- +0 == -0
        elsif sa /= sb then
            eq := false; lt := (sa = '1');             -- negative < positive
        elsif sa = '0' then
            eq := (maga = magb); lt := (maga < magb);
        else
            eq := (maga = magb); lt := (maga > magb);  -- both negative: larger mag is smaller
        end if;

        nv := '0';
        res_fp := (others => '0');
        res_int := (others => '0');

        case funct5 is
            ------------------------------------------------------------------
            when "00100" =>  -- fsgnj / fsgnjn / fsgnjx
                case funct3 is
                    when "000"  => sgn := sb;            -- fsgnj
                    when "001"  => sgn := not sb;        -- fsgnjn
                    when others => sgn := sa xor sb;     -- fsgnjx
                end case;
                if is_double = '1' then
                    res_fp := sgn & av(62 downto 0);
                else
                    res_fp := (63 downto 32 => '0') & sgn & av(30 downto 0);
                end if;

            ------------------------------------------------------------------
            when "00101" =>  -- fmin / fmax
                -- Signaling NaN on either input raises NV; NaN inputs return the number.
                if sna or snb then nv := '1'; end if;
                if na and nb then                -- both NaN -> canonical qNaN
                    if is_double = '1' then res_fp := QNAN_D; else res_fp := (63 downto 32 => '0') & QNAN_S; end if;
                elsif na then
                    res_fp := bv;                -- a is NaN -> b
                elsif nb then
                    res_fp := av;                -- b is NaN -> a
                else
                    if funct3 = "000" then       -- fmin
                        pick_a := lt or (eq and sa = '1');
                    else                          -- fmax
                        pick_a := (not lt and not eq) or (eq and sa = '0');
                    end if;
                    if pick_a then res_fp := av; else res_fp := bv; end if;
                end if;

            ------------------------------------------------------------------
            when "10100" =>  -- feq / flt / fle  (integer result)
                case funct3 is
                    when "010" =>  -- feq: quiet, signals only on sNaN
                        if sna or snb then nv := '1'; end if;
                        if na or nb then res_int := (others => '0');
                        elsif eq then res_int := x"00000001"; end if;
                    when "001" =>  -- flt: signaling, NV on any NaN
                        if na or nb then nv := '1'; res_int := (others => '0');
                        elsif lt then res_int := x"00000001"; end if;
                    when others => -- fle: signaling, NV on any NaN
                        if na or nb then nv := '1'; res_int := (others => '0');
                        elsif lt or eq then res_int := x"00000001"; end if;
                end case;

            ------------------------------------------------------------------
            when "11100" =>  -- fclass (funct3=001); integer one-hot result
                cls := (others => '0');
                if na then
                    if sna then cls(8) := '1'; else cls(9) := '1'; end if;
                elsif ia then
                    if sa = '1' then cls(0) := '1'; else cls(7) := '1'; end if;
                elsif za then
                    if sa = '1' then cls(3) := '1'; else cls(4) := '1'; end if;
                elsif expa = 0 then            -- subnormal (exp=0, frac/=0)
                    if sa = '1' then cls(2) := '1'; else cls(5) := '1'; end if;
                else                            -- normal
                    if sa = '1' then cls(1) := '1'; else cls(6) := '1'; end if;
                end if;
                res_int := (31 downto 10 => '0') & cls;

            when others =>
                null;
        end case;

        -- Single-precision FP results are NaN-boxed into the upper 32 bits (upper = all ones).
        -- (For integer-result ops fp_result is unused, so boxing it is harmless.)
        if is_double = '0' then
            res_fp := x"FFFFFFFF" & res_fp(31 downto 0);
        end if;

        fp_result  <= res_fp;
        int_result <= res_int;
        flags      <= nv & "0000";
    end process;

end behavioral;