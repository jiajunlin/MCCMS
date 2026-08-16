library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.all;

-- FP divide / square root regression (M6): fdiv.s/fdiv.d and fsqrt.s/fsqrt.d covering exact and
-- inexact results, several rounding modes, and the special/exception cases (x/0 -> DZ, 0/0 and
-- sqrt(neg) -> NV, overflow -> OF|NX). These are multi-cycle ops, so the run also exercises the
-- pipeline freeze (ex_stall) and single-shot fflags accrual. FP results are captured from the FP
-- writeback stream; per-op exception flags are isolated by clearing fflags before an op and
-- reading them after into integer regs. Data region base is 0x200 (RAM word 128), above the code.
entity riscv_fdivsqrt_tb is
end entity;

architecture sim of riscv_fdivsqrt_tb is

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
        2  => x"f0008053", -- fmv.w.x f0,x1  # 1.0
        3  => x"404000b7", -- lui  x1,0x40400
        4  => x"00008093", -- addi x1,x1,0
        5  => x"f00080d3", -- fmv.w.x f1,x1  # 3.0
        6  => x"40e000b7", -- lui  x1,0x40e00
        7  => x"00008093", -- addi x1,x1,0
        8  => x"f0008153", -- fmv.w.x f2,x1  # 7.0
        9  => x"400000b7", -- lui  x1,0x40000
        10 => x"00008093", -- addi x1,x1,0
        11 => x"f00081d3", -- fmv.w.x f3,x1  # 2.0
        12 => x"000000b7", -- lui  x1,0x00000
        13 => x"00008093", -- addi x1,x1,0
        14 => x"f0008253", -- fmv.w.x f4,x1  # 0.0
        15 => x"bf8000b7", -- lui  x1,0xbf800
        16 => x"00008093", -- addi x1,x1,0
        17 => x"f00082d3", -- fmv.w.x f5,x1  # -1.0
        18 => x"408000b7", -- lui  x1,0x40800
        19 => x"00008093", -- addi x1,x1,0
        20 => x"f0008353", -- fmv.w.x f6,x1  # 4.0
        21 => x"411000b7", -- lui  x1,0x41100
        22 => x"00008093", -- addi x1,x1,0
        23 => x"f00083d3", -- fmv.w.x f7,x1  # 9.0
        24 => x"18100453", -- fdiv.s f8,f0,f1,rne
        25 => x"181014d3", -- fdiv.s f9,f0,f1,rtz
        26 => x"18103553", -- fdiv.s f10,f0,f1,rup
        27 => x"183105d3", -- fdiv.s f11,f2,f3
        28 => x"001ff073", -- csrrci x0,fflags,0x1f
        29 => x"18400653", -- fdiv.s f12,f0,f4
        30 => x"001022f3", -- csrrs x5,fflags,x0
        31 => x"184286d3", -- fdiv.s f13,f5,f4
        32 => x"001ff073", -- csrrci x0,fflags,0x1f
        33 => x"18420753", -- fdiv.s f14,f4,f4
        34 => x"00102373", -- csrrs x6,fflags,x0
        35 => x"580307d3", -- fsqrt.s f15,f6
        36 => x"58018853", -- fsqrt.s f16,f3
        37 => x"580388d3", -- fsqrt.s f17,f7
        38 => x"001ff073", -- csrrci x0,fflags,0x1f
        39 => x"58028953", -- fsqrt.s f18,f5
        40 => x"001023f3", -- csrrs x7,fflags,x0
        41 => x"00000537", -- lui  x10,0x00000
        42 => x"20050513", -- addi x10,x10,512
        43 => x"00000837", -- lui  x16,0x00000
        44 => x"00080813", -- addi x16,x16,0
        45 => x"01052023", -- sw x16,0(x10)
        46 => x"3ff008b7", -- lui  x17,0x3ff00
        47 => x"00088893", -- addi x17,x17,0
        48 => x"01152223", -- sw x17,4(x10)
        49 => x"00053a07", -- fld f20,0(x10)  # 1.0
        50 => x"00000837", -- lui  x16,0x00000
        51 => x"00080813", -- addi x16,x16,0
        52 => x"01052423", -- sw x16,8(x10)
        53 => x"400808b7", -- lui  x17,0x40080
        54 => x"00088893", -- addi x17,x17,0
        55 => x"01152623", -- sw x17,12(x10)
        56 => x"00853a87", -- fld f21,8(x10)  # 3.0
        57 => x"00000837", -- lui  x16,0x00000
        58 => x"00080813", -- addi x16,x16,0
        59 => x"01052823", -- sw x16,16(x10)
        60 => x"400008b7", -- lui  x17,0x40000
        61 => x"00088893", -- addi x17,x17,0
        62 => x"01152a23", -- sw x17,20(x10)
        63 => x"01053b07", -- fld f22,16(x10)  # 2.0
        64 => x"00000837", -- lui  x16,0x00000
        65 => x"00080813", -- addi x16,x16,0
        66 => x"01052c23", -- sw x16,24(x10)
        67 => x"401008b7", -- lui  x17,0x40100
        68 => x"00088893", -- addi x17,x17,0
        69 => x"01152e23", -- sw x17,28(x10)
        70 => x"01853b87", -- fld f23,24(x10)  # 4.0
        71 => x"88007837", -- lui  x16,0x88007
        72 => x"59c80813", -- addi x16,x16,1436
        73 => x"03052023", -- sw x16,32(x10)
        74 => x"7e37e8b7", -- lui  x17,0x7e37e
        75 => x"43c88893", -- addi x17,x17,1084
        76 => x"03152223", -- sw x17,36(x10)
        77 => x"02053c07", -- fld f24,32(x10)  # 1e+300
        78 => x"c2f8f837", -- lui  x16,0xc2f8f
        79 => x"35980813", -- addi x16,x16,857
        80 => x"03052423", -- sw x16,40(x10)
        81 => x"01a578b7", -- lui  x17,0x01a57
        82 => x"e1f88893", -- addi x17,x17,-481
        83 => x"03152623", -- sw x17,44(x10)
        84 => x"02853c87", -- fld f25,40(x10)  # 1e-300
        85 => x"1b5a0d53", -- fdiv.d f26,f20,f21,rne
        86 => x"1b5a1dd3", -- fdiv.d f27,f20,f21,rtz
        87 => x"1b7b0e53", -- fdiv.d f28,f22,f23
        88 => x"001ff073", -- csrrci x0,fflags,0x1f
        89 => x"1b9c0ed3", -- fdiv.d f29,f24,f25
        90 => x"00102473", -- csrrs x8,fflags,x0
        91 => x"5a0b0f53", -- fsqrt.d f30,f22
        92 => x"5a0b8fd3", -- fsqrt.d f31,f23
        93 => x"0000006f", -- j .
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

        -- 94 instructions plus long div/sqrt latencies and FP interlock bubbles: generous slack.
        wait for CLK_PERIOD * 800;

        assert false report "FP divide/sqrt simulation complete" severity failure;
        wait;
    end process;

end architecture;
