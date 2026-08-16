library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.all;

-- Zicsr / FCSR regression: csrrw/s/c and immediate forms against fcsr/fflags/frm,
-- including back-to-back read-after-write on the same CSR and set/clear no-write (rs1=x0).
entity riscv_csr_tb is
end entity;

architecture sim of riscv_csr_tb is

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
        0  => x"01500093", -- addi  x1,x0,0x15
        1  => x"00309173", -- csrrw x2,fcsr,x1
        2  => x"003021f3", -- csrrs x3,fcsr,x0
        3  => x"00e00213", -- addi  x4,x0,0x0E
        4  => x"001232f3", -- csrrc x5,fflags,x4
        5  => x"00102373", -- csrrs x6,fflags,x0
        6  => x"00700393", -- addi  x7,x0,7
        7  => x"00239473", -- csrrw x8,frm,x7
        8  => x"003024f3", -- csrrs x9,fcsr,x0
        9  => x"0021d573", -- csrrwi x10,frm,3
        10 => x"0010e5f3", -- csrrsi x11,fflags,1
        11 => x"0018f673", -- csrrci x12,fflags,0x11
        12 => x"003026f3", -- csrrs x13,fcsr,x0
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

        wait for CLK_PERIOD * 40;

        assert false report "Zicsr/FCSR simulation complete" severity failure;
        wait;
    end process;

end architecture;
