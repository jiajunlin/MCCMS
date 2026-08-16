library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- IEEE-754 floating-point divide (fdiv, funct5 00011) and square root (fsqrt, funct5 01011)
-- for single (fmt=0) and double (fmt=1). Multi-cycle with a muldiv-style start/done handshake so
-- the pipeline can freeze while it works (see ex_stall in RISCV_CPU.vhd).
--
-- The arithmetic itself is computed COMBINATIONALLY from the operands captured at launch: an exact
-- integer long-division / integer square root produces a wide significand together with an exact
-- sticky bit, which is normalized so its leading 1 lands at bit 127 and handed to the shared
-- fpu_round core for correctly-rounded results in all five rounding modes (incl. subnormal
-- underflow and overflow). The FSM only sequences the latency and pulses `done` for one cycle.
--
-- Special cases (bypass the rounder):
--   fdiv : NaN in -> qNaN (+NV if sNaN); inf/inf, 0/0 -> qNaN + NV; x/0 (x finite!=0) -> inf + DZ;
--          inf/finite -> inf; finite/inf and 0/finite -> signed 0; sign = sign(a) xor sign(b).
--   fsqrt: NaN in -> qNaN (+NV if sNaN); a<0 (and !=0) -> qNaN + NV; -0 -> -0; +0 -> +0;
--          +inf -> +inf; else sign 0.
-- Single results are NaN-boxed on exit. flags: NV DZ OF UF NX.
entity fp_divsqrt is
    port(
        clk, reset : in  std_logic;
        start      : in  std_logic;                      -- held '1' while the op sits in EX
        is_sqrt    : in  std_logic;                      -- 1 = fsqrt, 0 = fdiv
        is_double  : in  std_logic;
        rm         : in  std_logic_vector(2 downto 0);
        a_raw      : in  std_logic_vector(63 downto 0);  -- dividend / radicand (fp[rs1])
        b_raw      : in  std_logic_vector(63 downto 0);  -- divisor (fp[rs2]); ignored for fsqrt
        fp_result  : out std_logic_vector(63 downto 0);
        flags      : out std_logic_vector(4 downto 0);   -- NV DZ OF UF NX
        done       : out std_logic
        );
end entity;

architecture behavioral of fp_divsqrt is

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

    -- Latency (RUN cycles). Values only model multi-cycle behaviour; the result is exact regardless.
    constant DIV_LAT  : integer := 12;
    constant SQRT_LAT : integer := 20;

    type state_t is (IDLE, RUN, FINISH);
    signal state : state_t := IDLE;
    signal cnt   : integer range 0 to 63 := 0;

    -- Latched operands / op (captured at launch, held stable by the pipeline freeze anyway)
    signal r_a, r_b     : std_logic_vector(63 downto 0) := (others => '0');
    signal r_is_sqrt    : std_logic := '0';
    signal r_is_double  : std_logic := '0';
    signal r_rm         : std_logic_vector(2 downto 0) := "000";

    -- Path into the shared rounder
    signal n_sign   : std_logic;
    signal n_exp    : integer;
    signal n_sig    : std_logic_vector(127 downto 0);
    signal rnd_res  : std_logic_vector(63 downto 0);
    signal rnd_flags: std_logic_vector(4 downto 0);

    -- Special-case bypass
    signal spec_valid : std_logic;
    signal spec_val   : std_logic_vector(63 downto 0);
    signal spec_flags : std_logic_vector(4 downto 0);

begin

    -- Sequential control: launch on start, count down, pulse done for one cycle (mirrors muldiv_unit)
    process(clk, reset)
    begin
        if reset = '1' then
            state <= IDLE; cnt <= 0; done <= '0';
            r_a <= (others => '0'); r_b <= (others => '0');
            r_is_sqrt <= '0'; r_is_double <= '0'; r_rm <= "000";
        elsif rising_edge(clk) then
            case state is
                when IDLE =>
                    done <= '0';
                    if start = '1' then
                        r_a <= a_raw; r_b <= b_raw;
                        r_is_sqrt <= is_sqrt; r_is_double <= is_double; r_rm <= rm;
                        if is_sqrt = '1' then cnt <= SQRT_LAT; else cnt <= DIV_LAT; end if;
                        state <= RUN;
                    end if;
                when RUN =>
                    if cnt = 0 then
                        done  <= '1';
                        state <= FINISH;
                    else
                        cnt <= cnt - 1;
                    end if;
                when FINISH =>
                    done  <= '0';
                    state <= IDLE;
            end case;
        end if;
    end process;

    -- Combinational arithmetic from the latched operands (valid throughout RUN/FINISH).
    process(r_a, r_b, r_is_sqrt, r_is_double)
        variable MW, BIAS, EMIN : integer;
        variable av, bv : std_logic_vector(63 downto 0);
        variable sa, sb, sr : std_logic;
        variable efa, efb : std_logic_vector(10 downto 0);
        variable fra, frb : unsigned(51 downto 0);
        variable za, zb, ia, ib, na, nb, sna, snb : boolean;
        variable siga, sigb : unsigned(63 downto 0);
        variable ea, eb : integer;         -- normalized exponent of the leading 1
        variable p : integer;
        -- division
        variable num : unsigned(255 downto 0);
        variable q   : unsigned(255 downto 0);
        variable rem_d : unsigned(255 downto 0);
        variable Mq  : integer;
        variable rshift : integer;
        variable sig128 : unsigned(127 downto 0);
        variable sticky : std_logic;
        -- sqrt
        variable base, eparity, gexp : integer;
        variable radicand : unsigned(319 downto 0);
        variable nrem : unsigned(319 downto 0);
        variable res  : unsigned(319 downto 0);
        variable b1   : unsigned(319 downto 0);
        variable bitpos, Mr, Ms : integer;
    begin
        if r_is_double = '1' then
            MW := 52; BIAS := 1023; EMIN := -1022;
            av := r_a; bv := r_b;
        else
            MW := 23; BIAS := 127; EMIN := -126;
            av := (63 downto 32 => '0') & unbox_s(r_a);
            bv := (63 downto 32 => '0') & unbox_s(r_b);
        end if;

        if r_is_double = '1' then
            sa := av(63); efa := av(62 downto 52); fra := unsigned(av(51 downto 0));
            sb := bv(63); efb := bv(62 downto 52); frb := unsigned(bv(51 downto 0));
        else
            sa := av(31); efa := "000" & av(30 downto 23); fra := resize(unsigned(av(22 downto 0)), 52);
            sb := bv(31); efb := "000" & bv(30 downto 23); frb := resize(unsigned(bv(22 downto 0)), 52);
        end if;

        -- Classify a and b (efa/efb all-ones = inf/NaN)
        za := (efa = "00000000000") and (fra = 0);
        zb := (efb = "00000000000") and (frb = 0);
        ia := (efa = "11111111111") and (fra = 0);
        ib := (efb = "11111111111") and (frb = 0);
        na := (efa = "11111111111") and (fra /= 0);
        nb := (efb = "11111111111") and (frb /= 0);
        sna := na and (fra(MW - 1) = '0');   -- signaling NaN: top fraction bit clear
        snb := nb and (frb(MW - 1) = '0');

        sr := sa xor sb;

        -- defaults
        spec_valid <= '0';
        spec_val   <= (others => '0');
        spec_flags <= "00000";
        n_sign     <= '0';
        n_exp      <= 0;
        n_sig      <= (others => '0');

        -- Build normalized significand + exponent-of-leading-1 for a (siga/ea) and b (sigb/eb).
        -- Value = sig * 2^(e - MW), sig in [2^MW, 2^(MW+1)) for finite non-zero.
        if efa = "00000000000" then           -- zero or subnormal a
            siga := (others => '0'); ea := EMIN;
            if fra /= 0 then
                p := 0;
                for i in 0 to 51 loop if fra(i) = '1' then p := i; end if; end loop;
                siga := shift_left(resize(fra, 64), MW - p);
                ea := EMIN - (MW - p);
            end if;
        else
            siga := resize(fra, 64); siga(MW) := '1'; ea := to_integer(unsigned(efa)) - BIAS;
        end if;
        if efb = "00000000000" then
            sigb := (others => '0'); eb := EMIN;
            if frb /= 0 then
                p := 0;
                for i in 0 to 51 loop if frb(i) = '1' then p := i; end if; end loop;
                sigb := shift_left(resize(frb, 64), MW - p);
                eb := EMIN - (MW - p);
            end if;
        else
            sigb := resize(frb, 64); sigb(MW) := '1'; eb := to_integer(unsigned(efb)) - BIAS;
        end if;

        if r_is_sqrt = '1' then
            -- ============================ SQUARE ROOT ============================
            if na then                                   -- NaN in
                spec_valid <= '1';
                if sna then spec_flags <= "10000"; end if;
                if r_is_double = '1' then spec_val <= QNAN_D; else spec_val <= x"FFFFFFFF" & QNAN_S; end if;
            elsif za then                                -- +/-0 -> same-signed zero (no flag)
                spec_valid <= '1';
                if r_is_double = '1' then spec_val <= sa & (62 downto 0 => '0');
                else spec_val <= x"FFFFFFFF" & sa & (30 downto 0 => '0'); end if;
            elsif sa = '1' then                          -- negative (incl -inf, -normal) -> NV, qNaN
                spec_valid <= '1'; spec_flags <= "10000";
                if r_is_double = '1' then spec_val <= QNAN_D; else spec_val <= x"FFFFFFFF" & QNAN_S; end if;
            elsif ia then                                -- +inf -> +inf
                spec_valid <= '1';
                if r_is_double = '1' then spec_val <= '0' & "11111111111" & (51 downto 0 => '0');
                else spec_val <= x"FFFFFFFF" & '0' & "11111111" & (22 downto 0 => '0'); end if;
            else
                -- Finite positive: value = siga * 2^(ea - MW). Remove exponent parity so the
                -- remaining scale is even, fold the odd bit into the radicand (x2).
                base := ea - MW;
                eparity := base mod 2;                   -- VHDL mod: result 0..1
                gexp := (base - eparity) / 2;
                radicand := shift_left(resize(siga, 320), 256);   -- R * 2^256 (P = 128)
                if eparity = 1 then radicand := shift_left(radicand, 1); end if;

                -- Integer sqrt (digit-by-digit): res = floor(sqrt(radicand)), nrem = remainder.
                Mr := 0;
                for i in 319 downto 0 loop
                    if radicand(i) = '1' then Mr := i; exit; end if;
                end loop;
                bitpos := Mr; if (bitpos mod 2) = 1 then bitpos := bitpos - 1; end if;
                nrem := radicand;
                res  := (others => '0');
                loop
                    b1 := shift_left(to_unsigned(1, 320), bitpos);
                    if nrem >= (res + b1) then
                        nrem := nrem - (res + b1);
                        res  := shift_right(res, 1) + b1;
                    else
                        res  := shift_right(res, 1);
                    end if;
                    exit when bitpos = 0;
                    bitpos := bitpos - 2;
                end loop;

                -- Normalize res (leading 1 -> bit 127); OR-jam lost bits and the sqrt remainder.
                Ms := 0;
                for i in 319 downto 0 loop
                    if res(i) = '1' then Ms := i; exit; end if;
                end loop;
                rshift := Ms - 127;
                sig128 := resize(shift_right(res, rshift), 128);
                sticky := '0';
                if shift_left(shift_right(res, rshift), rshift) /= res then sticky := '1'; end if;
                if nrem /= 0 then sticky := '1'; end if;
                sig128(0) := sig128(0) or sticky;

                n_sign <= '0';
                n_exp  <= Ms + gexp - 128;
                n_sig  <= std_logic_vector(sig128);
            end if;

        else
            -- ============================== DIVIDE ==============================
            if na or nb then                             -- NaN in
                spec_valid <= '1';
                if sna or snb then spec_flags <= "10000"; end if;
                if r_is_double = '1' then spec_val <= QNAN_D; else spec_val <= x"FFFFFFFF" & QNAN_S; end if;
            elsif (ia and ib) or (za and zb) then        -- inf/inf or 0/0 -> NV, qNaN
                spec_valid <= '1'; spec_flags <= "10000";
                if r_is_double = '1' then spec_val <= QNAN_D; else spec_val <= x"FFFFFFFF" & QNAN_S; end if;
            elsif ia then                                -- inf / finite -> inf
                spec_valid <= '1';
                if r_is_double = '1' then spec_val <= sr & "11111111111" & (51 downto 0 => '0');
                else spec_val <= x"FFFFFFFF" & sr & "11111111" & (22 downto 0 => '0'); end if;
            elsif ib or za then                          -- finite/inf or 0/finite -> signed 0
                spec_valid <= '1';
                if r_is_double = '1' then spec_val <= sr & (62 downto 0 => '0');
                else spec_val <= x"FFFFFFFF" & sr & (30 downto 0 => '0'); end if;
            elsif zb then                                -- x/0 (x finite non-zero) -> inf, DZ
                spec_valid <= '1'; spec_flags <= "01000";
                if r_is_double = '1' then spec_val <= sr & "11111111111" & (51 downto 0 => '0');
                else spec_val <= x"FFFFFFFF" & sr & "11111111" & (22 downto 0 => '0'); end if;
            else
                -- Finite / finite: q = floor(siga * 2^130 / sigb), rem exact. siga,sigb in
                -- [2^MW,2^(MW+1)) so q in (2^129, 2^131) -> leading 1 at bit 129 or 130.
                num := shift_left(resize(siga, 256), 130);
                q   := num / resize(sigb, 256);
                rem_d := num mod resize(sigb, 256);

                Mq := 0;
                for i in 255 downto 0 loop
                    if q(i) = '1' then Mq := i; exit; end if;
                end loop;
                rshift := Mq - 127;
                sig128 := resize(shift_right(q, rshift), 128);
                sticky := '0';
                if shift_left(shift_right(q, rshift), rshift) /= q then sticky := '1'; end if;
                if rem_d /= 0 then sticky := '1'; end if;
                sig128(0) := sig128(0) or sticky;

                n_sign <= sr;
                n_exp  <= Mq + ea - eb - 130;
                n_sig  <= std_logic_vector(sig128);
            end if;
        end if;
    end process;

    ROUND_INST: fpu_round
        port map(sign => n_sign, is_double => r_is_double, is_zero => '0',
                 rm => r_rm, exp_in => n_exp, sig_in => n_sig,
                 result => rnd_res, flags => rnd_flags);

    -- Final result: special-case bypass, else the rounded value. NaN-box single results.
    process(spec_valid, spec_val, spec_flags, rnd_res, rnd_flags, r_is_double)
    begin
        if spec_valid = '1' then
            fp_result <= spec_val;
            flags     <= spec_flags;
        else
            if r_is_double = '1' then
                fp_result <= rnd_res;
            else
                fp_result <= x"FFFFFFFF" & rnd_res(31 downto 0);
            end if;
            flags <= rnd_flags;
        end if;
    end process;

end behavioral;
