library ieee;
use ieee.std_logic_1164.all;

entity control_unit is
    port(
        opcode     : in  std_logic_vector(6 downto 0);
        reg_write  : out std_logic;
        alu_src    : out std_logic;
        mem_read   : out std_logic;
        mem_write  : out std_logic;
        mem_to_reg : out std_logic;
        branch     : out std_logic;
        alu_op     : out std_logic_vector(1 downto 0);
        alu_a_sel  : out std_logic_vector(1 downto 0) -- "00"=register rs1 (default), "01"=PC (AUIPC), "10"=zero (LUI)
    );
end entity;

architecture behavioral of control_unit is
begin
    process(opcode)
    begin
        -- Default assignments to avoid latches
        reg_write  <= '0'; alu_src    <= '0'; mem_read   <= '0';
        mem_write  <= '0'; mem_to_reg <= '0'; branch     <= '0';
        alu_op     <= "00"; alu_a_sel  <= "00";

        case opcode is
            when "0110011" => -- R-type (add, sub, and, or, slt, sll, slt, sltu, xor, srl, sra)
                reg_write <= '1';
                alu_op    <= "10";
                
            when "0010011" => -- I-type ALU (addi, andi, ori, slti, sltiu, xori, slli, srli, srai)
                reg_write <= '1';
                alu_src   <= '1';
                alu_op    <= "11";
                
            when "0000011" => -- I-type Load (lw)
                reg_write  <= '1';
                alu_src    <= '1';
                mem_read   <= '1';
                mem_to_reg <= '1';
                
            when "0100011" => -- S-type Store (sw)
                alu_src   <= '1';
                mem_write <= '1';
                
            when "1100011" => -- B-type Branch (beq, bne)
                branch <= '1';
                alu_op <= "01";
                
            when "0110111" => -- U-type LUI: rd = imm[31:12] << 12
                reg_write <= '1';
                alu_src   <= '1';   -- ALU B = immediate
                alu_op    <= "00";  -- ADD control code (0 + imm = imm)
                alu_a_sel <= "10";  -- ALU A = 0
                
            when "0010111" => -- U-type AUIPC: rd = PC + (imm[31:12] << 12)
                reg_write <= '1';
                alu_src   <= '1';   -- ALU B = immediate
                alu_op    <= "00";  -- ADD control code
                alu_a_sel <= "01";  -- ALU A = PC
                
            when others =>
                null; -- Unsupported/Unknown Opcode
        end case;
    end process;
end architecture;