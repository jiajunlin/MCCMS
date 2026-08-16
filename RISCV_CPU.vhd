library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity riscv_cpu is
	port(
		clk           : in  std_logic;
		reset         : in  std_logic;
		mem_ready     : in  std_logic; -- High when both caches are happy. Stalls if '0'
		
		-- Instruction Memory Interface (Fetch Stage Bus)
		inst_addr     : out std_logic_vector(31 downto 0);
		instruction   : in  std_logic_vector(31 downto 0);
		
		-- Data Memory Interface (Memory Stage Bus)
		dmem_addr     : out std_logic_vector(31 downto 0);
		dmem_wdata    : out std_logic_vector(31 downto 0);
		dmem_rdata    : in  std_logic_vector(31 downto 0);
		dmem_re       : out std_logic;
		dmem_we       : out std_logic
		);
end entity;

architecture structural of riscv_cpu is
	
	-- --- Structural Reused Component Definitions ---
	component Program_counter is
		port(
			clk, reset, en : in std_logic;
			pc_next        : in std_logic_vector(31 downto 0);
			pc_current     : out std_logic_vector(31 downto 0)
			);
	end component;
	
	component control_unit is
		port(
			opcode : in std_logic_vector(6 downto 0);
			reg_write, alu_src, mem_read, mem_write, mem_to_reg, branch : out std_logic;
			alu_op : out std_logic_vector(1 downto 0);
			alu_a_sel : out std_logic_vector(1 downto 0)
			);
	end component;
	
	component Register_File is
		port(
			clk, reset, reg_write           : in std_logic;
			read_reg1, read_reg2, write_reg : in std_logic_vector(4 downto 0);
			write_data                      : in std_logic_vector(31 downto 0);
			read_data1, read_data2          : out std_logic_vector(31 downto 0)
			);
	end component;
	
	component Sign_Extender is
		port(
			Instr   : in std_logic_vector(31 downto 0);
			Imm_Out : out std_logic_vector(31 downto 0)
			);
	end component;
	
	component alu_decoder is
		port(
			alu_op      : in std_logic_vector(1 downto 0);
			funct3      : in std_logic_vector(2 downto 0);
			funct7_bit6 : in std_logic;
			alu_control : out std_logic_vector(3 downto 0)
			);
	end component;
	
	component ALU_RV32I is
		port(
			A, B        : in std_logic_vector(31 downto 0);
			Alu_Control : in std_logic_vector(3 downto 0);
			Alu_Result  : out std_logic_vector(31 downto 0);
			Zero        : out std_logic
			);
	end component;
	
	component data_memory is
		port(
			clk, mem_read, mem_write : in std_logic;
			address, write_data      : in std_logic_vector(31 downto 0);
			read_data                : out std_logic_vector(31 downto 0)
			);
	end component;
	
	component hazard_forward_unit is
		port(
			IF_ID_rs1, IF_ID_rs2, ID_EX_rd              : in std_logic_vector(4 downto 0);
			ID_EX_mem_read                              : in std_logic;
			ID_EX_rs1, ID_EX_rs2, EX_MEM_rd, MEM_WB_rd : in std_logic_vector(4 downto 0);
			EX_MEM_reg_write, MEM_WB_reg_write          : in std_logic;
			forward_a, forward_b                        : out std_logic_vector(1 downto 0);
			pipeline_stall                              : out std_logic
			);
	end component;
	
	-- --- STAGE INTERCONNECT CHANNELS ---
	signal pc_current, pc_next, pc_plus_4 : std_logic_vector(31 downto 0);
	signal pc_enable, pipeline_stall      : std_logic;
	signal forward_a, forward_b            : std_logic_vector(1 downto 0);
	
	-- Combinational Decoded Flags
	signal dec_reg_write, dec_alu_src, dec_mem_read, dec_mem_write, dec_mem_to_reg, dec_branch : std_logic;
	signal dec_alu_op : std_logic_vector(1 downto 0);
	signal dec_alu_a_sel : std_logic_vector(1 downto 0);
	signal rf_data1, rf_data2, decoded_imm : std_logic_vector(31 downto 0);
	
	-- Intermediate Mux Busses
	signal alu_mux_a, alu_mux_b, final_alu_a, final_alu_b : std_logic_vector(31 downto 0);
	signal alu_calculated, alu_ctrl_word    : std_logic_vector(31 downto 0);
	signal alu_zero_flag                    : std_logic;
	signal dmem_out                         : std_logic_vector(31 downto 0);
	signal wb_payload                       : std_logic_vector(31 downto 0);
	
	-- --- PIPELINE STORAGE BUFFERS ---
	-- IF/ID Buffer
	signal IF_ID_pc    : std_logic_vector(31 downto 0);
	signal IF_ID_instr : std_logic_vector(31 downto 0);
	
	-- ID/EX Buffer
	signal ID_EX_pc, ID_EX_data1, ID_EX_data2, ID_EX_imm : std_logic_vector(31 downto 0);
	signal ID_EX_rs1, ID_EX_rs2, ID_EX_rd                : std_logic_vector(4 downto 0);
	signal ID_EX_funct3                                  : std_logic_vector(2 downto 0);
	signal ID_EX_funct7_bit6                             : std_logic;
	signal ID_EX_reg_write, ID_EX_alu_src, ID_EX_mem_read, ID_EX_mem_write, ID_EX_mem_to_reg, ID_EX_branch : std_logic;
	signal ID_EX_alu_op                                  : std_logic_vector(1 downto 0);
	signal ID_EX_alu_a_sel                               : std_logic_vector(1 downto 0);
	
	-- EX/MEM Buffer
	signal EX_MEM_alu_out, EX_MEM_write_data : std_logic_vector(31 downto 0);
	signal EX_MEM_rd                         : std_logic_vector(4 downto 0);
	signal EX_MEM_reg_write, EX_MEM_mem_read, EX_MEM_mem_write, EX_MEM_mem_to_reg, EX_MEM_branch : std_logic;
	
	-- MEM/WB Buffer
	signal MEM_WB_dmem_data, MEM_WB_alu_out : std_logic_vector(31 downto 0);
	signal MEM_WB_rd                        : std_logic_vector(4 downto 0);
	signal MEM_WB_reg_write, MEM_WB_mem_to_reg, EX_MEM_zero : std_logic;
	
begin
	
	-- --- FETCH (IF) STAGE ---
	pc_plus_4 <= std_logic_vector(unsigned(pc_current) + 4);
	inst_addr <= pc_current; -- Drive fetch address out to instruction memory bus
	
	-- Next PC Selection (Branches evaluate in the MEM stage to prevent control hazards)
	pc_next <= EX_MEM_alu_out when (EX_MEM_branch = '1' and EX_MEM_zero = '1') else pc_plus_4;
	
	-- PC moves forward only if cache memory is clear and no load-use bubble is inside the pipe
	pc_enable <= mem_ready and (not pipeline_stall);
	
	PC_REG: Program_counter 
	port map(clk => clk, reset => reset, en => pc_enable, pc_next => pc_next, pc_current => pc_current);
	
	-- --- PIPELINE STEP CORES ---
	process(clk, reset)
	begin
		if reset = '1' then
			IF_ID_pc        <= (others => '0');
			IF_ID_instr     <= x"00000013"; -- NOP initialization
			
			ID_EX_reg_write <= '0'; ID_EX_mem_read  <= '0'; ID_EX_mem_write <= '0'; ID_EX_branch <= '0'; ID_EX_alu_a_sel <= "00";
			EX_MEM_reg_write<= '0'; EX_MEM_mem_read <= '0'; EX_MEM_mem_write<= '0'; EX_MEM_branch<= '0'; EX_MEM_zero <= '0';
			MEM_WB_reg_write<= '0';
		elsif rising_edge(clk) then
			if mem_ready = '1' then
				
				-- IF/ID Latch Step
				if pipeline_stall = '0' then
					IF_ID_pc    <= pc_current;
					IF_ID_instr <= instruction;
				end if;
				
				-- ID/EX Latch Step (Inject clear bubbles if pipeline_stall is asserted)
				if pipeline_stall = '1' then
					ID_EX_reg_write <= '0'; ID_EX_mem_read <= '0'; ID_EX_mem_write <= '0'; ID_EX_branch <= '0';
					ID_EX_mem_to_reg<= '0'; ID_EX_alu_src  <= '0'; ID_EX_alu_op   <= "00"; ID_EX_alu_a_sel <= "00";
				else
					ID_EX_pc         <= IF_ID_pc;
					ID_EX_data1      <= rf_data1;
					ID_EX_data2      <= rf_data2;
					ID_EX_imm        <= decoded_imm;
					ID_EX_rs1        <= IF_ID_instr(19 downto 15);
					ID_EX_rs2        <= IF_ID_instr(24 downto 20);
					ID_EX_rd         <= IF_ID_instr(11 downto 7);
					ID_EX_funct3     <= IF_ID_instr(14 downto 12);
					ID_EX_funct7_bit6<= IF_ID_instr(30);
					ID_EX_reg_write  <= dec_reg_write;
					ID_EX_alu_src    <= dec_alu_src;
					ID_EX_mem_read   <= dec_mem_read;
					ID_EX_mem_write  <= dec_mem_write;
					ID_EX_mem_to_reg <= dec_mem_to_reg;
					ID_EX_branch     <= dec_branch;
					ID_EX_alu_op     <= dec_alu_op;
					ID_EX_alu_a_sel  <= dec_alu_a_sel;
				end if;
				
				-- EX/MEM Latch Step
				EX_MEM_alu_out    <= alu_calculated;
				EX_MEM_write_data <= alu_mux_b; -- Carry forwarded data for store operations
				EX_MEM_rd         <= ID_EX_rd;
				EX_MEM_reg_write  <= ID_EX_reg_write;
				EX_MEM_mem_read   <= ID_EX_mem_read;
				EX_MEM_mem_write  <= ID_EX_mem_write;
				EX_MEM_mem_to_reg <= ID_EX_mem_to_reg;
				EX_MEM_branch     <= ID_EX_branch;
				EX_MEM_zero       <= alu_zero_flag; -- Latch branch comparison result forward to PC mux
				
				-- MEM/WB Latch Step
				MEM_WB_dmem_data  <= dmem_out;
				MEM_WB_alu_out    <= EX_MEM_alu_out;
				MEM_WB_rd         <= EX_MEM_rd;
				MEM_WB_reg_write  <= EX_MEM_reg_write;
				MEM_WB_mem_to_reg <= EX_MEM_mem_to_reg;
			end if;
		end if;
	end process;
	
	-- --- DECODE (ID) STAGE ---
	CTRL_UNIT_INST: control_unit 
	port map(opcode => IF_ID_instr(6 downto 0), reg_write => dec_reg_write, alu_src => dec_alu_src, 
		mem_read => dec_mem_read, mem_write => dec_mem_write, mem_to_reg => dec_mem_to_reg, 
		branch => dec_branch, alu_op => dec_alu_op, alu_a_sel => dec_alu_a_sel);
	
	REG_FILE_INST: Register_File 
	port map(clk => clk, reset => reset, reg_write => MEM_WB_reg_write, 
		read_reg1 => IF_ID_instr(19 downto 15), read_reg2 => IF_ID_instr(24 downto 20), 
		write_reg => MEM_WB_rd, write_data => wb_payload, read_data1 => rf_data1, read_data2 => rf_data2);
	
	IMM_GEN_INST: Sign_Extender 
	port map(Instr => IF_ID_instr, Imm_Out => decoded_imm);
	
	-- --- EXECUTE (EX) STAGE ---
	HAZARD_UNIT: hazard_forward_unit 
	port map(IF_ID_rs1 => IF_ID_instr(19 downto 15), IF_ID_rs2 => IF_ID_instr(24 downto 20),
		ID_EX_rd => ID_EX_rd, ID_EX_mem_read => ID_EX_mem_read, ID_EX_rs1 => ID_EX_rs1, 
		ID_EX_rs2 => ID_EX_rs2, EX_MEM_rd => EX_MEM_rd, MEM_WB_rd => MEM_WB_rd,
		EX_MEM_reg_write => EX_MEM_reg_write, MEM_WB_reg_write => MEM_WB_reg_write,
		forward_a => forward_a, forward_b => forward_b, pipeline_stall => pipeline_stall);
	
	-- Forwarding Mux A
	alu_mux_a <= EX_MEM_alu_out when forward_a = "10" else
	wb_payload     when forward_a = "01" else
	ID_EX_data1;
	
	-- Forwarding Mux B
	alu_mux_b <= EX_MEM_alu_out when forward_b = "10" else
	wb_payload     when forward_b = "01" else
	ID_EX_data2;
	
	-- ALU Operand A Source Mux (register/forwarded value, PC for AUIPC, or zero for LUI)
	final_alu_a <= ID_EX_pc          when ID_EX_alu_a_sel = "01" else
	(others => '0')       when ID_EX_alu_a_sel = "10" else
	alu_mux_a;
	
	-- Immediate Field Multiplexer
	final_alu_b <= ID_EX_imm when ID_EX_alu_src = '1' else alu_mux_b;
	
	DECODER_ALU: alu_decoder 
	port map(alu_op => ID_EX_alu_op, funct3 => ID_EX_funct3, funct7_bit6 => ID_EX_funct7_bit6, alu_control => alu_ctrl_word(3 downto 0));
	
	ALU_INST: ALU_RV32I 
	port map(A => final_alu_a, B => final_alu_b, Alu_Control => alu_ctrl_word(3 downto 0), Alu_Result => alu_calculated, Zero => open);
	
	-- --- MEMORY ACCESS (MEM) STAGE ---
	-- Custom Target branch calculations happen relative to the tracked ID_EX properties
	alu_zero_flag <= '1' when (alu_mux_a = alu_mux_b) else '0'; -- Zero check calculation
	
	-- Forward internal MEM-stage signals out to the external data memory bus
	dmem_addr  <= EX_MEM_alu_out;
	dmem_wdata <= EX_MEM_write_data;
	dmem_re    <= EX_MEM_mem_read;
	dmem_we    <= EX_MEM_mem_write;
	
	-- Loaded data comes back over the external bus, not from a local memory
	dmem_out   <= dmem_rdata;
	
	-- --- WRITE BACK (WB) STAGE ---
	wb_payload <= MEM_WB_dmem_data when MEM_WB_mem_to_reg = '1' else MEM_WB_alu_out;
	
end architecture;