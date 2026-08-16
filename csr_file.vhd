library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Zicsr control/status registers, FCSR subset only (all that RV32F/D requires):
--   fflags (0x001) = fcsr[4:0]   : NV(4) DZ(3) OF(2) UF(1) NX(0)  -- accrued exception flags
--   frm    (0x002) = fcsr[7:5]   : dynamic rounding mode
--   fcsr   (0x003) = {frm, fflags}
--
-- Two write sources:
--   * explicit CSR instructions (csrrw/s/c[i]) via we/waddr/wdata
--   * FP instructions accruing exception flags via fflags_we/fflags_in (OR-ed in)
-- Reads are combinational; writes commit on the clock edge when `en` is high (= mem_ready).
entity csr_file is
    port(
        clk, reset : in  std_logic;
        en         : in  std_logic;                     -- advance enable (mem_ready)

        -- Combinational read port (for the CSR instruction's rd = old value)
        raddr      : in  std_logic_vector(11 downto 0);
        rdata      : out std_logic_vector(31 downto 0);

        -- CSR-instruction write port
        we         : in  std_logic;
        waddr      : in  std_logic_vector(11 downto 0);
        wdata      : in  std_logic_vector(31 downto 0);

        -- FP exception-flag accrual (OR-ed into fflags)
        fflags_we  : in  std_logic;
        fflags_in  : in  std_logic_vector(4 downto 0);

        -- Exposed for FP dynamic rounding
        frm_out    : out std_logic_vector(2 downto 0)
    );
end entity;

architecture behavioral of csr_file is
    signal fflags : std_logic_vector(4 downto 0) := (others => '0');
    signal frm    : std_logic_vector(2 downto 0) := (others => '0');
begin

    frm_out <= frm;

    -- Combinational read
    process(raddr, fflags, frm)
    begin
        case raddr is
            when x"001" => rdata <= (31 downto 5 => '0') & fflags;              -- fflags
            when x"002" => rdata <= (31 downto 3 => '0') & frm;                 -- frm
            when x"003" => rdata <= (31 downto 8 => '0') & frm & fflags;        -- fcsr
            when others => rdata <= (others => '0');
        end case;
    end process;

    -- Synchronous write / accrual
    process(clk, reset)
        variable nf : std_logic_vector(4 downto 0);
        variable nr : std_logic_vector(2 downto 0);
    begin
        if reset = '1' then
            fflags <= (others => '0');
            frm    <= (others => '0');
        elsif rising_edge(clk) then
            if en = '1' then
                nf := fflags;
                nr := frm;
                -- explicit CSR write takes effect first
                if we = '1' then
                    case waddr is
                        when x"001" => nf := wdata(4 downto 0);
                        when x"002" => nr := wdata(2 downto 0);
                        when x"003" => nr := wdata(7 downto 5); nf := wdata(4 downto 0);
                        when others => null;
                    end case;
                end if;
                -- FP flag accrual OR-ed on top (never lost)
                if fflags_we = '1' then
                    nf := nf or fflags_in;
                end if;
                fflags <= nf;
                frm    <= nr;
            end if;
        end if;
    end process;

end architecture;
