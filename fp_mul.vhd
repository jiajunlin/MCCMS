library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- IEEE-754 floating-point multiply for single (fmt=0) and double (fmt=1).
-- Special cases (NaN, inf*0, inf) bypass the rounder; finite products are normalized and handed
-- to the shared fpu_round core. Single results are NaN-boxed on exit.
-- flags: NV DZ OF UF NX (NV only from sNaN or inf*0).
entity fp_mul is
    port(
        is_double : in  std_logic;
        rm        : in  std_logic_vector(2 downto 0);
        a_raw     : in  std_logic_vector(63 downto 0);
        b_raw     : in  std_logic_vector(63 downto 0);
        fp_result : out std_logic_vector(63 downto 0);
        flags     : out std_logic_vector(4 downto 0)
        );
end entity;

architecture behavioral of fp_mul is

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

    function unbox_s(x : std_logic_vector(63 downto 0)) return std_logic_vector is
    begin
        if x(63 downto 32) = x"FFFFFFFF" then
            return x(31 downto 0);
        else
            return QNAN_S;
        end if;
    end function;

    signal r_sign   : std_logic;
    signal r_zero   : std_logic;
    signal r_exp    : integer;
    signal r_sig    : std_logic_vector(127 downto 0);
    signal r_result : std_logic_vector(63 downto 0);
    signal r_flags  : std_logic_vector(4 downto 0);

    signal spec_valid : std_logic;
    signal spec_val   : std_logic_vector(63 downto 0);
    signal spec_nv    : std_logic;

begin

    process(is_double, rm, a_raw, b_raw)
        variable MW, BIAS, EMIN : integer;
        variable av, bv : std_logic_vector(63 downto 0);
        variable sa, sb, sr : std_logic;
        variable efa, efb : std_logic_vector(10 downto 0);
        variable fra, frb : unsigned(51 downto 0);
        variable ea, eb : integer;
        variable za, zb, ia, ib, na, nb, sna, snb : boolean;
        variable siga, sigb : unsigned(63 downto 0);
        variable prod : unsigned(127 downto 0);
        variable M : integer;
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

        if is_double = '1' then
            sa := av(63); efa := av(62 downto 52); fra := unsigned(av(51 downto 0));
            sb := bv(63); efb := bv(62 downto 52); frb := unsigned(bv(51 downto 0));
            emaxa := (efa = "11111111111"); emaxb := (efb = "11111111111");
        else
            sa := av(31); efa := "000" & av(30 downto 23); fra := resize(unsigned(av(22 downto 0)), 52);
            sb := bv(31); efb := "000" & bv(30 downto 23); frb := resize(unsigned(bv(22 downto 0)), 52);
            emaxa := (av(30 downto 23) = "11111111"); emaxb := (bv(30 downto 23) = "11111111");
        end if;

        za := (efa = (efa'range => '0')) and (fra = 0);
        zb := (efb = (efb'range => '0')) and (frb = 0);
        ia := emaxa and (fra = 0);
        ib := emaxb and (frb = 0);
        na := emaxa and (fra /= 0);
        nb := emaxb and (frb /= 0);
        if is_double = '1' then
            sna := na and (av(51) = '0'); snb := nb and (bv(51) = '0');
        else
            sna := na and (av(22) = '0'); snb := nb and (bv(22) = '0');
        end if;

        sr := sa xor sb;

        spec_valid <= '0';
        spec_nv    <= '0';
        spec_val   <= (others => '0');
        r_sign     <= sr;
        r_zero     <= '0';
        r_exp      <= 0;
        r_sig      <= (others => '0');

        if na or nb or ia or ib then
            spec_valid <= '1';
            if sna or snb then spec_nv <= '1'; end if;
            if na or nb then
                if is_double = '1' then spec_val <= QNAN_D; else spec_val <= x"FFFFFFFF" & QNAN_S; end if;
            elsif (ia and zb) or (ib and za) then    -- inf * 0 -> invalid
                spec_nv <= '1';
                if is_double = '1' then spec_val <= QNAN_D; else spec_val <= x"FFFFFFFF" & QNAN_S; end if;
            else                                      -- inf * finite-nonzero -> inf
                if is_double = '1' then spec_val <= sr & "11111111111" & (51 downto 0 => '0');
                else spec_val <= x"FFFFFFFF" & sr & "11111111" & (22 downto 0 => '0'); end if;
            end if;
        elsif za or zb then
            -- zero * finite -> signed zero
            r_zero <= '1';
        else
            if efa = (efa'range => '0') then
                siga := resize(fra, 64); ea := EMIN;
            else
                siga := resize(fra, 64); siga(MW) := '1'; ea := to_integer(unsigned(efa)) - BIAS;
            end if;
            if efb = (efb'range => '0') then
                sigb := resize(frb, 64); eb := EMIN;
            else
                sigb := resize(frb, 64); sigb(MW) := '1'; eb := to_integer(unsigned(efb)) - BIAS;
            end if;

            prod := siga * sigb;    -- up to 2*(MW+1) bits

            M := 0;
            for i in 127 downto 0 loop
                if prod(i) = '1' then M := i; exit; end if;
            end loop;

            r_sig <= std_logic_vector(shift_left(prod, 127 - M));
            r_exp <= M + ea + eb - 2 * MW;
        end if;
    end process;

    ROUND_INST: fpu_round
        port map(sign => r_sign, is_double => is_double, is_zero => r_zero,
                 rm => rm, exp_in => r_exp, sig_in => r_sig,
                 result => r_result, flags => r_flags);

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
