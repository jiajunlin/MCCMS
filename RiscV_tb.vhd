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
            dmem_wdata    : out std_logic_vector(31 downto 0);
            dmem_rdata    : in  std_logic_vector(31 downto 0);
            dmem_re       : out std_logic;
            dmem_we       : out std_logic
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
    signal dmem_wdata_tb  : std_logic_vector(31 downto 0);
    signal dmem_rdata_tb  : std_logic_vector(31 downto 0);
    signal dmem_re_tb     : std_logic;
    signal dmem_we_tb     : std_logic;

    -- Local Simulation Dual-Port Shared RAM (256 Words)
    type ram_array is array (0 to 255) of std_logic_vector(31 downto 0);
    signal shared_sys_ram : ram_array := (
        0  => x"01400093", -- addi x1, x0, 20      
        1  => x"00a00113", -- addi x2, x0, 10      
        2  => x"002081b3", -- add  x3, x1, x2      
        3  => x"40208233", -- sub  x4, x1, x2      
        4  => x"0020f2b3", -- and  x5, x1, x2      
        5  => x"0020e333", -- or   x6, x1, x2      
        6  => x"0020a123", -- sw   x2, 2(x1)       -- Target Address calculation: 20 + 2 = 22
        7  => x"0040a383", -- lw   x7, 4(x1)       -- Target Address calculation: 20 + 4 = 24
        8  => x"0020a463", -- beq  x1, x2, 8       
        9  => x"00209463", -- bne  x1, x2, 8       
        10 => x"00000013", -- nop                  
        11 => x"00112433", -- slt  x8, x2, x1      
        others => x"00000013" -- Default Balance to NOPs
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
            dmem_we       => dmem_we_tb
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

    -- Port 2: Synchronous Data Access Read/Write Memory tracking
    process(clk_tb)
        variable data_idx : integer;
    begin
        if rising_edge(clk_tb) then
            if reset_tb = '0' then
                data_idx := to_integer(unsigned(dmem_addr_tb(9 downto 2)));
                if data_idx >= 0 and data_idx <= 255 then
                    -- Process Synchronous Write
                    if dmem_we_tb = '1' then
                        shared_sys_ram(data_idx) <= dmem_wdata_tb;
                    end if;
                    -- Process Read response latching
                    if dmem_re_tb = '1' then
                        dmem_rdata_tb <= shared_sys_ram(data_idx);
                    else
                        dmem_rdata_tb <= (others => '0');
                    end if;
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
        wait for CLK_PERIOD * 30;
        
        assert false report "Refactored Core System successfully simulated!" severity failure;
        wait;
    end process;

end architecture;