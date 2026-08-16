library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- IEEE-754 conversions, selected by funct5:
--   11000  float -> int    (source precision = fmt bit; rs2(0): 0 = signed W, 1 = unsigned WU)
--   11010  int   -> float  (dest   precision = fmt bit; rs2(0): 0 = signed W, 1 = unsigned WU)
--   01000  float -> float  (dest   precision = fmt bit; source is the other precision)
--
-- The two float-producing classes normalize their operand into the shared fpu_round core, so all
-- rounding-mode / overflow / underflow / inexact behaviour is inherited from it. int->double and
-- single->double widening are always exact; int->single and double->single narrowing round.
--
-- float->int rounds directly to a 32-bit integer, following the RISC-V saturation rules:
--   NaN and out-of-range results saturate to the destination bound and raise NV (never NX);
--   an in-range result with a discarded fraction raises NX. A negative value that rounds to a
--   nonzero magnitude under an unsigned conversion saturates to 0 with NV (rounds-to-zero -> NX).
-- Single FP results are NaN-boxed on exit. flags: NV DZ OF UF NX.
entity fp_cvt is
    port(
        is_double  : in  std_logic;                       -- fmt bit (dest for i2f/f2f, source for f2i)
        funct5     : in  std_logic_vector(4 downto 0);
        rs2_field  : in  std_logic_vector(4 downto 0);     -- instr(24:20): (0)=unsigned for int endpoints
        rm         : in  std_logic_vector(2 downto 0);
        a_raw      : in  std_logic_vector(63 downto 0);     -- fp operand, or integer in low 32 for i2f
        fp_result  : out std_logic_vector(63 downto 0);
        int_result : out std_logic_vector(31 downto 0);
        flags      : out std_logic_vector(4 downto 0)
        );
end entity;

architecture behavioral of fp_cvt is

    component fpu_round is
        port(
            sign      : in  std_logic;
            is_double : in  std_logic;
            is_zero   : in  std_logic;
            rm        : in  std_logic_vector(2 downto 0);
            exp_in    : in  integer;
            sig_in    : in  std_logic_vector(127 downto 0);
            result    : out std_logic_vector(63 downto 0);
            flags     : out std_logic_vector(4 downto 0)
            );
    end component;

    constant QNAN_S  : std_logic_vector(31 downto 0) := x"7FC00000";
    constant QNAN_D  : std_logic_vector(63 downto 0) := x"7FF8000000000000";
    constant INT_MAX : std_logic_vector(31 downto 0) := x"7FFFFFFF";
    constant INT_MIN : std_logic_vector(31 downto 0) := x"80000000";
    constant UINT_MAX: std_logic_vector(31 downto 0) := x"FFFFFFFF";
    constant U_2_31_M1 : unsigned(63 downto 0) := x"000000007FFFFFFF"; -- 2^31 - 1
    constant U_2_31    : unsigned(63 downto 0) := x"0000000080000000"; -- 2^31
    constant U_2_32_M1 : unsigned(63 downto 0) := x"00000000FFFFFFFF"; -- 2^32 - 1

    function unbox_s(x : std_logic_vector(63 downto 0)) return std_logic_vector is
    begin
        if x(63 downto 32) = x"FFFFFFFF" then
            return x(31 downto 0);
        else
            return QNAN_S;
        end if;
    end function;

    -- Round-core driver signals (int->float and float->float finite paths)
    signal r_sign   : std_logic;
    signal r_zero   : std_logic;
    signal r_exp    : integer;
    signal r_sig    : std_logic_vector(127 downto 0);
    signal r_result : std_logic_vector(63 downto 0);
    signal r_flags  : std_logic_vector(4 downto 0);

    -- float->float special (NaN/inf) bypass
    signal spec_valid : std_logic;
    signal spec_val   : std_logic_vector(63 downto 0);
    signal spec_nv    : std_logic;

    -- float->int result
    signal i_res   : std_logic_vector(31 downto 0);
    signal i_flags : std_logic_vector(4 downto 0);

begin

    process(is_double, funct5, rs2_field, rm, a_raw)
        -- shared source-float decode
        variable MW_s, BIAS_s : integer;
        variable src_double   : std_logic;
        variable sv           : std_logic_vector(63 downto 0);
        variable ssign        : std_logic;
        variable efv          : integer;
        variable s_fr         : unsigned(51 downto 0);
        variable is_emax      : boolean;
        variable is_nan, is_snan, is_inf, is_zero_src : boolean;
        -- int->float
        variable signed_conv  : boolean;
        variable ival         : std_logic_vector(31 downto 0);
        variable sgn          : std_logic;
        variable magu         : unsigned(63 downto 0);
        variable p            : integer;
        variable sfull        : unsigned(127 downto 0);
        -- float->float finite
        variable q            : integer;
        -- float->int
        variable eff_exp, E, shift_amt : integer;
        variable Swide        : unsigned(63 downto 0);
        variable magf         : unsigned(63 downto 0);
        variable G, stk       : std_logic;
        variable inexact, rup, ovf : boolean;
    begin
        -- Defaults
        r_sign <= '0'; r_zero <= '0'; r_exp <= 0; r_sig <= (others => '0');
        spec_valid <= '0'; spec_nv <= '0'; spec_val <= (others => '0');
        i_res <= (others => '0'); i_flags <= "00000";

        if funct5 = "11010" then
            -----------------------------------------------------------------
            -- int -> float  (operand is the integer in a_raw(31:0))
            -----------------------------------------------------------------
            signed_conv := (rs2_field(0) = '0');
            ival := a_raw(31 downto 0);
            if signed_conv and ival(31) = '1' then
                sgn  := '1';
                magu := resize(unsigned(not ival) + 1, 64);   -- two's-complement negate (32-bit)
            else
                sgn  := '0';
                magu := resize(unsigned(ival), 64);
            end if;

            if magu = 0 then
                r_zero <= '1'; r_sign <= '0';                  -- integer 0 -> +0.0
            else
                p := 0;
                for i in 31 downto 0 loop
                    if magu(i) = '1' then p := i; exit; end if;
                end loop;
                r_sig  <= std_logic_vector(shift_left(resize(magu, 128), 127 - p));
                r_exp  <= p;                                   -- value = 1.f * 2^p
                r_sign <= sgn;
            end if;

        elsif funct5 = "01000" then
            -----------------------------------------------------------------
            -- float -> float  (source precision = the other format)
            -----------------------------------------------------------------
            src_double := not is_double;
            if src_double = '1' then
                MW_s := 52; BIAS_s := 1023;
                sv := a_raw;
                ssign := sv(63); efv := to_integer(unsigned(sv(62 downto 52)));
                s_fr := unsigned(sv(51 downto 0));
                is_emax := (sv(62 downto 52) = "11111111111");
            else
                MW_s := 23; BIAS_s := 127;
                sv := (63 downto 32 => '0') & unbox_s(a_raw);
                ssign := sv(31); efv := to_integer(unsigned(sv(30 downto 23)));
                s_fr := resize(unsigned(sv(22 downto 0)), 52);
                is_emax := (sv(30 downto 23) = "11111111");
            end if;
            is_nan  := is_emax and (s_fr /= 0);
            is_snan := is_nan and (s_fr(MW_s - 1) = '0');
            is_inf  := is_emax and (s_fr = 0);
            is_zero_src := (efv = 0) and (s_fr = 0);

            if is_nan then
                spec_valid <= '1';
                if is_snan then spec_nv <= '1'; end if;
                if is_double = '1' then spec_val <= QNAN_D; else spec_val <= x"FFFFFFFF" & QNAN_S; end if;
            elsif is_inf then
                spec_valid <= '1';
                if is_double = '1' then
                    spec_val <= ssign & "11111111111" & (51 downto 0 => '0');
                else
                    spec_val <= x"FFFFFFFF" & ssign & "11111111" & (22 downto 0 => '0');
                end if;
            elsif is_zero_src then
                r_zero <= '1'; r_sign <= ssign;                -- dest +/-0 via rounder
            else
                -- Finite: normalize the source significand to bit 127, exp_in = exp of that MSB.
                if efv = 0 then
                    q := 0;
                    for i in 51 downto 0 loop
                        if s_fr(i) = '1' then q := i; exit; end if;
                    end loop;
                    r_sig <= std_logic_vector(shift_left(resize(s_fr, 128), 127 - q));
                    r_exp <= q + (1 - BIAS_s) - MW_s;          -- EMIN_s - MW_s + q
                else
                    sfull := resize(s_fr, 128);
                    sfull(MW_s) := '1';
                    r_sig <= std_logic_vector(shift_left(sfull, 127 - MW_s));
                    r_exp <= efv - BIAS_s;
                end if;
                r_sign <= ssign;
            end if;

        else
            -----------------------------------------------------------------
            -- float -> int  (funct5 = 11000; source precision = is_double)
            -----------------------------------------------------------------
            src_double := is_double;
            if src_double = '1' then
                MW_s := 52; BIAS_s := 1023;
                sv := a_raw;
                ssign := sv(63); efv := to_integer(unsigned(sv(62 downto 52)));
                s_fr := unsigned(sv(51 downto 0));
                is_emax := (sv(62 downto 52) = "11111111111");
            else
                MW_s := 23; BIAS_s := 127;
                sv := (63 downto 32 => '0') & unbox_s(a_raw);
                ssign := sv(31); efv := to_integer(unsigned(sv(30 downto 23)));
                s_fr := resize(unsigned(sv(22 downto 0)), 52);
                is_emax := (sv(30 downto 23) = "11111111");
            end if;
            is_nan  := is_emax and (s_fr /= 0);
            is_inf  := is_emax and (s_fr = 0);
            is_zero_src := (efv = 0) and (s_fr = 0);
            signed_conv := (rs2_field(0) = '0');

            if is_zero_src then
                i_res <= (others => '0'); i_flags <= "00000";
            elsif is_nan or is_inf then
                i_flags <= "10000";                            -- NV
                if signed_conv then
                    if is_nan or (is_inf and ssign = '0') then i_res <= INT_MAX; else i_res <= INT_MIN; end if;
                else
                    if is_nan or (is_inf and ssign = '0') then i_res <= UINT_MAX; else i_res <= (others => '0'); end if;
                end if;
            else
                -- Build significand and the power-of-two of its MSB.
                if efv = 0 then
                    eff_exp := 1; Swide := resize(s_fr, 64);           -- subnormal: no hidden bit
                else
                    eff_exp := efv; Swide := resize(s_fr, 64); Swide(MW_s) := '1';
                end if;
                E := eff_exp - BIAS_s;
                ovf := false; magf := (others => '0'); G := '0'; stk := '0';

                if E >= 32 then
                    ovf := true;                                       -- |value| >= 2^32
                else
                    shift_amt := MW_s - E;
                    if shift_amt <= 0 then
                        magf := shift_left(Swide, -shift_amt);         -- exact integer (E >= MW_s)
                    elsif shift_amt > 63 then
                        if Swide /= 0 then stk := '1'; end if;         -- all fraction -> integer 0
                    else
                        magf := shift_right(Swide, shift_amt);
                        G := Swide(shift_amt - 1);
                        if (Swide and (shift_left(to_unsigned(1, 64), shift_amt - 1) - 1)) /= 0 then
                            stk := '1';
                        end if;
                    end if;
                end if;
                inexact := (G = '1') or (stk = '1');

                -- Round the magnitude per rm (sign-aware for directed modes).
                case rm is
                    when "001"  => rup := false;                                   -- RTZ
                    when "010"  => rup := (ssign = '1') and inexact;               -- RDN
                    when "011"  => rup := (ssign = '0') and inexact;               -- RUP
                    when "100"  => rup := (G = '1');                               -- RMM
                    when others => rup := (G = '1') and ((stk = '1') or (magf(0) = '1')); -- RNE
                end case;
                if rup then magf := magf + 1; end if;

                -- Range check + sign, choosing NV (saturate) vs NX (inexact) per spec.
                if signed_conv then
                    if ssign = '0' then
                        if ovf or (magf > U_2_31_M1) then
                            i_res <= INT_MAX; i_flags <= "10000";
                        else
                            i_res <= std_logic_vector(magf(31 downto 0));
                            if inexact then i_flags <= "00001"; end if;
                        end if;
                    else
                        if ovf or (magf > U_2_31) then
                            i_res <= INT_MIN; i_flags <= "10000";
                        else
                            i_res <= std_logic_vector((not magf(31 downto 0)) + 1);
                            if inexact then i_flags <= "00001"; end if;
                        end if;
                    end if;
                else
                    if ssign = '1' then
                        if magf = 0 then
                            i_res <= (others => '0');                  -- rounds to 0: in range
                            if inexact then i_flags <= "00001"; end if;
                        else
                            i_res <= (others => '0'); i_flags <= "10000"; -- negative -> below 0
                        end if;
                    else
                        if ovf or (magf > U_2_32_M1) then
                            i_res <= UINT_MAX; i_flags <= "10000";
                        else
                            i_res <= std_logic_vector(magf(31 downto 0));
                            if inexact then i_flags <= "00001"; end if;
                        end if;
                    end if;
                end if;
            end if;
        end if;
    end process;

    ROUND_INST: fpu_round
        port map(sign => r_sign, is_double => is_double, is_zero => r_zero,
                 rm => rm, exp_in => r_exp, sig_in => r_sig,
                 result => r_result, flags => r_flags);

    -- FP-result output: int->float and float->float rounded value (NaN-boxed for single),
    -- with the float->float NaN/inf bypass. (float->int drives int_result, not this.)
    process(funct5, spec_valid, spec_val, r_result, is_double)
        variable boxed : std_logic_vector(63 downto 0);
    begin
        if is_double = '1' then
            boxed := r_result;
        else
            boxed := x"FFFFFFFF" & r_result(31 downto 0);
        end if;
        if funct5 = "01000" and spec_valid = '1' then
            fp_result <= spec_val;
        else
            fp_result <= boxed;
        end if;
    end process;

    int_result <= i_res;

    flags <= i_flags                 when funct5 = "11000" else               -- float->int
             (spec_nv & "0000")      when (funct5 = "01000" and spec_valid = '1') else
             r_flags;                                                          -- int->float / f2f finite

end behavioral;
