library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity ALU_RV32I is
    Port (
        A           : in  STD_LOGIC_VECTOR(31 downto 0);
        B           : in  STD_LOGIC_VECTOR(31 downto 0);
        Alu_Control : in  STD_LOGIC_VECTOR(3 downto 0);
        Alu_Result  : out STD_LOGIC_VECTOR(31 downto 0);
        Zero        : out STD_LOGIC
    );
end ALU_RV32I;

architecture Behavioral of ALU_RV32I is
    signal result_signal : STD_LOGIC_VECTOR(31 downto 0);
    
    -- Extract shift amount from the lowest 5 bits of operand B (as per RISC-V spec)
    signal shift_amt     : integer range 0 to 31;
    
begin

    shift_amt <= to_integer(unsigned(B(4 downto 0)));

    process(A, B, ALU_Control, shift_amt)
    begin
        case ALU_Control is
            -- 0000: ADD / ADDI
            when "0000" => 
                result_signal <= std_logic_vector(signed(A) + signed(B));
                
            -- 0001: SUB
            when "0001" => 
                result_signal <= std_logic_vector(signed(A) - signed(B));
                
            -- 0010: SLL / SLLI (Shift Left Logical)
            when "0010" => 
                result_signal <= std_logic_vector(shift_left(unsigned(A), shift_amt));
                
            -- 0011: SLT / SLTI (Set Less Than - Signed)
            when "0011" => 
                if signed(A) < signed(B) then
                    result_signal <= x"00000001";
                else
                    result_signal <= x"00000000";
                end if;
                
            -- 0100: SLTU / SLTIU (Set Less Than - Unsigned)
            when "0100" => 
                if unsigned(A) < unsigned(B) then
                    result_signal <= x"00000001";
                else
                    result_signal <= x"00000000";
                end if;
                
            -- 0101: XOR / XORI
            when "0101" => 
                result_signal <= A xor B;
                
            -- 0110: SRL / SRLI (Shift Right Logical)
            when "0110" => 
                result_signal <= std_logic_vector(shift_right(unsigned(A), shift_amt));
                
            -- 0111: SRA / SRAI (Shift Right Arithmetic - Preserves sign bit)
            when "0111" => 
                result_signal <= std_logic_vector(shift_right(signed(A), shift_amt));
                
            -- 1000: OR / ORI
            when "1000" => 
                result_signal <= A or B;
                
            -- 1001: AND / ANDI
            when "1001" => 
                result_signal <= A and B;
                
            -- Default case fallback
            when others => 
                result_signal <= (others => '0');
        end case;
    end process;

    -- Drive outputs
    ALU_Result <= result_signal;
    Zero       <= '1' when (result_signal = x"00000000") else '0';

end Behavioral;
