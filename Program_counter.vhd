library ieee;
use ieee.std_logic_1164.all;

entity Program_counter is
    port(
        clk        : in  std_logic;
        reset      : in  std_logic;
        en         : in  std_logic; -- Add this line to your entity file!
        pc_next    : in  std_logic_vector(31 downto 0);
        pc_current : out std_logic_vector(31 downto 0)
    );
end entity;

architecture behavioral of Program_counter is
begin
    process(clk, reset)
    begin
        if reset = '1' then
            pc_current <= (others => '0');
        elsif rising_edge(clk) then
            if en = '1' then -- Only update PC if memory subsystem is ready
                pc_current <= pc_next;
            end if;
        end if;
    end process;
end architecture;