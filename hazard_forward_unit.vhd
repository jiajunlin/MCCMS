library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity hazard_forward_unit is
    port(
        -- From ID Stage (for Load-Use Hazard Detection)
        IF_ID_rs1        : in  std_logic_vector(4 downto 0);
        IF_ID_rs2        : in  std_logic_vector(4 downto 0);
        ID_EX_rd         : in  std_logic_vector(4 downto 0);
        ID_EX_mem_read   : in  std_logic;
        
        -- From EX and MEM stages (for Forwarding Evaluation)
        ID_EX_rs1        : in  std_logic_vector(4 downto 0);
        ID_EX_rs2        : in  std_logic_vector(4 downto 0);
        EX_MEM_rd        : in  std_logic_vector(4 downto 0);
        MEM_WB_rd        : in  std_logic_vector(4 downto 0);
        EX_MEM_reg_write : in  std_logic;
        MEM_WB_reg_write : in  std_logic;
        
        -- Outputs to Control Pipelines
        forward_a        : out std_logic_vector(1 downto 0);
        forward_b        : out std_logic_vector(1 downto 0);
        pipeline_stall   : out std_logic
    );
end entity;

architecture behavioral of hazard_forward_unit is
begin
    -- 1. Load-Use Hazard Detection Logic
    process(IF_ID_rs1, IF_ID_rs2, ID_EX_rd, ID_EX_mem_read)
    begin
        if (ID_EX_mem_read = '1') and ((ID_EX_rd = IF_ID_rs1) or (ID_EX_rd = IF_ID_rs2)) and (ID_EX_rd /= "00000") then
            pipeline_stall <= '1'; -- Drop lines to insert bubble stall
        else
            pipeline_stall <= '0';
        end if;
    end process;

    -- 2. Operand A Forwarding Logic
    process(ID_EX_rs1, EX_MEM_rd, MEM_WB_rd, EX_MEM_reg_write, MEM_WB_reg_write)
    begin
        -- EX Stage Forward Hazard Priority
        if (EX_MEM_reg_write = '1') and (EX_MEM_rd /= "00000") and (EX_MEM_rd = ID_EX_rs1) then
            forward_a <= "10"; -- Route data directly from EX/MEM ALU output register
        -- MEM Stage Forward Hazard
        elsif (MEM_WB_reg_write = '1') and (MEM_WB_rd /= "00000") and (MEM_WB_rd = ID_EX_rs1) then
            forward_a <= "01"; -- Route data from MEM/WB Write-Back register
        else
            forward_a <= "00"; -- No hazard: Read from standard Register File lines
        end if;
    end process;

    -- 3. Operand B Forwarding Logic
    process(ID_EX_rs2, EX_MEM_rd, MEM_WB_rd, EX_MEM_reg_write, MEM_WB_reg_write)
    begin
        -- EX Stage Forward Hazard Priority
        if (EX_MEM_reg_write = '1') and (EX_MEM_rd /= "00000") and (EX_MEM_rd = ID_EX_rs2) then
            forward_b <= "10";
        -- MEM Stage Forward Hazard
        elsif (MEM_WB_reg_write = '1') and (MEM_WB_rd /= "00000") and (MEM_WB_rd = ID_EX_rs2) then
            forward_b <= "01";
        else
            forward_b <= "00";
        end if;
    end process;
end architecture;