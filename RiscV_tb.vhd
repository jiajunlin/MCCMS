library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.all;

entity riscv_cpu_tb is
end entity;

architecture sim of riscv_cpu_tb is

    -- Component declaration matching the updated interface
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

    -- Testbench Interconnect Signals
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

    -- Local Simulation Dual-Port Shared RAM (256 Words)
    type ram_array is array (0 to 255) of std_logic_vector(31 downto 0);
    -- Exercises loads/stores of every width plus JAL/JALR. Data lives at word index 64+
    -- (byte addr 256+) so stores never clobber the instruction region.
    signal shared_sys_ram : ram_array := (
        0  => x"10000093", -- addi x1,x0,256   x1 = 0x100 (data base)
        1  => x"fff00113", -- addi x2,x0,-1    x2 = 0xFFFFFFFF
        2  => x"00208023", -- sb   x2,0(x1)    mem[0x100] byte0 = 0xFF
        3  => x"0000c183", -- lbu  x3,0(x1)    x3 = 0x000000FF
        4  => x"00008203", -- lb   x4,0(x1)    x4 = 0xFFFFFFFF (sign-extended)
        5  => x"00209223", -- sh   x2,4(x1)    mem[0x104] half = 0xFFFF
        6  => x"0040d303", -- lhu  x6,4(x1)    x6 = 0x0000FFFF
        7  => x"00409383", -- lh   x7,4(x1)    x7 = 0xFFFFFFFF (sign-extended)
        8  => x"0010a423", -- sw   x1,8(x1)    mem[0x108] = 0x100
        9  => x"0080a403", -- lw   x8,8(x1)    x8 = 0x00000100
        10 => x"008004ef", -- jal  x9,8        x9 = 44; jump to idx12 (skips idx11)
        11 => x"06f00513", -- addi x10,x0,111  SKIPPED -> x10 stays 0
        12 => x"0de00593", -- addi x11,x0,222  x11 = 222
        13 => x"05000693", -- addi x13,x0,80   x13 = 80 (= byte addr of idx20)
        14 => x"00068667", -- jalr x12,x13,0   x12 = 60; jump to idx20 (skips idx15-19)
        15 => x"07b00713", -- addi x14,x0,123  SKIPPED -> x14 stays 0
        others => x"00000013" -- NOP (addi x0,x0,0)
    );

begin

    -- Unit Under Test (UUT)
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

    -- Port 1: Async Read Interface for Instruction Fetch Tracking
    process(inst_addr_tb, shared_sys_ram)
        variable inst_idx : integer;
    begin
        inst_idx := to_integer(unsigned(inst_addr_tb(9 downto 2)));
        if inst_idx >= 0 and inst_idx <= 255 then
            instruction_tb <= shared_sys_ram(inst_idx);
        else
            instruction_tb <= x"00000013"; -- Fallback safe NOP
        end if;
    end process;

    -- Port 2a: Asynchronous data read. The 64-bit bus presents the addressed 8-byte doubleword
    -- as two consecutive 32-bit words: low lane = word[base], high lane = word[base+1].
    process(dmem_addr_tb, dmem_re_tb, shared_sys_ram)
        variable base : integer;
    begin
        base := to_integer(unsigned(dmem_addr_tb(11 downto 3))) * 2; -- doubleword-aligned word index
        if dmem_re_tb = '1' and base >= 0 and base <= 254 then
            dmem_rdata_tb(31 downto 0)  <= shared_sys_ram(base);
            dmem_rdata_tb(63 downto 32) <= shared_sys_ram(base + 1);
        else
            dmem_rdata_tb <= (others => '0');
        end if;
    end process;

    -- Port 2b: Synchronous data write with per-byte strobes (sb/sh/sw/fsw/fsd). be(3:0) hit the
    -- low-lane word, be(7:4) the high-lane word.
    process(clk_tb)
        variable base : integer;
    begin
        if rising_edge(clk_tb) then
            if reset_tb = '0' and dmem_we_tb = '1' then
                base := to_integer(unsigned(dmem_addr_tb(11 downto 3))) * 2;
                if base >= 0 and base <= 254 then
                    for bsel in 0 to 3 loop
                        if dmem_be_tb(bsel) = '1' then
                            shared_sys_ram(base)(bsel*8 + 7 downto bsel*8) <=
                                dmem_wdata_tb(bsel*8 + 7 downto bsel*8);
                        end if;
                        if dmem_be_tb(bsel + 4) = '1' then
                            shared_sys_ram(base + 1)(bsel*8 + 7 downto bsel*8) <=
                                dmem_wdata_tb(bsel*8 + 39 downto bsel*8 + 32);
                        end if;
                    end loop;
                end if;
            end if;
        end if;
    end process;

    -- Clock Generation
    clk_process : process
    begin
        while true loop
            clk_tb <= '0'; wait for CLK_PERIOD / 2;
            clk_tb <= '1'; wait for CLK_PERIOD / 2;
        end loop;
    end process;

    -- Test Bench Stimulus Process Sequence
    stimulus_process : process
    begin
        reset_tb <= '1';
        mem_ready_tb <= '1';
        wait for CLK_PERIOD * 2;
        
        wait until falling_edge(clk_tb);
        reset_tb <= '0';
        
        -- Run long enough to completely observe pipeline step saturation
        wait for CLK_PERIOD * 40;
        
        assert false report "Refactored Core System successfully simulated!" severity failure;
        wait;
    end process;

end architecture;