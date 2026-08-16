library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

-- 32 x 64-bit floating-point register file (FLEN=64). Unlike the integer file, f0 is a
-- normal read/write register (no hardwired zero). Three combinational read ports (rs1/rs2,
-- plus rs3 for the fused multiply-add family) with a write-first bypass so a value committed
-- in WB is visible to an instruction reading in ID on the same cycle -- this is what lets the
-- FP interlock release after the producer reaches WB without a dedicated forwarding network.
entity fp_register_file is
    port(
        clk        : in  std_logic;
        reset      : in  std_logic;
        fp_write   : in  std_logic;
        read_reg1  : in  std_logic_vector(4 downto 0);
        read_reg2  : in  std_logic_vector(4 downto 0);
        read_reg3  : in  std_logic_vector(4 downto 0);
        write_reg  : in  std_logic_vector(4 downto 0);
        write_data : in  std_logic_vector(63 downto 0);
        read_data1 : out std_logic_vector(63 downto 0);
        read_data2 : out std_logic_vector(63 downto 0);
        read_data3 : out std_logic_vector(63 downto 0)
        );
end fp_register_file;

architecture behavioral of fp_register_file is
    type reg_array is array (0 to 31) of std_logic_vector(63 downto 0);
    signal registers : reg_array := (others => (others => '0'));
begin
    -- Sequential write
    writing: process(clk, reset)
    begin
        if reset = '1' then
            registers <= (others => (others => '0'));
        elsif rising_edge(clk) then
            if fp_write = '1' then
                registers(to_integer(unsigned(write_reg))) <= write_data;
            end if;
        end if;
    end process;

    -- Combinational read with write-first bypass
    read_data1 <= write_data when (fp_write = '1' and read_reg1 = write_reg) else
                  registers(to_integer(unsigned(read_reg1)));

    read_data2 <= write_data when (fp_write = '1' and read_reg2 = write_reg) else
                  registers(to_integer(unsigned(read_reg2)));

    read_data3 <= write_data when (fp_write = '1' and read_reg3 = write_reg) else
                  registers(to_integer(unsigned(read_reg3)));
end behavioral;
