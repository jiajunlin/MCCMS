library ieee;
use ieee.std_logic_1164.all;

entity alu_decoder is
	port(
		alu_op      : in  std_logic_vector(1 downto 0);
		funct3      : in  std_logic_vector(2 downto 0);
		funct7_bit6 : in  std_logic; -- Instruction(30)
		alu_control : out std_logic_vector(3 downto 0)
		);
end entity;

architecture behavioral of alu_decoder is
begin
	process(alu_op, funct3, funct7_bit6)
	begin
		case alu_op is
			when "00" => alu_control <= "0000"; -- Changed to "0000" to match ALU ADD
			when "01" => alu_control <= "0001"; -- Changed to "0001" to match ALU SUB
			
			when "10" | "11" => 
				case funct3 is
					when "000" => 
						if (alu_op = "10" and funct7_bit6 = '1') then
							alu_control <= "0001"; -- SUB (R-type only; I-type ADDI has no SUB variant)
						else
							alu_control <= "0000"; -- ADD / ADDI
						end if;
					when "001" => alu_control <= "0010"; -- SLL / SLLI
					when "010" => alu_control <= "0011"; -- SLT / SLTI
					when "011" => alu_control <= "0100"; -- SLTU / SLTIU
					when "100" => alu_control <= "0101"; -- XOR / XORI
					when "101" =>
						if (funct7_bit6 = '1') then
							alu_control <= "0111"; -- SRA / SRAI
						else
							alu_control <= "0110"; -- SRL / SRLI
						end if;
					when "110" => alu_control <= "1000"; -- OR / ORI
					when "111" => alu_control <= "1001"; -- AND / ANDI
					when others => alu_control <= "0000";
			end case;
			when others => alu_control <= "0000";
		end case;
	end process;
end architecture;