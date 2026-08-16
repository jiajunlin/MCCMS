library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- IEEE-754 fused multiply-add for single (fmt=0) and double (fmt=1): computes  (a*b) +/- c  with a
-- SINGLE correct rounding of the exact product-plus-addend (no intermediate rounding of a*b).
--
--   op(1) negates the product, op(0) negates the addend:
--     00 fmadd  =  a*b + c      01 fmsub  =  a*b - c
--     10 fnmsub = -a*b + c      11 fnmadd = -a*b - c
--
-- Method (combinational, single-cycle like fadd/fmul): form the exact product significand
-- P = siga*sigb (up to 2*(MW+1) bits) with product exponent pe, and the addend significand C with
-- exponent ce. Both are placed into a 256-bit accumulator TOP-ANCHORED at 2^hi (hi = exponent of
-- the larger operand's leading bit) so the result's leading 1 lands near bit 250 and there is a
-- wide sticky region below bit 0. Bits that fall below bit 0 are OR-jammed into a per-operand
-- "tail" flag. Same-sign -> add; opposite-sign -> subtract the smaller from the larger, and when
-- the smaller operand carried a nonzero jammed tail, borrow one accumulator LSB (this makes a tie
-- like X.5 minus an infinitesimal round DOWN, as it must). The normalized 128-bit significand with
-- an exact guard/sticky is handed to the shared fpu_round core, which does subnormal/overflow and
-- the five rounding modes. Only the "far apart" regime jams a tail, and there no cancellation of
-- the leading bits is possible, so the borrow rule is exact.
--
-- Special cases (bypass the rounder): any NaN in -> qNaN (+NV if any is signaling); inf*0 -> NV,
-- qNaN; product inf with an inf addend of the opposite sign -> NV, qNaN; otherwise an infinite
-- product or infinite addend -> correctly-signed inf. Single results are NaN-boxed on exit.
-- flags: NV DZ OF UF NX (this unit contributes NV; OF/UF/NX come from the rounder).
entity fp_fma is
    port(
        is_double : in  std_logic;
        op        : in  std_logic_vector(1 downto 0);   -- 00 fmadd 01 fmsub 10 fnmsub 11 fnmadd
        rm        : in  std_logic_vector(2 downto 0);
        a_raw     : in  std_logic_vector(63 downto 0);
        b_raw     : in  std_logic_vector(63 downto 0);
        c_raw     : in  std_logic_vector(63 downto 0);
        fp_result : out std_logic_vector(63 downto 0);
        flags     : out std_logic_vector(4 downto 0)
        );
end entity;

architecture behavioral of fp_fma is

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
    constant ANCHOR : integer := 250;   -- accumulator bit that represents 2^hi

    function unbox_s(x : std_logic_vector(63 downto 0)) return std_logic_vector is
    begin
        if x(63 downto 32) = x"FFFFFFFF" then
            return x(31 downto 0);
        else
            return QNAN_S;
        end if;
    end function;

    -- Round-core driver signals
    signal r_sign   : std_logic;
    signal r_zero   : std_logic;
    signal r_exp    : integer;
    signal r_sig    : std_logic_vector(127 downto 0);
    signal r_result : std_logic_vector(63 downto 0);
    signal r_flags  : std_logic_vector(4 downto 0);

    -- Special-case bypass
    signal spec_valid : std_logic;
    signal spec_val   : std_logic_vector(63 downto 0);
    signal spec_nv    : std_logic;

begin

    process(is_double, op, rm, a_raw, b_raw, c_raw)
        variable MW, BIAS, EMIN : integer;
        variable av, bv, cv : std_logic_vector(63 downto 0);
        variable sa, sb, sc : std_logic;
        variable efa, efb, efc : std_logic_vector(10 downto 0);
        variable fra, frb, frc : unsigned(51 downto 0);
        variable za, zb, zc, ia, ib, ic, na, nb, nc, sna, snb, snc : boolean;
        variable siga, sigb, sigc : unsigned(63 downto 0);
        variable ea, eb, ec : integer;
        variable Pmag : unsigned(127 downto 0);
        variable Cmag : unsigned(63 downto 0);
        variable pe, ce : integer;
        variable sp, se : std_logic;           -- effective product / addend signs
        variable msbP, msbC : integer;
        variable pe_top, ce_top, hi : integer;
        variable shift_p, shift_c, rs, ls : integer;
        variable Pacc, Cacc, sumacc : unsigned(255 downto 0);
        variable Ptail, Ctail, sticky_extra : std_logic;
        variable eff_sub : boolean;
        variable rsign : std_logic;
        variable Msum : integer;
        variable sig128 : unsigned(127 downto 0);
        variable prod_inf, prod_nan, prod_zero : boolean;
        variable zsign : std_logic;
    begin
        if is_double = '1' then
            MW := 52; BIAS := 1023; EMIN := -1022;
            av := a_raw; bv := b_raw; cv := c_raw;
        else
            MW := 23; BIAS := 127; EMIN := -126;
            av := (63 downto 32 => '0') & unbox_s(a_raw);
            bv := (63 downto 32 => '0') & unbox_s(b_raw);
            cv := (63 downto 32 => '0') & unbox_s(c_raw);
        end if;

        if is_double = '1' then
            sa := av(63); efa := av(62 downto 52); fra := unsigned(av(51 downto 0));
            sb := bv(63); efb := bv(62 downto 52); frb := unsigned(bv(51 downto 0));
            sc := cv(63); efc := cv(62 downto 52); frc := unsigned(cv(51 downto 0));
        else
            sa := av(31); efa := "000" & av(30 downto 23); fra := resize(unsigned(av(22 downto 0)), 52);
            sb := bv(31); efb := "000" & bv(30 downto 23); frb := resize(unsigned(bv(22 downto 0)), 52);
            sc := cv(31); efc := "000" & cv(30 downto 23); frc := resize(unsigned(cv(22 downto 0)), 52);
        end if;

        za := (efa = "00000000000") and (fra = 0);
        zb := (efb = "00000000000") and (frb = 0);
        zc := (efc = "00000000000") and (frc = 0);
        ia := (efa = "11111111111") and (fra = 0);
        ib := (efb = "11111111111") and (frb = 0);
        ic := (efc = "11111111111") and (frc = 0);
        na := (efa = "11111111111") and (fra /= 0);
        nb := (efb = "11111111111") and (frb /= 0);
        nc := (efc = "11111111111") and (frc /= 0);
        sna := na and (fra(MW - 1) = '0');
        snb := nb and (frb(MW - 1) = '0');
        snc := nc and (frc(MW - 1) = '0');

        -- Effective signs after the op-encoded negations.
        sp := (sa xor sb) xor op(1);
        se := sc xor op(0);

        -- Defaults
        spec_valid <= '0';
        spec_nv    <= '0';
        spec_val   <= (others => '0');
        r_sign     <= '0';
        r_zero     <= '0';
        r_exp      <= 0;
        r_sig      <= (others => '0');

        prod_nan  := na or nb;
        prod_inf  := (ia or ib) and not (prod_nan);
        prod_zero := (za or zb) and not (ia or ib) and not prod_nan;

        ---------------------------------------------------------------
        -- Special cases (bypass the rounder)
        ---------------------------------------------------------------
        if na or nb or nc then                       -- any NaN operand
            spec_valid <= '1';
            if sna or snb or snc then spec_nv <= '1'; end if;
            if is_double = '1' then spec_val <= QNAN_D; else spec_val <= x"FFFFFFFF" & QNAN_S; end if;
        elsif (ia and zb) or (za and ib) then        -- inf * 0 -> invalid
            spec_valid <= '1'; spec_nv <= '1';
            if is_double = '1' then spec_val <= QNAN_D; else spec_val <= x"FFFFFFFF" & QNAN_S; end if;
        elsif prod_inf then                          -- infinite product
            if ic and (se /= sp) then                -- inf - inf -> invalid
                spec_valid <= '1'; spec_nv <= '1';
                if is_double = '1' then spec_val <= QNAN_D; else spec_val <= x"FFFFFFFF" & QNAN_S; end if;
            else                                     -- inf (+/- matching inf, or +/- finite) -> inf(sp)
                spec_valid <= '1';
                if is_double = '1' then spec_val <= sp & "11111111111" & (51 downto 0 => '0');
                else spec_val <= x"FFFFFFFF" & sp & "11111111" & (22 downto 0 => '0'); end if;
            end if;
        elsif ic then                                -- finite product + infinite addend -> inf(se)
            spec_valid <= '1';
            if is_double = '1' then spec_val <= se & "11111111111" & (51 downto 0 => '0');
            else spec_val <= x"FFFFFFFF" & se & "11111111" & (22 downto 0 => '0'); end if;
        else
            ---------------------------------------------------------------
            -- Finite path: build significands and unbiased exponents.
            ---------------------------------------------------------------
            if efa = "00000000000" then siga := resize(fra, 64); ea := EMIN;
            else siga := resize(fra, 64); siga(MW) := '1'; ea := to_integer(unsigned(efa)) - BIAS; end if;
            if efb = "00000000000" then sigb := resize(frb, 64); eb := EMIN;
            else sigb := resize(frb, 64); sigb(MW) := '1'; eb := to_integer(unsigned(efb)) - BIAS; end if;
            if efc = "00000000000" then sigc := resize(frc, 64); ec := EMIN;
            else sigc := resize(frc, 64); sigc(MW) := '1'; ec := to_integer(unsigned(efc)) - BIAS; end if;

            Pmag := siga * sigb;                     -- exact product significand
            pe   := ea + eb - 2 * MW;                -- value = Pmag * 2^pe
            Cmag := sigc;
            ce   := ec - MW;                         -- value = Cmag * 2^ce

            if (Pmag = 0) and (Cmag = 0) then
                -- 0 + 0: signed-zero addition rules (RDN gives -0 on sign disagreement).
                if sp = se then zsign := sp;
                elsif rm = "010" then zsign := '1';
                else zsign := '0'; end if;
                r_zero <= '1';
                r_sign <= zsign;
            else
                -- Exponent of each operand's leading 1 (top-anchor to the larger).
                msbP := 0;
                for i in 127 downto 0 loop if Pmag(i) = '1' then msbP := i; exit; end if; end loop;
                msbC := 0;
                for i in 63 downto 0 loop if Cmag(i) = '1' then msbC := i; exit; end if; end loop;
                pe_top := pe + msbP;
                ce_top := ce + msbC;
                if Pmag = 0 then hi := ce_top;
                elsif Cmag = 0 then hi := pe_top;
                elsif pe_top >= ce_top then hi := pe_top;
                else hi := ce_top; end if;

                shift_p := pe - hi + ANCHOR;
                shift_c := ce - hi + ANCHOR;

                -- Place product.
                if Pmag = 0 then
                    Pacc := (others => '0'); Ptail := '0';
                elsif shift_p >= 0 then
                    Pacc := shift_left(resize(Pmag, 256), shift_p); Ptail := '0';
                else
                    rs := -shift_p;
                    if rs >= 256 then
                        Pacc := (others => '0'); Ptail := '1';   -- Pmag /= 0 here
                    else
                        Pacc := shift_right(resize(Pmag, 256), rs);
                        if shift_left(Pacc, rs) /= resize(Pmag, 256) then Ptail := '1'; else Ptail := '0'; end if;
                    end if;
                end if;

                -- Place addend.
                if Cmag = 0 then
                    Cacc := (others => '0'); Ctail := '0';
                elsif shift_c >= 0 then
                    Cacc := shift_left(resize(Cmag, 256), shift_c); Ctail := '0';
                else
                    rs := -shift_c;
                    if rs >= 256 then
                        Cacc := (others => '0'); Ctail := '1';
                    else
                        Cacc := shift_right(resize(Cmag, 256), rs);
                        if shift_left(Cacc, rs) /= resize(Cmag, 256) then Ctail := '1'; else Ctail := '0'; end if;
                    end if;
                end if;

                eff_sub := (sp /= se);

                if not eff_sub then
                    sumacc := Pacc + Cacc;
                    sticky_extra := Ptail or Ctail;
                    rsign := sp;
                else
                    if Pacc > Cacc then              -- product larger; addend's tail (if any) borrows
                        sumacc := Pacc - Cacc;
                        if Ctail = '1' then sumacc := sumacc - 1; end if;
                        sticky_extra := Ctail;
                        rsign := sp;
                    elsif Cacc > Pacc then           -- addend larger
                        sumacc := Cacc - Pacc;
                        if Ptail = '1' then sumacc := sumacc - 1; end if;
                        sticky_extra := Ptail;
                        rsign := se;
                    else                             -- exact cancellation -> zero
                        sumacc := (others => '0');
                        sticky_extra := '0';
                        if rm = "010" then rsign := '1'; else rsign := '0'; end if;
                    end if;
                end if;

                if sumacc = 0 then
                    r_zero <= '1';
                    r_sign <= rsign;
                else
                    Msum := 0;
                    for i in 255 downto 0 loop if sumacc(i) = '1' then Msum := i; exit; end if; end loop;
                    if Msum >= 127 then
                        rs := Msum - 127;
                        sig128 := resize(shift_right(sumacc, rs), 128);
                        if shift_left(shift_right(sumacc, rs), rs) /= sumacc then
                            sticky_extra := '1';
                        end if;
                    else
                        ls := 127 - Msum;
                        sig128 := resize(shift_left(sumacc, ls), 128);
                    end if;
                    sig128(0) := sig128(0) or sticky_extra;

                    r_sign <= rsign;
                    r_exp  <= hi - ANCHOR + Msum;
                    r_sig  <= std_logic_vector(sig128);
                end if;
            end if;
        end if;
    end process;

    ROUND_INST: fpu_round
        port map(sign => r_sign, is_double => is_double, is_zero => r_zero,
                 rm => rm, exp_in => r_exp, sig_in => r_sig,
                 result => r_result, flags => r_flags);

    -- Output mux: special-case bypass vs rounded finite result (NaN-boxed for single).
    process(spec_valid, spec_val, spec_nv, r_result, r_flags, is_double)
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
