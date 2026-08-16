library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.all;

-- RV32M regression: exercises MUL/MULH/MULHSU/MULHU/DIV/DIVU/REM/REMU including
-- div-by-zero, INT_MIN/-1 overflow, and a back-to-back M -> ALU forwarding dependency.
-- The many multi-cycle stalls make this run much longer than the RV32I test.
entity riscv_m_tb is
end entity;

architecture sim of riscv_m_tb is

    component riscv_cpu is
        port(
            clk           : in  std_logic;
            reset         : in  std_logic;
            mem_ready     : in  std_logic;
            inst_addr     : out std_logic_vector(31 downto 0);
            instruction   : in  std_logic_vector(31 downto 0);
            dmem_addr     : out std_logic_vector(31 downto 0);
            dmem_wdata    : out std_logic_vector(63 downto 0);
            dmem_rdata    : in  std_logic_vector(63 downto 0);
            dmem_re       : out std_logic;
            dmem_we       : out std_logic;
            dmem_be       : out std_logic_vector(7 downto 0)
        );
    end component;

    constant CLK_PERIOD : time := 10 ns;

    signal clk_tb         : std_logic := '0';
    signal reset_tb       : std_logic := '1';
    signal mem_ready_tb   : std_logic := '1';

    signal inst_addr_tb   : std_logic_vector(31 downto 0);
    signal instruction_tb : std_logic_vector(31 downto 0);

    signal dmem_addr_tb   : std_logic_vector(31 downto 0);
    signal dmem_wdata_tb  : std_logic_vector(63 downto 0);
    signal dmem_rdata_tb  : std_logic_vector(63 downto 0);
    signal dmem_re_tb     : std_logic;
    signal dmem_we_tb     : std_logic;
    signal dmem_be_tb     : std_logic_vector(7 downto 0);

    type ram_array is array (0 to 255) of std_logic_vector(31 downto 0);
    signal imem : ram_array := (
        0  => x"00600093", -- addi x1,x0,6
        1  => x"00700113", -- addi x2,x0,7
        2  => x"022081b3", -- mul  x3,x1,x2
        3  => x"fec00213", -- addi x4,x0,-20
        4  => x"00300293", -- addi x5,x0,3
        5  => x"02524333", -- div  x6,x4,x5
        6  => x"025263b3", -- rem  x7,x4,x5
        7  => x"0220d433", -- divu x8,x1,x2
        8  => x"0220f4b3", -- remu x9,x1,x2
        9  => x"400005b7", -- lui  x11,0x40000
        10 => x"00400613", -- addi x12,x0,4
        11 => x"02c59533", -- mulh x10,x11,x12
        12 => x"02c5b6b3", -- mulhu x13,x11,x12
        13 => x"02c5a733", -- mulhsu x14,x11,x12
        14 => x"0200c7b3", -- div  x15,x1,x0
        15 => x"0200e833", -- rem  x16,x1,x0
        16 => x"800008b7", -- lui  x17,0x80000
        17 => x"fff00913", -- addi x18,x0,-1
        18 => x"0328c9b3", -- div  x19,x17,x18
        19 => x"0328ea33", -- rem  x20,x17,x18
        20 => x"02518ab3", -- mul  x21,x3,x5
        21 => x"001a8b33", -- add  x22,x21,x1
        others => x"00000013" -- NOP
    );

begin

    UUT: riscv_cpu
        port map(
            clk           => clk_tb,
            reset         => reset_tb,
            mem_ready     => mem_ready_tb,
            inst_addr     => inst_addr_tb,
            instruction   => instruction_tb,
            dmem_addr     => dmem_addr_tb,
            dmem_wdata    => dmem_wdata_tb,
            dmem_rdata    => dmem_rdata_tb,
            dmem_re       => dmem_re_tb,
            dmem_we       => dmem_we_tb,
            dmem_be       => dmem_be_tb
        );

    -- Async instruction fetch
    process(inst_addr_tb, imem)
        variable inst_idx : integer;
    begin
        inst_idx := to_integer(unsigned(inst_addr_tb(9 downto 2)));
        if inst_idx >= 0 and inst_idx <= 255 then
            instruction_tb <= imem(inst_idx);
        else
            instruction_tb <= x"00000013";
        end if;
    end process;

    -- No data memory activity in this program, but the port must be driven.
    dmem_rdata_tb <= (others => '0');

    clk_process : process
    begin
        while true loop
            clk_tb <= '0'; wait for CLK_PERIOD / 2;
            clk_tb <= '1'; wait for CLK_PERIOD / 2;
        end loop;
    end process;

    stimulus_process : process
    begin
        reset_tb <= '1';
        mem_ready_tb <= '1';
        wait for CLK_PERIOD * 2;
        wait until falling_edge(clk_tb);
        reset_tb <= '0';

        -- 22 instructions, 8 of them divide-group (~34 cycles each): allow plenty of slack.
        wait for CLK_PERIOD * 500;

        assert false report "RV32M simulation complete" severity failure;
        wait;
    end process;

end architecture;
