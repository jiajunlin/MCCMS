library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.all;

-- Fused multiply-add regression (M7): fmadd/fmsub/fnmsub/fnmadd for single and double, covering
-- exact and fused-inexact results, exact cancellation, a rounding mode (RUP), and the special/
-- exception cases (overflow -> OF|NX, inf*0 -> NV). FMA is single-cycle combinational (like
-- fadd/fmul), and reads three FP source registers (rs1/rs2/rs3), exercising the 3rd read port and
-- the FP interlock (f8 producer -> f15 consumer). FP results captured from the FP writeback stream;
-- per-op exception flags isolated via csrrci/csrrs into integer regs. Data base 0x200 (RAM word 128).
entity riscv_fma_tb is
end entity;

architecture sim of riscv_fma_tb is

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
        0  => x"400000b7", -- lui  x1,0x40000
        1  => x"00008093", -- addi x1,x1,0
        2  => x"f0008053", -- fmv.w.x f0,x1  # 2.0
        3  => x"404000b7", -- lui  x1,0x40400
        4  => x"00008093", -- addi x1,x1,0
        5  => x"f00080d3", -- fmv.w.x f1,x1  # 3.0
        6  => x"3f8000b7", -- lui  x1,0x3f800
        7  => x"00008093", -- addi x1,x1,0
        8  => x"f0008153", -- fmv.w.x f2,x1  # 1.0
        9  => x"3fc000b7", -- lui  x1,0x3fc00
        10 => x"00008093", -- addi x1,x1,0
        11 => x"f00081d3", -- fmv.w.x f3,x1  # 1.5
        12 => x"000000b7", -- lui  x1,0x00000
        13 => x"00008093", -- addi x1,x1,0
        14 => x"f0008253", -- fmv.w.x f4,x1  # 0.0
        15 => x"7149f0b7", -- lui  x1,0x7149f
        16 => x"2ca08093", -- addi x1,x1,714
        17 => x"f00082d3", -- fmv.w.x f5,x1  # 1e+30
        18 => x"3dccd0b7", -- lui  x1,0x3dccd
        19 => x"ccd08093", -- addi x1,x1,-819
        20 => x"f0008353", -- fmv.w.x f6,x1  # 0.1
        21 => x"3e4cd0b7", -- lui  x1,0x3e4cd
        22 => x"ccd08093", -- addi x1,x1,-819
        23 => x"f00083d3", -- fmv.w.x f7,x1  # 0.2
        24 => x"10100443", -- fmadd.s  f8,f0,f1,f2
        25 => x"003184c7", -- fmsub.s  f9,f3,f3,f0
        26 => x"1010054b", -- fnmsub.s f10,f0,f1,f2
        27 => x"101005cf", -- fnmadd.s f11,f0,f1,f2
        28 => x"38130643", -- fmadd.s  f12,f6,f1,f7
        29 => x"202407c3", -- fmadd.s  f15,f8,f2,f4
        30 => x"001ff073", -- csrrci x0,fflags,0x1f
        31 => x"205286c3", -- fmadd.s f13,f5,f5,f4
        32 => x"001022f3", -- csrrs x5,fflags,x0
        33 => x"001ff073", -- csrrci x0,fflags,0x1f
        34 => x"20633743", -- fmadd.s f14,f6,f6,f4,rup
        35 => x"001024f3", -- csrrs x9,fflags,x0
        36 => x"00000537", -- lui  x10,0x00000
        37 => x"20050513", -- addi x10,x10,512
        38 => x"00000837", -- lui  x16,0x00000
        39 => x"00080813", -- addi x16,x16,0
        40 => x"01052023", -- sw x16,0(x10)
        41 => x"400008b7", -- lui  x17,0x40000
        42 => x"00088893", -- addi x17,x17,0
        43 => x"01152223", -- sw x17,4(x10)
        44 => x"00053a07", -- fld f20,0(x10)
        45 => x"00000837", -- lui  x16,0x00000
        46 => x"00080813", -- addi x16,x16,0
        47 => x"01052423", -- sw x16,8(x10)
        48 => x"400808b7", -- lui  x17,0x40080
        49 => x"00088893", -- addi x17,x17,0
        50 => x"01152623", -- sw x17,12(x10)
        51 => x"00853a87", -- fld f21,8(x10)
        52 => x"00000837", -- lui  x16,0x00000
        53 => x"00080813", -- addi x16,x16,0
        54 => x"01052823", -- sw x16,16(x10)
        55 => x"3ff008b7", -- lui  x17,0x3ff00
        56 => x"00088893", -- addi x17,x17,0
        57 => x"01152a23", -- sw x17,20(x10)
        58 => x"01053b07", -- fld f22,16(x10)
        59 => x"00000837", -- lui  x16,0x00000
        60 => x"00180813", -- addi x16,x16,1
        61 => x"01052c23", -- sw x16,24(x10)
        62 => x"3ff008b7", -- lui  x17,0x3ff00
        63 => x"00088893", -- addi x17,x17,0
        64 => x"01152e23", -- sw x17,28(x10)
        65 => x"01853b87", -- fld f23,24(x10)
        66 => x"88007837", -- lui  x16,0x88007
        67 => x"59c80813", -- addi x16,x16,1436
        68 => x"03052023", -- sw x16,32(x10)
        69 => x"7e37e8b7", -- lui  x17,0x7e37e
        70 => x"43c88893", -- addi x17,x17,1084
        71 => x"03152223", -- sw x17,36(x10)
        72 => x"02053c07", -- fld f24,32(x10)
        73 => x"00000837", -- lui  x16,0x00000
        74 => x"00080813", -- addi x16,x16,0
        75 => x"03052423", -- sw x16,40(x10)
        76 => x"000008b7", -- lui  x17,0x00000
        77 => x"00088893", -- addi x17,x17,0
        78 => x"03152623", -- sw x17,44(x10)
        79 => x"02853c87", -- fld f25,40(x10)
        80 => x"00000837", -- lui  x16,0x00000
        81 => x"00080813", -- addi x16,x16,0
        82 => x"03052823", -- sw x16,48(x10)
        83 => x"7ff008b7", -- lui  x17,0x7ff00
        84 => x"00088893", -- addi x17,x17,0
        85 => x"03152a23", -- sw x17,52(x10)
        86 => x"03053d07", -- fld f26,48(x10)
        87 => x"00000837", -- lui  x16,0x00000
        88 => x"00080813", -- addi x16,x16,0
        89 => x"03052c23", -- sw x16,56(x10)
        90 => x"401008b7", -- lui  x17,0x40100
        91 => x"00088893", -- addi x17,x17,0
        92 => x"03152e23", -- sw x17,60(x10)
        93 => x"03853d87", -- fld f27,56(x10)
        94 => x"b35a0843", -- fmadd.d  f16,f20,f21,f22
        95 => x"b35a08c7", -- fmsub.d  f17,f20,f21,f22
        96 => x"b35a094b", -- fnmsub.d f18,f20,f21,f22
        97 => x"b35a09cf", -- fnmadd.d f19,f20,f21,f22
        98 => x"b37b8e47", -- fmsub.d  f28,f23,f23,f22
        99 => x"b36b0ec7", -- fmsub.d  f29,f22,f22,f22
        100=> x"001ff073", -- csrrci x0,fflags,0x1f
        101=> x"cb8c0f43", -- fmadd.d f30,f24,f24,f25
        102=> x"00102373", -- csrrs x6,fflags,x0
        103=> x"001ff073", -- csrrci x0,fflags,0x1f
        104=> x"b39d0fc3", -- fmadd.d f31,f26,f25,f22
        105=> x"001023f3", -- csrrs x7,fflags,x0
        106=> x"0000006f", -- j .
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

        wait for CLK_PERIOD * 800;

        assert false report "FP fused multiply-add simulation complete" severity failure;
        wait;
    end process;

end architecture;
