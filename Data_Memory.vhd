library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity data_memory is
    port(
        clk        : in  std_logic;
        mem_read   : in  std_logic;
        mem_write  : in  std_logic;
        address    : in  std_logic_vector(31 downto 0);
        write_data : in  std_logic_vector(31 downto 0);
        read_data  : out std_logic_vector(31 downto 0)
    );
end entity;

architecture behavioral of data_memory is
    -- Simple 64-word memory array for simulation (256 bytes)
    type ram_type is array (0 to 255) of std_logic_vector(31 downto 0);
    signal ram : ram_type := (others => (others => '0'));
    
    signal word_addr : integer;
begin
    -- Shift address right by 2 because RAM is word-addressed (32-bit words)
    word_addr <= to_integer(unsigned(address(9 downto 2)));

    -- Synchronous Write
    process(clk)
    begin
        if rising_edge(clk) then
            if mem_write = '1' then
                ram(word_addr) <= write_data;
            end if;
        end if;
    end process;

    -- Asynchronous Read
    read_data <= ram(word_addr) when mem_read = '1' else (others => '0');
end architecture;