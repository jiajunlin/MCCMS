library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.all;

-- FP arithmetic regression (M4b): fadd/fsub/fmul on single and double covering exact/inexact
-- results, all five rounding modes (static + dynamic via frm), overflow -> inf, gradual
-- underflow / flush-to-zero, signed-zero cancellation, inf and inf-inf / sNaN invalid cases.
-- FP results are captured from the FP writeback stream; per-op exception flags (NX/OF/UF/NV)
-- are isolated by clearing fflags before an op and reading them after into integer regs.
-- Doubles are built in memory at base 0x200.
entity riscv_farith_tb is
end entity;

architecture sim of riscv_farith_tb is

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
        3  => x"400000b7", -- lui  x1,0x40000
        4  => x"00008093", -- addi x1,x1,0
        5  => x"f00080d3", -- fmv.w.x f1,x1  # 2.0
        6  => x"404000b7", -- lui  x1,0x40400
        7  => x"00008093", -- addi x1,x1,0
        8  => x"f0008153", -- fmv.w.x f2,x1  # 3.0
        9  => x"c00000b7", -- lui  x1,0xc0000
        10 => x"00008093", -- addi x1,x1,0
        11 => x"f00081d3", -- fmv.w.x f3,x1  # -2.0
        12 => x"3dccd0b7", -- lui  x1,0x3dccd
        13 => x"ccd08093", -- addi x1,x1,-819
        14 => x"f0008253", -- fmv.w.x f4,x1  # 0.1
        15 => x"3e4cd0b7", -- lui  x1,0x3e4cd
        16 => x"ccd08093", -- addi x1,x1,-819
        17 => x"f00082d3", -- fmv.w.x f5,x1  # 0.2
        18 => x"7f0000b7", -- lui  x1,0x7f000
        19 => x"00008093", -- addi x1,x1,0
        20 => x"f0008353", -- fmv.w.x f6,x1  # big
        21 => x"7f8000b7", -- lui  x1,0x7f800
        22 => x"00008093", -- addi x1,x1,0
        23 => x"f00083d3", -- fmv.w.x f7,x1  # +inf
        24 => x"7f8000b7", -- lui  x1,0x7f800
        25 => x"00108093", -- addi x1,x1,1
        26 => x"f0008453", -- fmv.w.x f8,x1  # sNaN
        27 => x"008000b7", -- lui  x1,0x00800
        28 => x"00008093", -- addi x1,x1,0
        29 => x"f00084d3", -- fmv.w.x f9,x1  # minN
        30 => x"00100553", -- fadd.s f10,f0,f1
        31 => x"081005d3", -- fsub.s f11,f0,f1
        32 => x"10208653", -- fmul.s f12,f1,f2
        33 => x"00300753", -- fadd.s f14,f0,f3
        34 => x"080008d3", -- fsub.s f17,f0,f0
        35 => x"00738953", -- fadd.s f18,f7,f7
        36 => x"001ff073", -- csrrci x0,fflags,0x1f
        37 => x"004286d3", -- fadd.s f13,f5,f4
        38 => x"001022f3", -- csrrs x5,fflags,x0
        39 => x"001ff073", -- csrrci x0,fflags,0x1f
        40 => x"106307d3", -- fmul.s f15,f6,f6
        41 => x"00102373", -- csrrs x6,fflags,x0
        42 => x"001ff073", -- csrrci x0,fflags,0x1f
        43 => x"10948853", -- fmul.s f16,f9,f9
        44 => x"001023f3", -- csrrs x7,fflags,x0
        45 => x"001ff073", -- csrrci x0,fflags,0x1f
        46 => x"087389d3", -- fsub.s f19,f7,f7
        47 => x"00102473", -- csrrs x8,fflags,x0
        48 => x"00429a53", -- fadd.s f20,f5,f4,rtz
        49 => x"0042aad3", -- fadd.s f21,f5,f4,rdn
        50 => x"0042bb53", -- fadd.s f22,f5,f4,rup
        51 => x"0042cbd3", -- fadd.s f23,f5,f4,rmm
        52 => x"0021d073", -- csrrwi x0,frm,3
        53 => x"0042fc53", -- fadd.s f24,f5,f4,dyn
        54 => x"00205073", -- csrrwi x0,frm,0
        55 => x"00000537", -- lui  x10,0x00000
        56 => x"20050513", -- addi x10,x10,512
        57 => x"00000837", -- lui  x16,0x00000
        58 => x"00080813", -- addi x16,x16,0
        59 => x"3ff808b7", -- lui  x17,0x3ff80
        60 => x"00088893", -- addi x17,x17,0
        61 => x"01052023", -- sw x16,0(x10)
        62 => x"01152223", -- sw x17,4(x10)
        63 => x"00000837", -- lui  x16,0x00000
        64 => x"00080813", -- addi x16,x16,0
        65 => x"3fe008b7", -- lui  x17,0x3fe00
        66 => x"00088893", -- addi x17,x17,0
        67 => x"01052423", -- sw x16,8(x10)
        68 => x"01152623", -- sw x17,12(x10)
        69 => x"9999a837", -- lui  x16,0x9999a
        70 => x"99a80813", -- addi x16,x16,-1638
        71 => x"3fb9a8b7", -- lui  x17,0x3fb9a
        72 => x"99988893", -- addi x17,x17,-1639
        73 => x"01052823", -- sw x16,16(x10)
        74 => x"01152a23", -- sw x17,20(x10)
        75 => x"9999a837", -- lui  x16,0x9999a
        76 => x"99a80813", -- addi x16,x16,-1638
        77 => x"3fc9a8b7", -- lui  x17,0x3fc9a
        78 => x"99988893", -- addi x17,x17,-1639
        79 => x"01052c23", -- sw x16,24(x10)
        80 => x"01152e23", -- sw x17,28(x10)
        81 => x"00053c87", -- fld f25,0(x10)
        82 => x"00853d07", -- fld f26,8(x10)
        83 => x"01053d87", -- fld f27,16(x10)
        84 => x"01853e07", -- fld f28,24(x10)
        85 => x"03ac8ed3", -- fadd.d f29,f25,f26
        86 => x"13ac8f53", -- fmul.d f30,f25,f26
        87 => x"0b9d0fd3", -- fsub.d f31,f26,f25
        88 => x"03cd8453", -- fadd.d f8,f27,f28
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

        -- 89 instructions plus FP interlock bubbles: allow generous slack.
        wait for CLK_PERIOD * 260;

        assert false report "FP arithmetic simulation complete" severity failure;
        wait;
    end process;

end architecture;
