library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.all;

-- FP load/store/move regression (M3b): fmv.w.x / fmv.x.w NaN-boxed single moves, fsw/flw and
-- fsd/fld round-trips through the 64-bit data memory, and back-to-back FP-register dependencies
-- that exercise the FP interlock. Integer stores (sw) feed the fld to cross-check the shared bus.
entity riscv_fp_tb is
end entity;

architecture sim of riscv_fp_tb is

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
    signal shared_sys_ram : ram_array := (
        0  => x"3f8000b7", -- lui  x1,0x3f800
        1  => x"00008093", -- addi x1,x1,0
        2  => x"40491137", -- lui  x2,0x40491
        3  => x"fdb10113", -- addi x2,x2,-37
        4  => x"112231b7", -- lui  x3,0x11223
        5  => x"34418193", -- addi x3,x3,836
        6  => x"55667237", -- lui  x4,0x55667
        7  => x"78820213", -- addi x4,x4,1928
        8  => x"00000537", -- lui  x10,0x00000
        9  => x"10050513", -- addi x10,x10,256
        10 => x"f0008053", -- fmv.w.x f0,x1
        11 => x"f00100d3", -- fmv.w.x f1,x2
        12 => x"e00002d3", -- fmv.x.w x5,f0
        13 => x"e0008353", -- fmv.x.w x6,f1
        14 => x"00052027", -- fsw f0,0(x10)
        15 => x"00052107", -- flw f2,0(x10)
        16 => x"e00103d3", -- fmv.x.w x7,f2
        17 => x"00352423", -- sw  x3,8(x10)
        18 => x"00452623", -- sw  x4,12(x10)
        19 => x"00853187", -- fld f3,8(x10)
        20 => x"00353827", -- fsd f3,16(x10)
        21 => x"01053207", -- fld f4,16(x10)
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
    process(inst_addr_tb, shared_sys_ram)
        variable inst_idx : integer;
    begin
        inst_idx := to_integer(unsigned(inst_addr_tb(9 downto 2)));
        if inst_idx >= 0 and inst_idx <= 255 then
            instruction_tb <= shared_sys_ram(inst_idx);
        else
            instruction_tb <= x"00000013";
        end if;
    end process;

    -- Async 64-bit data read: addressed doubleword presented as low/high 32-bit lanes.
    process(dmem_addr_tb, dmem_re_tb, shared_sys_ram)
        variable base : integer;
    begin
        base := to_integer(unsigned(dmem_addr_tb(11 downto 3))) * 2;
        if dmem_re_tb = '1' and base >= 0 and base <= 254 then
            dmem_rdata_tb(31 downto 0)  <= shared_sys_ram(base);
            dmem_rdata_tb(63 downto 32) <= shared_sys_ram(base + 1);
        else
            dmem_rdata_tb <= (others => '0');
        end if;
    end process;

    -- Sync 64-bit data write with per-byte strobes: be(3:0) -> low lane, be(7:4) -> high lane.
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

        -- 22 instructions plus FP interlock bubbles: allow generous slack.
        wait for CLK_PERIOD * 100;

        assert false report "FP load/store/move simulation complete" severity failure;
        wait;
    end process;

end architecture;
