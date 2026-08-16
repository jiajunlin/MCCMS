library IEEE;
use IEEE.std_logic_1164.all;

entity Sign_Extender is
    port(
        Instr   : in  STD_LOGIC_VECTOR(31 downto 0); -- Takes the full instruction
        Imm_Out : out STD_LOGIC_VECTOR(31 downto 0)  -- Outputs the padded 32-bit immediate
    );
end Sign_Extender;

architecture behavioral of Sign_Extender is
    signal opcode : STD_LOGIC_VECTOR(6 downto 0);
begin
    opcode <= Instr(6 downto 0);

    process(opcode, Instr)
    begin
        case opcode is
            -- I-type: Loads (lw) and Immediate Alu (addi, andi, ori)
            when "0000011" | "0010011" =>
                Imm_Out <= (31 downto 12 => Instr(31)) & Instr(31 downto 20);

            -- S-type: Stores (sw)
            when "0100011" =>
                Imm_Out <= (31 downto 12 => Instr(31)) & Instr(31 downto 25) & Instr(11 downto 7);

            -- B-type: Branches (beq, bne)
            -- Note: RISC-V branches byte-aligned targets, so bit 0 is always 0
            when "1100011" =>
                Imm_Out <= (31 downto 12 => Instr(31)) & Instr(7) & Instr(30 downto 25) & Instr(11 downto 8) & '0';

            -- U-type: LUI, AUIPC (immediate occupies bits 31:12, no sign-extension needed
            -- below bit 12 since the field itself already spans the top 20 bits)
            when "0110111" | "0010111" =>
                Imm_Out <= Instr(31 downto 12) & x"000";

            -- Default fallback
            when others =>
                Imm_Out <= (others => '0');
        end case;
    end process;
end behavioral;