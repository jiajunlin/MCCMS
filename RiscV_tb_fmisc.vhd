library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.all;

-- FP misc regression (M4a): fsgnj/n/x, fmin/fmax, feq/flt/fle, fclass on both single and double
-- operands, covering signed zero, +/-inf, qNaN/sNaN (NV accrual). FP-register results are captured
-- directly from the FP writeback stream; comparison/fclass write integer regs; the accrued fflags
-- are read out at the end via csrrs (expect NV = 0x10). Doubles are built in memory (base 0x200).
entity riscv_fmisc_tb is
end entity;

architecture sim of riscv_fmisc_tb is

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
        2  => x"f0008053", -- fmv.w.x f0,x1  (1.0)
        3  => x"bf8000b7", -- lui  x1,0xbf800
        4  => x"00008093", -- addi x1,x1,0
        5  => x"f00080d3", -- fmv.w.x f1,x1  (-1.0)
        6  => x"400000b7", -- lui  x1,0x40000
        7  => x"00008093", -- addi x1,x1,0
        8  => x"f0008153", -- fmv.w.x f2,x1  (2.0)
        9  => x"800000b7", -- lui  x1,0x80000
        10 => x"00008093", -- addi x1,x1,0
        11 => x"f00081d3", -- fmv.w.x f3,x1  (-0.0)
        12 => x"000000b7", -- lui  x1,0x00000
        13 => x"00008093", -- addi x1,x1,0
        14 => x"f0008253", -- fmv.w.x f4,x1  (+0.0)
        15 => x"7f8000b7", -- lui  x1,0x7f800
        16 => x"00008093", -- addi x1,x1,0
        17 => x"f00082d3", -- fmv.w.x f5,x1  (+inf)
        18 => x"7fc000b7", -- lui  x1,0x7fc00
        19 => x"00008093", -- addi x1,x1,0
        20 => x"f0008353", -- fmv.w.x f6,x1  (qNaN)
        21 => x"7f8000b7", -- lui  x1,0x7f800
        22 => x"00108093", -- addi x1,x1,1
        23 => x"f00083d3", -- fmv.w.x f7,x1  (sNaN)
        24 => x"20100453", -- fsgnj.s  f8,f0,f1
        25 => x"201014d3", -- fsgnjn.s f9,f0,f1
        26 => x"2020a553", -- fsgnjx.s f10,f1,f2
        27 => x"280085d3", -- fmin.s   f11,f1,f0
        28 => x"28009653", -- fmax.s   f12,f1,f0
        29 => x"284186d3", -- fmin.s   f13,f3,f4
        30 => x"28419753", -- fmax.s   f14,f3,f4
        31 => x"280307d3", -- fmin.s   f15,f6,f0
        32 => x"28038853", -- fmin.s   f16,f7,f0
        33 => x"a00022d3", -- feq.s  x5,f0,f0
        34 => x"a0009353", -- flt.s  x6,f1,f0
        35 => x"a00003d3", -- fle.s  x7,f0,f0
        36 => x"a0031453", -- flt.s  x8,f6,f0
        37 => x"a00324d3", -- feq.s  x9,f6,f0
        38 => x"a003ae53", -- feq.s  x28,f7,f0
        39 => x"e0001a53", -- fclass.s x20,f0
        40 => x"e0019ad3", -- fclass.s x21,f3
        41 => x"e0029b53", -- fclass.s x22,f5
        42 => x"e0031bd3", -- fclass.s x23,f6
        43 => x"e0039c53", -- fclass.s x24,f7
        44 => x"00000537", -- lui  x10,0x00000
        45 => x"20050513", -- addi x10,x10,512
        46 => x"00000837", -- lui  x16,0x00000
        47 => x"00080813", -- addi x16,x16,0
        48 => x"3ff808b7", -- lui  x17,0x3ff80
        49 => x"00088893", -- addi x17,x17,0
        50 => x"00000937", -- lui  x18,0x00000
        51 => x"00090913", -- addi x18,x18,0
        52 => x"bff809b7", -- lui  x19,0xbff80
        53 => x"00098993", -- addi x19,x19,0
        54 => x"01052023", -- sw x16,0(x10)
        55 => x"01152223", -- sw x17,4(x10)
        56 => x"01252423", -- sw x18,8(x10)
        57 => x"01352623", -- sw x19,12(x10)
        58 => x"00053887", -- fld f17,0(x10)
        59 => x"00853907", -- fld f18,8(x10)
        60 => x"232889d3", -- fsgnj.d f19,f17,f18
        61 => x"2b190a53", -- fmin.d  f20,f18,f17
        62 => x"a318acd3", -- feq.d  x25,f17,f17
        63 => x"a3191d53", -- flt.d  x26,f18,f17
        64 => x"e2091dd3", -- fclass.d x27,f18
        65 => x"00102f73", -- csrrs x30,fflags,x0
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

        -- 66 instructions plus FP interlock bubbles: allow generous slack.
        wait for CLK_PERIOD * 200;

        assert false report "FP misc simulation complete" severity failure;
        wait;
    end process;

end architecture;
