library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- RV32M multiply/divide functional unit.
--
-- Multi-cycle with a simple start/done handshake so the pipeline can freeze while
-- it works. The arithmetic itself is computed combinationally from the operands
-- captured at launch (guaranteed-correct numeric_std operators); the FSM only
-- sequences the latency and pulses `done` for one cycle when the result is valid.
--
--   start : held '1' by the core while the M-op sits in EX (= ID_EX_is_muldiv)
--   done  : '1' for exactly one cycle when `result` is valid; the op then advances
entity muldiv_unit is
    port(
        clk, reset : in  std_logic;
        start      : in  std_logic;
        funct3     : in  std_logic_vector(2 downto 0);
        a, b       : in  std_logic_vector(31 downto 0); -- forwarded rs1, rs2
        result     : out std_logic_vector(31 downto 0);
        done       : out std_logic
    );
end entity;

architecture behavioral of muldiv_unit is
    type state_t is (IDLE, RUN, FINISH);
    signal state    : state_t := IDLE;
    signal cnt      : integer range 0 to 63 := 0;
    signal op       : std_logic_vector(2 downto 0) := "000";
    signal opa, opb : std_logic_vector(31 downto 0) := (others => '0');

    -- RUN cycles: multiply group is fast, divide group emulates a 32-step recurrence.
    constant MUL_LAT : integer := 3;
    constant DIV_LAT : integer := 32;
begin

    -- Sequential control: launch on start, count down, pulse done for one cycle
    process(clk, reset)
    begin
        if reset = '1' then
            state <= IDLE; cnt <= 0; done <= '0';
            op <= "000"; opa <= (others => '0'); opb <= (others => '0');
        elsif rising_edge(clk) then
            case state is
                when IDLE =>
                    done <= '0';
                    if start = '1' then
                        op  <= funct3;
                        opa <= a;
                        opb <= b;
                        if funct3(2) = '1' then cnt <= DIV_LAT; else cnt <= MUL_LAT; end if;
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

    -- Combinational result from the captured operands (valid throughout RUN/FINISH)
    process(op, opa, opb)
        variable pu  : unsigned(63 downto 0);
        variable ps  : signed(63 downto 0);
        variable sa  : signed(32 downto 0);
        variable sb  : signed(32 downto 0);
        variable psu : signed(65 downto 0);
    begin
        case op is
            when "000" => -- MUL: low 32 bits of product
                pu := unsigned(opa) * unsigned(opb);
                result <= std_logic_vector(pu(31 downto 0));
            when "001" => -- MULH: high 32 bits, signed x signed
                ps := signed(opa) * signed(opb);
                result <= std_logic_vector(ps(63 downto 32));
            when "010" => -- MULHSU: high 32 bits, signed(a) x unsigned(b)
                sa  := resize(signed(opa), 33);
                sb  := signed('0' & opb);          -- unsigned b as non-negative
                psu := sa * sb;
                result <= std_logic_vector(psu(63 downto 32));
            when "011" => -- MULHU: high 32 bits, unsigned x unsigned
                pu := unsigned(opa) * unsigned(opb);
                result <= std_logic_vector(pu(63 downto 32));
            when "100" => -- DIV: signed, truncate toward zero
                if opb = x"00000000" then
                    result <= (others => '1');                    -- div by zero -> -1
                elsif opa = x"80000000" and opb = x"FFFFFFFF" then
                    result <= x"80000000";                        -- signed overflow
                else
                    result <= std_logic_vector(signed(opa) / signed(opb));
                end if;
            when "101" => -- DIVU
                if opb = x"00000000" then
                    result <= (others => '1');                    -- div by zero -> all ones
                else
                    result <= std_logic_vector(unsigned(opa) / unsigned(opb));
                end if;
            when "110" => -- REM: signed, sign of dividend
                if opb = x"00000000" then
                    result <= opa;                                -- rem by zero -> dividend
                elsif opa = x"80000000" and opb = x"FFFFFFFF" then
                    result <= (others => '0');                    -- signed overflow -> 0
                else
                    result <= std_logic_vector(signed(opa) rem signed(opb));
                end if;
            when others => -- "111" REMU
                if opb = x"00000000" then
                    result <= opa;
                else
                    result <= std_logic_vector(unsigned(opa) rem unsigned(opb));
                end if;
        end case;
    end process;

end architecture;
