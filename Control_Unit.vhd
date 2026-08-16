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
        jump       : out std_logic; -- Unconditional PC redirect (JAL/JALR); also links rd = PC+4
        jalr       : out std_logic; -- 1 = target from ALU (rs1+imm); 0 = PC-relative target
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
        jump       <= '0'; jalr       <= '0';
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

            when "0000111" => -- FP load (flw/fld): address = rs1 + imm; result -> FP reg file
                alu_src  <= '1';   -- ALU B = immediate (address computation)
                mem_read <= '1';   -- integer reg_write stays 0; FP writeback handled separately

            when "0100111" => -- FP store (fsw/fsd): address = rs1 + imm; data = fp[rs2]
                alu_src   <= '1';  -- ALU B = immediate (address computation)
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

            when "1101111" => -- J-type JAL: rd = PC+4; PC = PC + imm
                reg_write <= '1';
                jump      <= '1';   -- PC-relative redirect (jalr = '0')

            when "1100111" => -- I-type JALR: rd = PC+4; PC = (rs1 + imm) & ~1
                reg_write <= '1';
                alu_src   <= '1';   -- ALU B = immediate (ALU computes rs1 + imm)
                alu_op    <= "00";  -- ADD control code
                jump      <= '1';
                jalr      <= '1';   -- Target taken from ALU result

            when others =>
                null; -- Unsupported/Unknown Opcode
        end case;
    end process;
end architecture;