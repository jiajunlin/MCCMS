library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.all;

-- FP conversion regression (M5): fcvt int<->float and single<->double, all five rounding
-- modes, float->int saturation (NV) on NaN/inf/out-of-range, NX on inexact int results and
-- on narrowing, exact int->double and single->double widening. FP results are captured from
-- the FP writeback stream; per-op exception flags (NX/OF/UF/NV) are isolated by clearing
-- fflags before an op and reading them after into integer regs. Because the program is longer
-- than the arithmetic one, the data region base is 0x280 (RAM word 160), above the code.
entity riscv_fcvt_tb is
end entity;

architecture sim of riscv_fcvt_tb is

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
        0  => x"000000b7", -- lui  x1,0x00000
        1  => x"00508093", -- addi x1,x1,5
        2  => x"d0008053", -- fcvt.s.w  f0,x1
        3  => x"d20080d3", -- fcvt.d.w  f1,x1
        4  => x"000000b7", -- lui  x1,0x00000
        5  => x"ff908093", -- addi x1,x1,-7
        6  => x"d0008153", -- fcvt.s.w  f2,x1
        7  => x"d20081d3", -- fcvt.d.w  f3,x1
        8  => x"800000b7", -- lui  x1,0x80000
        9  => x"00008093", -- addi x1,x1,0
        10 => x"d0008253", -- fcvt.s.w  f4,x1
        11 => x"d01082d3", -- fcvt.s.wu f5,x1
        12 => x"d2008353", -- fcvt.d.w  f6,x1
        13 => x"d21083d3", -- fcvt.d.wu f7,x1
        14 => x"000000b7", -- lui  x1,0x00000
        15 => x"fff08093", -- addi x1,x1,-1
        16 => x"001ff073", -- csrrci x0,fflags,0x1f
        17 => x"d0108453", -- fcvt.s.wu f8,x1
        18 => x"00102173", -- csrrs x2,fflags,x0
        19 => x"d21084d3", -- fcvt.d.wu f9,x1
        20 => x"010000b7", -- lui  x1,0x01000
        21 => x"00108093", -- addi x1,x1,1
        22 => x"001ff073", -- csrrci x0,fflags,0x1f
        23 => x"d0008553", -- fcvt.s.w  f10,x1
        24 => x"001021f3", -- csrrs x3,fflags,x0
        25 => x"d20085d3", -- fcvt.d.w  f11,x1
        26 => x"402000b7", -- lui  x1,0x40200
        27 => x"00008093", -- addi x1,x1,0
        28 => x"f0008653", -- fmv.w.x f12,x1
        29 => x"c02000b7", -- lui  x1,0xc0200
        30 => x"00008093", -- addi x1,x1,0
        31 => x"f00086d3", -- fmv.w.x f13,x1
        32 => x"406000b7", -- lui  x1,0x40600
        33 => x"00008093", -- addi x1,x1,0
        34 => x"f0008753", -- fmv.w.x f14,x1
        35 => x"7fc000b7", -- lui  x1,0x7fc00
        36 => x"00008093", -- addi x1,x1,0
        37 => x"f00087d3", -- fmv.w.x f15,x1
        38 => x"7f8000b7", -- lui  x1,0x7f800
        39 => x"00008093", -- addi x1,x1,0
        40 => x"f0008853", -- fmv.w.x f16,x1
        41 => x"ff8000b7", -- lui  x1,0xff800
        42 => x"00008093", -- addi x1,x1,0
        43 => x"f00088d3", -- fmv.w.x f17,x1
        44 => x"bf0000b7", -- lui  x1,0xbf000
        45 => x"00008093", -- addi x1,x1,0
        46 => x"f0008953", -- fmv.w.x f18,x1
        47 => x"4f0000b7", -- lui  x1,0x4f000
        48 => x"00008093", -- addi x1,x1,0
        49 => x"f00089d3", -- fmv.w.x f19,x1
        50 => x"500000b7", -- lui  x1,0x50000
        51 => x"00008093", -- addi x1,x1,0
        52 => x"f0008a53", -- fmv.w.x f20,x1
        53 => x"001ff073", -- csrrci x0,fflags,0x1f
        54 => x"c0060a53", -- fcvt.w.s  x20,f12,rne
        55 => x"00102273", -- csrrs x4,fflags,x0
        56 => x"c0061ad3", -- fcvt.w.s  x21,f12,rtz
        57 => x"c0063b53", -- fcvt.w.s  x22,f12,rup
        58 => x"c006abd3", -- fcvt.w.s  x23,f13,rdn
        59 => x"c006cc53", -- fcvt.w.s  x24,f13,rmm
        60 => x"c0070cd3", -- fcvt.w.s  x25,f14,rne
        61 => x"001ff073", -- csrrci x0,fflags,0x1f
        62 => x"c0078d53", -- fcvt.w.s  x26,f15
        63 => x"001025f3", -- csrrs x11,fflags,x0
        64 => x"c0178dd3", -- fcvt.wu.s x27,f15
        65 => x"c0080e53", -- fcvt.w.s  x28,f16
        66 => x"c0088ed3", -- fcvt.w.s  x29,f17
        67 => x"c0188f53", -- fcvt.wu.s x30,f17
        68 => x"001ff073", -- csrrci x0,fflags,0x1f
        69 => x"c0190fd3", -- fcvt.wu.s x31,f18
        70 => x"00102673", -- csrrs x12,fflags,x0
        71 => x"001ff073", -- csrrci x0,fflags,0x1f
        72 => x"c00982d3", -- fcvt.w.s  x5,f19
        73 => x"001026f3", -- csrrs x13,fflags,x0
        74 => x"c0198353", -- fcvt.wu.s x6,f19
        75 => x"c01a03d3", -- fcvt.wu.s x7,f20
        76 => x"00000537", -- lui  x10,0x00000
        77 => x"28050513", -- addi x10,x10,640
        78 => x"00000837", -- lui  x16,0x00000
        79 => x"00080813", -- addi x16,x16,0
        80 => x"400408b7", -- lui  x17,0x40040
        81 => x"00088893", -- addi x17,x17,0
        82 => x"01052023", -- sw x16,0(x10)
        83 => x"01152223", -- sw x17,4(x10)
        84 => x"00000837", -- lui  x16,0x00000
        85 => x"00080813", -- addi x16,x16,0
        86 => x"c00408b7", -- lui  x17,0xc0040
        87 => x"00088893", -- addi x17,x17,0
        88 => x"01052423", -- sw x16,8(x10)
        89 => x"01152623", -- sw x17,12(x10)
        90 => x"20000837", -- lui  x16,0x20000
        91 => x"00080813", -- addi x16,x16,0
        92 => x"4202a8b7", -- lui  x17,0x4202a
        93 => x"05f88893", -- addi x17,x17,95
        94 => x"01052823", -- sw x16,16(x10)
        95 => x"01152a23", -- sw x17,20(x10)
        96 => x"00000837", -- lui  x16,0x00000
        97 => x"00080813", -- addi x16,x16,0
        98 => x"7ff808b7", -- lui  x17,0x7ff80
        99 => x"00088893", -- addi x17,x17,0
        100=> x"01052c23", -- sw x16,24(x10)
        101=> x"01152e23", -- sw x17,28(x10)
        102=> x"00053a87", -- fld f21,0(x10)
        103=> x"00853b07", -- fld f22,8(x10)
        104=> x"01053b87", -- fld f23,16(x10)
        105=> x"01853c07", -- fld f24,24(x10)
        106=> x"c20a8453", -- fcvt.w.d  x8,f21,rne
        107=> x"c20b24d3", -- fcvt.w.d  x9,f22,rdn
        108=> x"c21b8953", -- fcvt.wu.d x18,f23
        109=> x"c20b89d3", -- fcvt.w.d  x19,f23
        110=> x"c20c0753", -- fcvt.w.d  x14,f24
        111=> x"3dccd0b7", -- lui  x1,0x3dccd
        112=> x"ccd08093", -- addi x1,x1,-819
        113=> x"f0008053", -- fmv.w.x f0,x1
        114=> x"42060cd3", -- fcvt.d.s  f25,f12
        115=> x"42000d53", -- fcvt.d.s  f26,f0
        116=> x"9999a837", -- lui  x16,0x9999a
        117=> x"99a80813", -- addi x16,x16,-1638
        118=> x"3fb9a8b7", -- lui  x17,0x3fb9a
        119=> x"99988893", -- addi x17,x17,-1639
        120=> x"03052023", -- sw x16,32(x10)
        121=> x"03152223", -- sw x17,36(x10)
        122=> x"88007837", -- lui  x16,0x88007
        123=> x"59c80813", -- addi x16,x16,1436
        124=> x"7e37e8b7", -- lui  x17,0x7e37e
        125=> x"43c88893", -- addi x17,x17,1084
        126=> x"03052423", -- sw x16,40(x10)
        127=> x"03152623", -- sw x17,44(x10)
        128=> x"b1553837", -- lui  x16,0xb1553
        129=> x"d8380813", -- addi x16,x16,-637
        130=> x"37d5c8b7", -- lui  x17,0x37d5c
        131=> x"72f88893", -- addi x17,x17,1839
        132=> x"03052823", -- sw x16,48(x10)
        133=> x"03152a23", -- sw x17,52(x10)
        134=> x"02053d87", -- fld f27,32(x10)
        135=> x"02853e07", -- fld f28,40(x10)
        136=> x"03053e87", -- fld f29,48(x10)
        137=> x"001ff073", -- csrrci x0,fflags,0x1f
        138=> x"401d8f53", -- fcvt.s.d  f30,f27
        139=> x"001027f3", -- csrrs x15,fflags,x0
        140=> x"401a8fd3", -- fcvt.s.d  f31,f21
        141=> x"001ff073", -- csrrci x0,fflags,0x1f
        142=> x"401e0453", -- fcvt.s.d  f8,f28
        143=> x"00102a73", -- csrrs x20,fflags,x0
        144=> x"001ff073", -- csrrci x0,fflags,0x1f
        145=> x"401e84d3", -- fcvt.s.d  f9,f29
        146=> x"00102af3", -- csrrs x21,fflags,x0
        147=> x"0000006f", -- j .
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

        -- 147 instructions plus FP interlock bubbles: allow generous slack.
        wait for CLK_PERIOD * 700;

        assert false report "FP conversion simulation complete" severity failure;
        wait;
    end process;

end architecture;
