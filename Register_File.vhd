-------------------------------------------------------------------------------
--
-- Title       : Register_File
-- Design      : MCCCMS
-- Author      : jiajun.lin@stonybrook.edu
-- Company     : Stony Brook University
--
-------------------------------------------------------------------------------
--
-- File        : C:/Users/jlin7/Desktop/Multi-Core Cache Coherent Memory System/MCCCMS/MCCCMS/src/Register_File.vhd
-- Generated   : Mon May 25 18:02:50 2026
-- From        : Interface description file
-- By          : ItfToHdl ver. 1.0
--
-------------------------------------------------------------------------------
--
-- Description : 
--
-------------------------------------------------------------------------------

--{{ Section below this comment is automatically maintained
--    and may be overwritten
--{entity {Register_File} architecture {Behavioral}}

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity Register_File is
	port(
		clk         : in  std_logic;		   
		reset       : in  std_logic; 
		reg_write   : in  std_logic;                      -- Write enable control signal
		read_reg1   : in  std_logic_vector(4 downto 0);   -- rs1 (5 bits for 32 registers)
		read_reg2   : in  std_logic_vector(4 downto 0);   -- rs2
		write_reg   : in  std_logic_vector(4 downto 0);   -- rd
		write_data  : in  std_logic_vector(31 downto 0);  -- Data to be written
		read_data1  : out std_logic_vector(31 downto 0);  -- Data from rs1
		read_data2  : out std_logic_vector(31 downto 0)   -- Data from rs2
		);
end Register_File;


architecture Behavioral of Register_File is	
	type reg_array is array (0 to 31) of std_logic_vector(31 downto 0);		 			-- 32 by 32 number by width
	signal registers : reg_array := (others => (others=>'0'));
begin	
	-- Sequential Write 
	writing: process(clk, reset)
	begin
		if reset = '1' then
			registers <= (others => (others=>'0'));
		elsif rising_edge(clk) then
			if reg_write = '1' and to_integer(unsigned(write_reg)) /= 0 then
				registers(to_integer(unsigned(write_reg))) <= write_data;
			end if;	 
		end if;
	end process;
	
	-- Combinational Read
	read_data1 <= (others=>'0') when (to_integer(unsigned(read_reg1)) = 0) else 
	write_data    when (reg_write = '1' and read_reg1 = write_reg) else 
	registers(to_integer(unsigned(read_reg1)));
	
	read_data2 <= (others=>'0') when (to_integer(unsigned(read_reg2)) = 0) else 
	write_data    when (reg_write = '1' and read_reg2 = write_reg) else 
	registers(to_integer(unsigned(read_reg2)));
	
end Behavioral;
