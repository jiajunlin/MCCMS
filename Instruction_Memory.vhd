library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity Instruction_Memory is
	port(
		address : in STD_LOGIC_VECTOR(31 downto 0);
		Instruction : out STD_LOGIC_VECTOR(31 downto 0)
		);
end Instruction_Memory;



architecture behavorial of Instruction_Memory is  
	type mem_type is array (0 to 255) of STD_logic_vector(31 downto 0);
	constant Memory_Array : mem_type := (others => (others => '0'));
begin	
	-- word index = Address / 4 = Address(9 downto 2) for 256 words
	Instruction <= Memory_Array(to_integer(unsigned(Address(9 downto 2))));
end behavorial;
