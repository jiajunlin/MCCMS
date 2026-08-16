library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- IEEE-754 floating-point add / subtract for single (fmt=0) and double (fmt=1).
--   is_sub = '1' selects fsub (negate b's sign before adding).
-- Special cases (NaN / inf) are resolved directly and bypass the rounder; finite results are
-- aligned, added/subtracted, normalized and handed to the shared fpu_round core. Single results
-- are NaN-boxed on exit. flags: NV DZ OF UF NX (NV only from sNaN or inf-inf).
entity fp_addsub is
    port(
        is_double : in  std_logic;
        is_sub    : in  std_logic;
        rm        : in  std_logic_vector(2 downto 0);
        a_raw     : in  std_logic_vector(63 downto 0);
        b_raw     : in  std_logic_vector(63 downto 0);
        fp_result : out std_logic_vector(63 downto 0);
        flags     : out std_logic_vector(4 downto 0)
        );
end entity;

architecture behavioral of fp_addsub is

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

    constant QNAN_S : std_logic_vector(31 downto 0) := x"7FC00000";
    constant QNAN_D : std_logic_vector(63 downto 0) := x"7FF8000000000000";
    constant HP     : integer := 126;   -- hidden-bit slot position in the 128-bit datapath

    function unbox_s(x : std_logic_vector(63 downto 0)) return std_logic_vector is
    begin
        if x(63 downto 32) = x"FFFFFFFF" then
            return x(31 downto 0);
        else
            return QNAN_S;
        end if;
    end function;

    -- Right shift with sticky "jamming": any bit shifted past bit 0 is OR-ed back into bit 0.
    function shr_sticky(v : unsigned(127 downto 0); n : integer) return unsigned is
        variable sh : unsigned(127 downto 0);
    begin
        if n <= 0 then
            return v;
        elsif n >= 128 then
            if v /= 0 then
                return to_unsigned(1, 128);
            else
                return to_unsigned(0, 128);
            end if;
        else
            sh := shift_right(v, n);
            if shift_left(sh, n) /= v then     -- bits were lost
                sh(0) := '1';
            end if;
            return sh;
        end if;
    end function;

    -- Round-core driver signals
    signal r_sign    : std_logic;
    signal r_zero    : std_logic;
    signal r_exp     : integer;
    signal r_sig     : std_logic_vector(127 downto 0);
    signal r_result  : std_logic_vector(63 downto 0);
    signal r_flags   : std_logic_vector(4 downto 0);

    -- Special-case (NaN/inf) bypass
    signal spec_valid : std_logic;
    signal spec_val   : std_logic_vector(63 downto 0);
    signal spec_nv    : std_logic;

begin

    -- Prepare operands / arithmetic, drive the round-core inputs and the special-case bypass.
    process(is_double, is_sub, rm, a_raw, b_raw)
        variable MW, BIAS, EMIN : integer;
        variable av, bv : std_logic_vector(63 downto 0);
        variable sa, sb : std_logic;                    -- effective signs (b flipped for sub)
        variable efa, efb : std_logic_vector(10 downto 0);
        variable fra, frb : unsigned(51 downto 0);
        variable ea, eb : integer;                      -- unbiased exponents (subnormal -> EMIN)
        variable za, zb, ia, ib, na, nb, sna, snb : boolean;
        variable siga, sigb : unsigned(63 downto 0);    -- (MW+1)-bit significand, hidden included
        variable pa, pb, aw, bw, summ : unsigned(127 downto 0);
        variable exp_max : integer;
        variable eff_sub : boolean;
        variable res_sign : std_logic;
        variable is_zero_res : boolean;
        variable L : integer;
        variable emaxa, emaxb : boolean;
    begin
        if is_double = '1' then
            MW := 52; BIAS := 1023; EMIN := -1022;
            av := a_raw; bv := b_raw;
        else
            MW := 23; BIAS := 127; EMIN := -126;
            av := (63 downto 32 => '0') & unbox_s(a_raw);
            bv := (63 downto 32 => '0') & unbox_s(b_raw);
        end if;

        -- Field extraction for the active precision
        if is_double = '1' then
            sa := av(63); efa := av(62 downto 52); fra := unsigned(av(51 downto 0));
            sb := bv(63); efb := bv(62 downto 52); frb := unsigned(bv(51 downto 0));
            emaxa := (efa = "11111111111"); emaxb := (efb = "11111111111");
        else
            sa := av(31); efa := "000" & av(30 downto 23); fra := resize(unsigned(av(22 downto 0)), 52);
            sb := bv(31); efb := "000" & bv(30 downto 23); frb := resize(unsigned(bv(22 downto 0)), 52);
            emaxa := (av(30 downto 23) = "11111111"); emaxb := (bv(30 downto 23) = "11111111");
        end if;

        if is_sub = '1' then sb := not sb; end if;      -- fsub = a + (-b)

        za := (efa = (efa'range => '0')) and (fra = 0);
        zb := (efb = (efb'range => '0')) and (frb = 0);
        ia := emaxa and (fra = 0);
        ib := emaxb and (frb = 0);
        na := emaxa and (fra /= 0);
        nb := emaxb and (frb /= 0);
        if is_double = '1' then
            sna := na and (av(51) = '0');
            snb := nb and (bv(51) = '0');
        else
            sna := na and (av(22) = '0');
            snb := nb and (bv(22) = '0');
        end if;

        -- Defaults
        spec_valid <= '0';
        spec_nv    <= '0';
        spec_val   <= (others => '0');
        r_sign     <= '0';
        r_zero     <= '0';
        r_exp      <= 0;
        r_sig      <= (others => '0');

        ---------------------------------------------------------------
        -- Special cases (bypass the rounder)
        ---------------------------------------------------------------
        if na or nb or ia or ib then
            spec_valid <= '1';
            if sna or snb then spec_nv <= '1'; end if;
            if na or nb then
                if is_double = '1' then spec_val <= QNAN_D; else spec_val <= x"FFFFFFFF" & QNAN_S; end if;
            elsif ia and ib then
                if sa /= sb then                     -- inf - inf -> invalid
                    spec_nv <= '1';
                    if is_double = '1' then spec_val <= QNAN_D; else spec_val <= x"FFFFFFFF" & QNAN_S; end if;
                else
                    if is_double = '1' then spec_val <= sa & "11111111111" & (51 downto 0 => '0');
                    else spec_val <= x"FFFFFFFF" & sa & "11111111" & (22 downto 0 => '0'); end if;
                end if;
            elsif ia then
                if is_double = '1' then spec_val <= sa & "11111111111" & (51 downto 0 => '0');
                else spec_val <= x"FFFFFFFF" & sa & "11111111" & (22 downto 0 => '0'); end if;
            else -- ib
                if is_double = '1' then spec_val <= sb & "11111111111" & (51 downto 0 => '0');
                else spec_val <= x"FFFFFFFF" & sb & "11111111" & (22 downto 0 => '0'); end if;
            end if;
        else
            ---------------------------------------------------------------
            -- Finite path
            ---------------------------------------------------------------
            -- Significand (hidden bit) and unbiased exponent; subnormal -> exp EMIN, hidden 0.
            if efa = (efa'range => '0') then
                siga := resize(fra, 64); ea := EMIN;             -- subnormal / zero
            else
                siga := resize(fra, 64); siga(MW) := '1'; ea := to_integer(unsigned(efa)) - BIAS;
            end if;
            if efb = (efb'range => '0') then
                sigb := resize(frb, 64); eb := EMIN;
            else
                sigb := resize(frb, 64); sigb(MW) := '1'; eb := to_integer(unsigned(efb)) - BIAS;
            end if;

            if ea >= eb then exp_max := ea; else exp_max := eb; end if;

            -- Place hidden bit at HP, then align the smaller operand down to exp_max.
            pa := shift_left(resize(siga, 128), HP - MW);
            pb := shift_left(resize(sigb, 128), HP - MW);
            aw := shr_sticky(pa, exp_max - ea);
            bw := shr_sticky(pb, exp_max - eb);

            eff_sub := (sa /= sb);
            is_zero_res := false;

            if not eff_sub then
                summ := aw + bw;
                res_sign := sa;
            else
                if aw = bw then
                    summ := (others => '0');
                    is_zero_res := true;
                    if rm = "010" then res_sign := '1'; else res_sign := '0'; end if;  -- RDN -> -0
                elsif aw > bw then
                    summ := aw - bw;
                    res_sign := sa;
                else
                    summ := bw - aw;
                    res_sign := sb;
                end if;
            end if;

            if is_zero_res or summ = 0 then
                r_zero <= '1';
                r_sign <= res_sign;
            else
                -- Normalize: find MSB, shift it to bit 127, exponent follows.
                L := 0;
                for i in 127 downto 0 loop
                    if summ(i) = '1' then L := i; exit; end if;
                end loop;
                r_sig  <= std_logic_vector(shift_left(summ, 127 - L));
                r_exp  <= exp_max + (L - HP);
                r_sign <= res_sign;
            end if;
        end if;
    end process;

    ROUND_INST: fpu_round
        port map(sign => r_sign, is_double => is_double, is_zero => r_zero,
                 rm => rm, exp_in => r_exp, sig_in => r_sig,
                 result => r_result, flags => r_flags);

    -- Output mux: special-case bypass vs rounded finite result (NaN-boxed for single).
    process(spec_valid, spec_val, spec_nv, r_result, r_flags, is_double)
        variable res : std_logic_vector(63 downto 0);
    begin
        if spec_valid = '1' then
            fp_result <= spec_val;
            flags     <= spec_nv & "0000";
        else
            if is_double = '1' then
                fp_result <= r_result;
            else
                fp_result <= x"FFFFFFFF" & r_result(31 downto 0);
            end if;
            flags <= r_flags;
        end if;
    end process;

end behavioral;
