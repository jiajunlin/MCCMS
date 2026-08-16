library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Shared IEEE-754 normalize + round core, reused by fadd/fsub, fmul (and later fma/cvt/div/sqrt).
--
-- Contract from the arithmetic unit (finite, non-zero magnitude, or exact zero via is_zero):
--   The unrounded magnitude is  sig_in * 2^(exp_in - 127), where sig_in is a 128-bit unsigned
--   significand NORMALIZED so its leading 1 sits at bit 127 (i.e. value = 1.f * 2^exp_in with
--   exp_in the true unbiased exponent of that leading one). All bits below the kept field carry
--   the exact remainder so guard/sticky are exact.
--
-- The core keeps (MW+1) bits (hidden + fraction), rounds per `rm` using a guard bit G and a
-- sticky T (OR of everything below G), handles carry-out, overflow (-> inf / max-normal per mode
-- and sign) and gradual underflow (right-shift into the subnormal range, exponent field 0).
-- Tininess is detected AFTER rounding (RISC-V / Spike / SoftFloat convention): a value that
-- rounds up to the smallest normal is NOT flagged underflow.
--
-- rm: 000 RNE, 001 RTZ, 010 RDN(-inf), 011 RUP(+inf), 100 RMM(nearest, ties to max magnitude).
-- flags: NV DZ OF UF NX  (this core only ever sets OF/UF/NX; NV/DZ come from the caller).
entity fpu_round is
    port(
        sign      : in  std_logic;
        is_double : in  std_logic;
        is_zero   : in  std_logic;                       -- exact zero result -> emit +/-0, no flags
        rm        : in  std_logic_vector(2 downto 0);
        exp_in    : in  integer;                         -- unbiased exponent of bit 127
        sig_in    : in  std_logic_vector(127 downto 0);  -- normalized: bit 127 = 1 when non-zero
        result    : out std_logic_vector(63 downto 0);   -- single packed in low 32 (caller boxes)
        flags     : out std_logic_vector(4 downto 0)     -- NV DZ OF UF NX
        );
end entity;

architecture behavioral of fpu_round is
begin
    process(sign, is_double, is_zero, rm, exp_in, sig_in)
        variable MW        : integer;      -- mantissa (fraction) width
        variable BIAS      : integer;
        variable EMIN      : integer;      -- minimum normal unbiased exponent
        variable EXPMAX    : integer;      -- all-ones exponent field (inf/NaN)
        variable sig       : unsigned(127 downto 0);
        variable shifted   : unsigned(127 downto 0);
        variable d         : integer;      -- right-shift for subnormal alignment
        variable gpos      : integer;      -- guard-bit index
        variable keep      : unsigned(63 downto 0);
        variable mant      : unsigned(63 downto 0);
        variable G, Tk     : std_logic;
        variable lsb       : std_logic;
        variable inexact   : boolean;
        variable roundUp   : boolean;
        variable base_exp  : integer;      -- biased exponent (normal path)
        variable exp_field : integer;
        variable frac      : unsigned(51 downto 0);
        variable of_f, uf_f, nx_f : std_logic;
        variable emit_inf  : boolean;
        variable res       : std_logic_vector(63 downto 0);
    begin
        -- Precision parameters
        if is_double = '1' then
            MW := 52; BIAS := 1023; EMIN := -1022; EXPMAX := 2047;
        else
            MW := 23; BIAS := 127;  EMIN := -126;  EXPMAX := 255;
        end if;

        of_f := '0'; uf_f := '0'; nx_f := '0';
        res  := (others => '0');

        if is_zero = '1' then
            -- Exact zero: sign only (caller decides sign, e.g. -0 for x-x under RDN).
            if is_double = '1' then
                res(63) := sign;
            else
                res(31) := sign;
            end if;
            result <= res;
            flags  <= "00000";
        else

        sig  := unsigned(sig_in);
        gpos := 127 - (MW + 1);            -- guard bit position (just below kept LSB)

        -- Subnormal alignment: shift right so the hidden-bit slot represents 2^EMIN.
        if exp_in < EMIN then
            d := EMIN - exp_in;
            base_exp := 0;                 -- subnormal candidate
        else
            d := 0;
            base_exp := exp_in + BIAS;     -- normal candidate (>= 1)
        end if;
        if d < 0 then d := 0; end if;
        if d > 200 then d := 200; end if;  -- clamp: everything shifted out

        shifted := shift_right(sig, d);

        -- Kept significand, guard, sticky (sticky folds in bits lost by the d-shift).
        keep := resize(shifted(127 downto gpos + 1), 64);
        G    := shifted(gpos);
        if shifted(gpos - 1 downto 0) /= 0 then
            Tk := '1';
        else
            Tk := '0';
        end if;
        if sig /= shift_left(shifted, d) then
            Tk := '1';                     -- bits pushed off the bottom by the subnormal shift
        end if;

        lsb     := keep(0);
        inexact := (G = '1') or (Tk = '1');

        -- Rounding decision
        case rm is
            when "001" => roundUp := false;                                   -- RTZ
            when "010" => roundUp := (sign = '1') and inexact;                -- RDN (-inf)
            when "011" => roundUp := (sign = '0') and inexact;                -- RUP (+inf)
            when "100" => roundUp := (G = '1');                               -- RMM (ties to max mag)
            when others => roundUp := (G = '1') and ((Tk = '1') or (lsb = '1')); -- RNE
        end case;

        mant := keep;
        if roundUp then
            mant := mant + 1;
        end if;

        if base_exp = 0 then
            -- Subnormal path: rounding may carry up into the smallest normal (bit MW set).
            exp_field := to_integer(mant(MW downto MW));   -- 0 (subnormal) or 1 (smallest normal)
            frac      := resize(mant(MW - 1 downto 0), 52);
            nx_f := '0'; if inexact then nx_f := '1'; end if;
            -- Tininess after rounding: tiny only if the rounded result is still subnormal.
            if exp_field = 0 and inexact then
                uf_f := '1';
            end if;
        else
            -- Normal path: handle round carry-out (1.111.. -> 10.000..).
            if mant(MW + 1) = '1' then
                mant := shift_right(mant, 1);
                base_exp := base_exp + 1;
            end if;
            nx_f := '0'; if inexact then nx_f := '1'; end if;

            if base_exp >= EXPMAX then
                -- Overflow: choose inf vs largest finite by mode and sign.
                of_f := '1'; nx_f := '1';
                case rm is
                    when "001"  => emit_inf := false;                 -- RTZ
                    when "010"  => emit_inf := (sign = '1');          -- RDN
                    when "011"  => emit_inf := (sign = '0');          -- RUP
                    when others => emit_inf := true;                  -- RNE / RMM
                end case;
                if emit_inf then
                    exp_field := EXPMAX; frac := (others => '0');
                else
                    exp_field := EXPMAX - 1; frac := (others => '1');
                end if;
            else
                exp_field := base_exp;
                frac      := resize(mant(MW - 1 downto 0), 52);
            end if;
        end if;

        -- Pack
        if is_double = '1' then
            res(63) := sign;
            res(62 downto 52) := std_logic_vector(to_unsigned(exp_field, 11));
            res(51 downto 0)  := std_logic_vector(frac);
        else
            res(63 downto 32) := (others => '0');
            res(31) := sign;
            res(30 downto 23) := std_logic_vector(to_unsigned(exp_field, 8));
            res(22 downto 0)  := std_logic_vector(frac(22 downto 0));
        end if;

        result <= res;
        flags  <= '0' & '0' & of_f & uf_f & nx_f;
        end if;
    end process;
end architecture;
