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
		
		-- Data Memory Interface (Memory Stage Bus) — 64-bit wide for fld/fsd; the addressed
		-- 8-byte doubleword is presented, addr(2:0) selects within it (addr(2) picks the 32-bit
		-- lane used by all integer + single-precision accesses).
		dmem_addr     : out std_logic_vector(31 downto 0);
		dmem_wdata    : out std_logic_vector(63 downto 0);
		dmem_rdata    : in  std_logic_vector(63 downto 0);
		dmem_re       : out std_logic;
		dmem_we       : out std_logic;
		dmem_be       : out std_logic_vector(7 downto 0) -- Per-byte write strobes (sb/sh/sw/fsd)
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
			jump, jalr : out std_logic;
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

	component muldiv_unit is
		port(
			clk, reset : in  std_logic;
			start      : in  std_logic;
			funct3     : in  std_logic_vector(2 downto 0);
			a, b       : in  std_logic_vector(31 downto 0);
			result     : out std_logic_vector(31 downto 0);
			done       : out std_logic
			);
	end component;

	component csr_file is
		port(
			clk, reset : in  std_logic;
			en         : in  std_logic;
			raddr      : in  std_logic_vector(11 downto 0);
			rdata      : out std_logic_vector(31 downto 0);
			we         : in  std_logic;
			waddr      : in  std_logic_vector(11 downto 0);
			wdata      : in  std_logic_vector(31 downto 0);
			fflags_we  : in  std_logic;
			fflags_in  : in  std_logic_vector(4 downto 0);
			frm_out    : out std_logic_vector(2 downto 0)
			);
	end component;

	component fp_register_file is
		port(
			clk, reset : in  std_logic;
			fp_write   : in  std_logic;
			read_reg1, read_reg2, read_reg3, write_reg : in  std_logic_vector(4 downto 0);
			write_data : in  std_logic_vector(63 downto 0);
			read_data1, read_data2, read_data3 : out std_logic_vector(63 downto 0)
			);
	end component;

	component fpu is
		port(
			clk        : in  std_logic;
			reset      : in  std_logic;
			start      : in  std_logic;
			is_double  : in  std_logic;
			funct5     : in  std_logic_vector(4 downto 0);
			funct3     : in  std_logic_vector(2 downto 0);
			rs2_field  : in  std_logic_vector(4 downto 0);
			rm         : in  std_logic_vector(2 downto 0);
			is_fma     : in  std_logic;
			fma_op     : in  std_logic_vector(1 downto 0);
			a_raw      : in  std_logic_vector(63 downto 0);
			b_raw      : in  std_logic_vector(63 downto 0);
			c_raw      : in  std_logic_vector(63 downto 0);
			fp_result  : out std_logic_vector(63 downto 0);
			int_result : out std_logic_vector(31 downto 0);
			flags      : out std_logic_vector(4 downto 0);
			done       : out std_logic
			);
	end component;
	
	-- --- STAGE INTERCONNECT CHANNELS ---
	signal pc_current, pc_next, pc_plus_4 : std_logic_vector(31 downto 0);
	signal pc_enable, pipeline_stall      : std_logic;
	signal forward_a, forward_b            : std_logic_vector(1 downto 0);

	-- RV32M multi-cycle execution (freeze-the-pipeline model)
	signal dec_is_muldiv   : std_logic;                     -- combinational: M-op in ID
	signal ID_EX_is_muldiv : std_logic;                     -- M-op currently in EX
	signal muldiv_result   : std_logic_vector(31 downto 0); -- product/quotient/remainder
	signal muldiv_done     : std_logic;                     -- one-cycle result-valid pulse
	signal ex_stall        : std_logic;                     -- hold front of pipe while unit works

	-- FP multi-cycle execution (fdiv/fsqrt): same freeze model as RV32M
	signal dec_is_fdivsqrt   : std_logic;                   -- combinational: fdiv/fsqrt in ID
	signal ID_EX_is_fdivsqrt : std_logic;                   -- fdiv/fsqrt currently in EX
	signal fpu_done          : std_logic;                   -- FPU op result valid (multi-cycle handshake)

	-- Zicsr / FCSR
	signal dec_is_csr      : std_logic;                     -- combinational: CSR op in ID
	signal ID_EX_is_csr    : std_logic;                     -- CSR op currently in EX
	signal ID_EX_csr_addr  : std_logic_vector(11 downto 0); -- CSR address
	signal csr_read_data   : std_logic_vector(31 downto 0); -- old CSR value (-> rd)
	signal csr_new_value   : std_logic_vector(31 downto 0); -- value written back to the CSR
	signal csr_src         : std_logic_vector(31 downto 0); -- rs1 value or zero-extended uimm
	signal csr_src_zero    : std_logic;                     -- source specifier is x0 / uimm 0
	signal csr_we          : std_logic;                     -- CSR write enable
	signal csr_frm         : std_logic_vector(2 downto 0);  -- exposed dynamic rounding mode

	-- Floating-point load/store/move (FP register file, FLEN=64, NaN-boxed singles)
	constant NAN_BOX_HI : std_logic_vector(31 downto 0) := x"FFFFFFFF"; -- upper 32 for boxed singles
	-- Combinational decode (ID stage)
	signal dec_is_fp_load  : std_logic;                     -- flw/fld  (opcode 0000111)
	signal dec_is_fp_store : std_logic;                     -- fsw/fsd  (opcode 0100111)
	signal dec_fmv_w_x     : std_logic;                     -- fmv.w.x: int rs1 -> fp rd (NaN-boxed)
	signal dec_fmv_x_w     : std_logic;                     -- fmv.x.w: fp rs1(31:0) -> int rd
	signal dec_fp_reg_write : std_logic;                    -- result targets the FP register file
	signal dec_fp_use_rs1  : std_logic;                     -- consumes fp[rs1] (fmv.x.w)
	signal dec_fp_use_rs2  : std_logic;                     -- consumes fp[rs2] (fsw/fsd)
	-- FP register-file read data (ID stage) and interlock
	signal fp_rf_data1, fp_rf_data2, fp_rf_data3 : std_logic_vector(63 downto 0);
	signal fp_stall        : std_logic;                     -- FP producer-consumer interlock
	signal front_stall     : std_logic;                     -- pipeline_stall or fp_stall
	-- FP writeback payload (WB stage)
	signal fp_wb_payload   : std_logic_vector(63 downto 0);
	signal fp_ex_result    : std_logic_vector(63 downto 0); -- FP value produced in EX (fmv.w.x; later FPU)
	signal fp_mem_result   : std_logic_vector(63 downto 0); -- FP load value assembled in MEM
	signal mem_stage_fp_res : std_logic_vector(63 downto 0);-- MEM-stage FP result select (load vs EX)

	-- ID/EX FP fields
	signal ID_EX_fp_data1, ID_EX_fp_data2, ID_EX_fp_data3 : std_logic_vector(63 downto 0);
	signal ID_EX_fp_reg_write : std_logic;
	signal ID_EX_is_fp_load   : std_logic;
	signal ID_EX_is_fp_store  : std_logic;
	signal ID_EX_fmv_w_x      : std_logic;
	signal ID_EX_fmv_x_w      : std_logic;
	-- EX/MEM FP fields
	signal EX_MEM_fp_reg_write : std_logic;
	signal EX_MEM_is_fp_load   : std_logic;
	signal EX_MEM_is_fp_store  : std_logic;
	signal EX_MEM_fp_result    : std_logic_vector(63 downto 0); -- non-load FP value (fmv.w.x/FPU)
	signal EX_MEM_fp_store_data : std_logic_vector(63 downto 0);-- fp[rs2] for fsw/fsd
	-- MEM/WB FP fields
	signal MEM_WB_fp_reg_write : std_logic;
	signal MEM_WB_fp_result    : std_logic_vector(63 downto 0);

	-- FP arithmetic / misc operations (opcode 1010011) routed through the FPU
	signal dec_is_fpop   : std_logic;                     -- any FP-OP instruction
	signal dec_fsgnj     : std_logic;                     -- fsgnj/n/x  (funct5 00100) -> fp reg
	signal dec_fminmax   : std_logic;                     -- fmin/fmax  (funct5 00101) -> fp reg
	signal dec_fcmp      : std_logic;                     -- feq/flt/fle (funct5 10100) -> int reg
	signal dec_fclass    : std_logic;                     -- fclass (funct5 11100, funct3 001) -> int reg
	signal dec_farith    : std_logic;                     -- fadd/fsub/fmul (funct5 00000/00001/00010) -> fp reg
	signal dec_fcvt_f2i  : std_logic;                     -- fcvt.w/wu.s/d (funct5 11000) -> int reg, reads fp[rs1]
	signal dec_fcvt_i2f  : std_logic;                     -- fcvt.s/d.w/wu (funct5 11010) -> fp reg, reads int rs1
	signal dec_fcvt_f2f  : std_logic;                     -- fcvt.s.d / fcvt.d.s (funct5 01000) -> fp reg, reads fp[rs1]
	signal dec_is_fma    : std_logic;                     -- fused multiply-add (opcodes 100xx11) -> fp reg
	signal dec_fp_use_rs3 : std_logic;                    -- consumes fp[rs3] (FMA addend)
	signal dec_fpu_fp    : std_logic;                     -- FPU produces an FP-register result
	signal dec_fpu_int   : std_logic;                     -- FPU produces an integer-register result
	signal fpu_a_in      : std_logic_vector(63 downto 0); -- FPU operand a: fp[rs1], or int rs1 for fcvt.i2f
	signal fpu_fp_result : std_logic_vector(63 downto 0);
	signal fpu_int_result : std_logic_vector(31 downto 0);
	signal fpu_flags     : std_logic_vector(4 downto 0);
	signal fpu_flags_we  : std_logic;                     -- accrue fflags when an FPU op is in EX
	signal fpu_rm        : std_logic_vector(2 downto 0);  -- effective rounding mode (static or frm)
	-- ID/EX FPU fields
	signal ID_EX_fpu_fp   : std_logic;
	signal ID_EX_fpu_int  : std_logic;
	signal ID_EX_is_double : std_logic;
	signal ID_EX_funct5   : std_logic_vector(4 downto 0);
	signal ID_EX_is_fma   : std_logic;
	signal ID_EX_fma_op   : std_logic_vector(1 downto 0);

	-- Combinational Decoded Flags
	signal dec_reg_write, dec_alu_src, dec_mem_read, dec_mem_write, dec_mem_to_reg, dec_branch : std_logic;
	signal dec_jump, dec_jalr : std_logic;
	signal dec_alu_op : std_logic_vector(1 downto 0);
	signal dec_alu_a_sel : std_logic_vector(1 downto 0);
	signal rf_data1, rf_data2, decoded_imm : std_logic_vector(31 downto 0);
	
	-- Intermediate Mux Busses
	signal alu_mux_a, alu_mux_b, final_alu_a, final_alu_b : std_logic_vector(31 downto 0);
	signal alu_calculated, alu_ctrl_word    : std_logic_vector(31 downto 0);

	-- Branch/Jump resolution (EX stage)
	signal branch_cond     : std_logic;                     -- funct3 comparison result
	signal branch_taken    : std_logic;                     -- ID_EX_branch and branch_cond
	signal branch_target   : std_logic_vector(31 downto 0); -- PC + immediate (branches and JAL)
	signal jalr_target     : std_logic_vector(31 downto 0); -- (rs1 + imm) & ~1 (JALR)
	signal redirect_target : std_logic_vector(31 downto 0); -- Selected non-sequential PC
	signal take_redirect   : std_logic;                     -- branch_taken or unconditional jump
	signal ex_result       : std_logic_vector(31 downto 0); -- ALU result, or PC+4 link for jumps
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
	signal ID_EX_jump, ID_EX_jalr                        : std_logic;
	signal ID_EX_alu_op                                  : std_logic_vector(1 downto 0);
	signal ID_EX_alu_a_sel                               : std_logic_vector(1 downto 0);
	
	-- EX/MEM Buffer
	signal EX_MEM_alu_out, EX_MEM_write_data : std_logic_vector(31 downto 0);
	signal EX_MEM_rd                         : std_logic_vector(4 downto 0);
	signal EX_MEM_funct3                     : std_logic_vector(2 downto 0); -- Load/store size + sign
	signal EX_MEM_reg_write, EX_MEM_mem_read, EX_MEM_mem_write, EX_MEM_mem_to_reg : std_logic;
	
	-- MEM/WB Buffer
	signal MEM_WB_dmem_data, MEM_WB_alu_out : std_logic_vector(31 downto 0);
	signal MEM_WB_rd                        : std_logic_vector(4 downto 0);
	signal MEM_WB_reg_write, MEM_WB_mem_to_reg : std_logic;
	
begin
	
	-- --- FETCH (IF) STAGE ---
	pc_plus_4 <= std_logic_vector(unsigned(pc_current) + 4);
	inst_addr <= pc_current; -- Drive fetch address out to instruction memory bus
	
	-- Next PC Selection (branches and jumps resolve in the EX stage: 2-cycle redirect penalty)
	pc_next <= redirect_target when take_redirect = '1' else pc_plus_4;
	
	-- PC moves forward only if cache memory is clear and no load-use bubble or multi-cycle
	-- EX freeze is holding the pipe
	pc_enable <= mem_ready and (not front_stall) and (not ex_stall);
	
	PC_REG: Program_counter 
	port map(clk => clk, reset => reset, en => pc_enable, pc_next => pc_next, pc_current => pc_current);
	
	-- --- PIPELINE STEP CORES ---
	process(clk, reset)
	begin
		if reset = '1' then
			IF_ID_pc        <= (others => '0');
			IF_ID_instr     <= x"00000013"; -- NOP initialization

			ID_EX_reg_write <= '0'; ID_EX_mem_read  <= '0'; ID_EX_mem_write <= '0'; ID_EX_branch <= '0'; ID_EX_jump <= '0'; ID_EX_alu_a_sel <= "00";
			ID_EX_is_muldiv <= '0'; ID_EX_is_csr <= '0'; ID_EX_is_fdivsqrt <= '0';
			ID_EX_fp_reg_write <= '0'; ID_EX_is_fp_load <= '0'; ID_EX_is_fp_store <= '0'; ID_EX_fmv_w_x <= '0'; ID_EX_fmv_x_w <= '0';
			ID_EX_fpu_fp <= '0'; ID_EX_fpu_int <= '0'; ID_EX_is_fma <= '0';
			EX_MEM_reg_write<= '0'; EX_MEM_mem_read <= '0'; EX_MEM_mem_write<= '0';
			EX_MEM_fp_reg_write <= '0'; EX_MEM_is_fp_load <= '0'; EX_MEM_is_fp_store <= '0';
			MEM_WB_reg_write<= '0'; MEM_WB_fp_reg_write <= '0';
		elsif rising_edge(clk) then
			if mem_ready = '1' then

				-- MEM/WB always advances so the tail of the pipe drains even while EX is frozen
				MEM_WB_dmem_data  <= dmem_out;
				MEM_WB_alu_out    <= EX_MEM_alu_out;
				MEM_WB_rd         <= EX_MEM_rd;
				MEM_WB_reg_write  <= EX_MEM_reg_write;
				MEM_WB_mem_to_reg <= EX_MEM_mem_to_reg;
				MEM_WB_fp_reg_write <= EX_MEM_fp_reg_write;
				MEM_WB_fp_result    <= mem_stage_fp_res;

				if ex_stall = '1' then
					-- Multi-cycle unit busy: hold PC, IF/ID and ID/EX (they keep their values),
					-- and inject a bubble into EX/MEM so the not-yet-complete op never commits.
					EX_MEM_reg_write   <= '0';
					EX_MEM_mem_read    <= '0';
					EX_MEM_mem_write   <= '0';
					EX_MEM_fp_reg_write <= '0';
					EX_MEM_is_fp_load  <= '0';
					EX_MEM_is_fp_store <= '0';
				else
					-- IF/ID Latch Step
					-- On a taken branch/jump, the instruction being fetched is wrong-path: squash it to a NOP.
					if take_redirect = '1' then
						IF_ID_pc    <= pc_current;
						IF_ID_instr <= x"00000013"; -- NOP (addi x0,x0,0)
					elsif front_stall = '0' then
						IF_ID_pc    <= pc_current;
						IF_ID_instr <= instruction;
					end if;

					-- ID/EX Latch Step (inject a bubble on a load-use/FP-interlock stall OR a taken branch/jump flush)
					if front_stall = '1' or take_redirect = '1' then
						ID_EX_reg_write <= '0'; ID_EX_mem_read <= '0'; ID_EX_mem_write <= '0'; ID_EX_branch <= '0'; ID_EX_jump <= '0';
						ID_EX_mem_to_reg<= '0'; ID_EX_alu_src  <= '0'; ID_EX_alu_op   <= "00"; ID_EX_alu_a_sel <= "00";
						ID_EX_is_muldiv <= '0'; ID_EX_is_csr <= '0'; ID_EX_is_fdivsqrt <= '0';
						ID_EX_fp_reg_write <= '0'; ID_EX_is_fp_load <= '0'; ID_EX_is_fp_store <= '0'; ID_EX_fmv_w_x <= '0'; ID_EX_fmv_x_w <= '0';
						ID_EX_fpu_fp <= '0'; ID_EX_fpu_int <= '0'; ID_EX_is_fma <= '0';
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
						-- Integer reg_write also fires for CSR ops (rd = old CSR), fmv.x.w (rd = fp[rs1] low32),
						-- and FPU integer-producing ops (feq/flt/fle, fclass)
						ID_EX_reg_write  <= dec_reg_write or dec_is_csr or dec_fmv_x_w or dec_fpu_int;
						ID_EX_alu_src    <= dec_alu_src;
						ID_EX_mem_read   <= dec_mem_read;
						ID_EX_mem_write  <= dec_mem_write;
						ID_EX_mem_to_reg <= dec_mem_to_reg;
						ID_EX_branch     <= dec_branch;
						ID_EX_jump       <= dec_jump;
						ID_EX_jalr       <= dec_jalr;
						ID_EX_alu_op     <= dec_alu_op;
						ID_EX_alu_a_sel  <= dec_alu_a_sel;
						ID_EX_is_muldiv  <= dec_is_muldiv;
						ID_EX_is_fdivsqrt <= dec_is_fdivsqrt;
						ID_EX_is_csr     <= dec_is_csr;
						ID_EX_csr_addr   <= IF_ID_instr(31 downto 20);
						-- FP load/store/move fields
						ID_EX_fp_data1     <= fp_rf_data1;
						ID_EX_fp_data2     <= fp_rf_data2;
						ID_EX_fp_data3     <= fp_rf_data3;
						ID_EX_fp_reg_write <= dec_fp_reg_write;
						ID_EX_is_fp_load   <= dec_is_fp_load;
						ID_EX_is_fp_store  <= dec_is_fp_store;
						ID_EX_fmv_w_x      <= dec_fmv_w_x;
						ID_EX_fmv_x_w      <= dec_fmv_x_w;
						-- FPU (fp_misc etc.) op fields
						ID_EX_fpu_fp       <= dec_fpu_fp;
						ID_EX_fpu_int      <= dec_fpu_int;
						ID_EX_is_double    <= IF_ID_instr(25);           -- fmt(0): 0=single,1=double
						ID_EX_funct5       <= IF_ID_instr(31 downto 27);
						ID_EX_is_fma       <= dec_is_fma;
						ID_EX_fma_op       <= IF_ID_instr(3 downto 2);   -- 00 fmadd 01 fmsub 10 fnmsub 11 fnmadd
					end if;

					-- EX/MEM Latch Step
					EX_MEM_alu_out    <= ex_result; -- ALU/M result, or PC+4 link value for JAL/JALR
					EX_MEM_write_data <= alu_mux_b; -- Carry forwarded data for store operations
					EX_MEM_rd         <= ID_EX_rd;
					EX_MEM_funct3     <= ID_EX_funct3;
					EX_MEM_reg_write  <= ID_EX_reg_write;
					EX_MEM_mem_read   <= ID_EX_mem_read;
					EX_MEM_mem_write  <= ID_EX_mem_write;
					EX_MEM_mem_to_reg <= ID_EX_mem_to_reg;
					-- FP pipeline fields
					EX_MEM_fp_reg_write  <= ID_EX_fp_reg_write;
					EX_MEM_is_fp_load    <= ID_EX_is_fp_load;
					EX_MEM_is_fp_store   <= ID_EX_is_fp_store;
					EX_MEM_fp_result     <= fp_ex_result;      -- fmv.w.x NaN-boxed value (later: FPU result)
					EX_MEM_fp_store_data <= ID_EX_fp_data2;    -- fp[rs2] store data for fsw/fsd
				end if;
			end if;
		end if;
	end process;
	
	-- --- DECODE (ID) STAGE ---
	CTRL_UNIT_INST: control_unit
	port map(opcode => IF_ID_instr(6 downto 0), reg_write => dec_reg_write, alu_src => dec_alu_src,
		mem_read => dec_mem_read, mem_write => dec_mem_write, mem_to_reg => dec_mem_to_reg,
		branch => dec_branch, jump => dec_jump, jalr => dec_jalr, alu_op => dec_alu_op, alu_a_sel => dec_alu_a_sel);

	-- RV32M op = R-type opcode with funct7 = 0000001 (bit 25 set). Its reg_write comes for free
	-- from the R-type control decode; the result is sourced from the muldiv unit, not the ALU.
	dec_is_muldiv <= '1' when (IF_ID_instr(6 downto 0) = "0110011" and IF_ID_instr(25) = '1') else '0';

	-- Zicsr op = SYSTEM opcode with a non-zero funct3 (funct3 = 000 is ECALL/EBREAK, treated as NOP).
	dec_is_csr <= '1' when (IF_ID_instr(6 downto 0) = "1110011" and IF_ID_instr(14 downto 12) /= "000") else '0';

	-- Floating-point load/store (address = int rs1 + imm) and integer<->FP register moves.
	dec_is_fp_load  <= '1' when (IF_ID_instr(6 downto 0) = "0000111") else '0'; -- flw/fld
	dec_is_fp_store <= '1' when (IF_ID_instr(6 downto 0) = "0100111") else '0'; -- fsw/fsd
	-- FP-OP opcode 1010011. funct5 = instr(31:27), fmt = instr(26:25) (00=single/01=double),
	-- is_double = instr(25). fmv.w.x = funct5 11110 (funct3 000); fmv.x.w = funct5 11100 funct3 000.
	dec_is_fpop <= '1' when (IF_ID_instr(6 downto 0) = "1010011") else '0';
	dec_fmv_w_x <= '1' when (dec_is_fpop = '1' and IF_ID_instr(31 downto 27) = "11110" and IF_ID_instr(14 downto 12) = "000") else '0';
	dec_fmv_x_w <= '1' when (dec_is_fpop = '1' and IF_ID_instr(31 downto 27) = "11100" and IF_ID_instr(14 downto 12) = "000") else '0';

	-- FPU-routed FP-OP groups (funct5 = instr(31:27)):
	--   00100 fsgnj/n/x, 00101 fmin/max -> FP-register result
	--   10100 feq/flt/fle, 11100+funct3 001 fclass -> integer-register result
	dec_fsgnj   <= '1' when (dec_is_fpop = '1' and IF_ID_instr(31 downto 27) = "00100") else '0';
	dec_fminmax <= '1' when (dec_is_fpop = '1' and IF_ID_instr(31 downto 27) = "00101") else '0';
	dec_fcmp    <= '1' when (dec_is_fpop = '1' and IF_ID_instr(31 downto 27) = "10100") else '0';
	dec_fclass  <= '1' when (dec_is_fpop = '1' and IF_ID_instr(31 downto 27) = "11100" and IF_ID_instr(14 downto 12) = "001") else '0';
	dec_farith  <= '1' when (dec_is_fpop = '1' and (IF_ID_instr(31 downto 27) = "00000" or
	                                                IF_ID_instr(31 downto 27) = "00001" or
	                                                IF_ID_instr(31 downto 27) = "00010")) else '0';
	-- Multi-cycle FP: fdiv (funct5 00011), fsqrt (funct5 01011, rs2 field = 0). Both write an FP reg.
	dec_is_fdivsqrt <= '1' when (dec_is_fpop = '1' and (IF_ID_instr(31 downto 27) = "00011" or
	                                                    IF_ID_instr(31 downto 27) = "01011")) else '0';
	-- Conversions (funct5): 11000 fp->int, 11010 int->fp, 01000 fp->fp (s<->d).
	dec_fcvt_f2i <= '1' when (dec_is_fpop = '1' and IF_ID_instr(31 downto 27) = "11000") else '0';
	dec_fcvt_i2f <= '1' when (dec_is_fpop = '1' and IF_ID_instr(31 downto 27) = "11010") else '0';
	dec_fcvt_f2f <= '1' when (dec_is_fpop = '1' and IF_ID_instr(31 downto 27) = "01000") else '0';
	-- Fused multiply-add family: distinct major opcodes 1000011 (fmadd), 1000111 (fmsub),
	-- 1001011 (fnmsub), 1001111 (fnmadd) -- all share opcode(6:4)="100" and opcode(1:0)="11".
	-- op = opcode(3:2): 00 fmadd, 01 fmsub, 10 fnmsub, 11 fnmadd. rs3 = instr(31:27), fmt = instr(26:25).
	dec_is_fma <= '1' when (IF_ID_instr(6 downto 4) = "100" and IF_ID_instr(1 downto 0) = "11") else '0';

	dec_fpu_fp  <= dec_fsgnj or dec_fminmax or dec_farith or dec_fcvt_i2f or dec_fcvt_f2f or dec_is_fdivsqrt or dec_is_fma;  -- FPU op writing FP RF
	dec_fpu_int <= dec_fcmp or dec_fclass or dec_fcvt_f2i;     -- FPU op writing the integer register file

	-- Result destined for the FP register file: FP loads, fmv.w.x, and FP-arith producing FP.
	dec_fp_reg_write <= dec_is_fp_load or dec_fmv_w_x or dec_fpu_fp;
	-- FP source consumers (drive the interlock). rs1 (fp): fmv.x.w, fsgnj, fmin/max, fcmp, fclass,
	-- fadd/sub/mul, fcvt.fp->int, fcvt.fp->fp. (fcvt.int->fp reads the INTEGER rs1, not fp.)
	-- rs2 (fp): fsw/fsd, fsgnj, fmin/max, fcmp, fadd/sub/mul.
	dec_fp_use_rs1 <= dec_fmv_x_w or dec_fsgnj or dec_fminmax or dec_fcmp or dec_fclass or dec_farith
	                  or dec_fcvt_f2i or dec_fcvt_f2f or dec_is_fdivsqrt or dec_is_fma;
	-- fdiv also consumes fp rs2; fsqrt does not (rs2 field is 0). instr(30)=funct5(3): 0=fdiv, 1=fsqrt.
	dec_fp_use_rs2 <= dec_is_fp_store or dec_fsgnj or dec_fminmax or dec_fcmp or dec_farith
	                  or (dec_is_fdivsqrt and not IF_ID_instr(30)) or dec_is_fma;
	-- Only the FMA family reads a third FP source (rs3 = instr(31:27)).
	dec_fp_use_rs3 <= dec_is_fma;
	
	REG_FILE_INST: Register_File 
	port map(clk => clk, reset => reset, reg_write => MEM_WB_reg_write, 
		read_reg1 => IF_ID_instr(19 downto 15), read_reg2 => IF_ID_instr(24 downto 20), 
		write_reg => MEM_WB_rd, write_data => wb_payload, read_data1 => rf_data1, read_data2 => rf_data2);
	
	-- FP register file: read fp[rs1]/fp[rs2] in ID (write-first bypass makes a WB-stage commit
	-- visible to an ID-stage read this cycle, which the FP interlock relies on).
	FP_REG_FILE_INST: fp_register_file
	port map(clk => clk, reset => reset, fp_write => MEM_WB_fp_reg_write,
		read_reg1 => IF_ID_instr(19 downto 15), read_reg2 => IF_ID_instr(24 downto 20),
		read_reg3 => IF_ID_instr(31 downto 27),
		write_reg => MEM_WB_rd, write_data => fp_wb_payload,
		read_data1 => fp_rf_data1, read_data2 => fp_rf_data2, read_data3 => fp_rf_data3);

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

	-- RV32M functional unit: operates on the forwarded register operands. `start` is held while
	-- the M-op sits in EX; it captures operands at launch and pulses `done` when the result is ready.
	MULDIV_INST: muldiv_unit
	port map(clk => clk, reset => reset, start => ID_EX_is_muldiv, funct3 => ID_EX_funct3,
		a => alu_mux_a, b => alu_mux_b, result => muldiv_result, done => muldiv_done);

	-- Freeze the front of the pipe while a multi-cycle EX op (M-op or fdiv/fsqrt) is executing but
	-- not yet complete. fpu_done is '1' for single-cycle FP ops, so the FP term only bites for div/sqrt.
	ex_stall <= (ID_EX_is_muldiv and (not muldiv_done))
	            or (ID_EX_is_fdivsqrt and (not fpu_done));

	-- FP interlock: since there is no FP forwarding network, stall a consumer in ID until any
	-- in-flight FP producer (in ID/EX or EX/MEM) targeting its FP source register has reached WB.
	-- A producer in MEM/WB writes this cycle and the FP file's write-first bypass makes it visible,
	-- so it does not force a stall. No x0 exemption -- f0 is an ordinary FP register.
	fp_interlock: process(dec_fp_use_rs1, dec_fp_use_rs2, dec_fp_use_rs3, IF_ID_instr,
	                      ID_EX_fp_reg_write, ID_EX_rd, EX_MEM_fp_reg_write, EX_MEM_rd)
		variable rs1 : std_logic_vector(4 downto 0);
		variable rs2 : std_logic_vector(4 downto 0);
		variable rs3 : std_logic_vector(4 downto 0);
		variable hz1, hz2, hz3 : std_logic;
	begin
		rs1 := IF_ID_instr(19 downto 15);
		rs2 := IF_ID_instr(24 downto 20);
		rs3 := IF_ID_instr(31 downto 27);
		hz1 := '0'; hz2 := '0'; hz3 := '0';
		if (ID_EX_fp_reg_write = '1' and ID_EX_rd = rs1) or (EX_MEM_fp_reg_write = '1' and EX_MEM_rd = rs1) then
			hz1 := '1';
		end if;
		if (ID_EX_fp_reg_write = '1' and ID_EX_rd = rs2) or (EX_MEM_fp_reg_write = '1' and EX_MEM_rd = rs2) then
			hz2 := '1';
		end if;
		if (ID_EX_fp_reg_write = '1' and ID_EX_rd = rs3) or (EX_MEM_fp_reg_write = '1' and EX_MEM_rd = rs3) then
			hz3 := '1';
		end if;
		fp_stall <= (dec_fp_use_rs1 and hz1) or (dec_fp_use_rs2 and hz2) or (dec_fp_use_rs3 and hz3);
	end process;

	-- Combined front-of-pipe stall: integer load-use hazard OR FP interlock.
	front_stall <= pipeline_stall or fp_stall;

	-- --- Zicsr / FCSR (read-modify-write resolved in EX) ---
	-- The CSR file commits its write on the same edge the CSR op leaves EX, so a following
	-- CSR op (one cycle behind, in EX next cycle) reads the updated value with no interlock.
	CSR_INST: csr_file
	port map(clk => clk, reset => reset, en => mem_ready,
		raddr => ID_EX_csr_addr, rdata => csr_read_data,
		we => csr_we, waddr => ID_EX_csr_addr, wdata => csr_new_value,
		fflags_we => fpu_flags_we, fflags_in => fpu_flags,  -- accrue FP exception flags
		frm_out => csr_frm);

	-- Accrue FP exception flags when an FPU op is in EX. Gate with (not ex_stall) so a multi-cycle
	-- fdiv/fsqrt accrues exactly once -- on the cycle it completes and leaves EX -- not every stalled
	-- cycle. Single-cycle FP ops have ex_stall = 0, so their behaviour is unchanged. fmv.w.x/fmv.x.w
	-- never signal, so they are excluded (not fpu_fp/int ops).
	fpu_flags_we <= (ID_EX_fpu_fp or ID_EX_fpu_int) and (not ex_stall);

	-- Source operand: register rs1 for csrr[wsc], or the zero-extended 5-bit uimm for the *i forms.
	-- funct3(2) selects the immediate form; the source specifier being x0/0 suppresses S/C writes.
	csr_src      <= (31 downto 5 => '0') & ID_EX_rs1 when ID_EX_funct3(2) = '1' else alu_mux_a;
	csr_src_zero <= '1' when ID_EX_rs1 = "00000" else '0';

	-- New CSR value by low two funct3 bits: 01 = write, 10 = set, 11 = clear
	csr_new_value <= csr_src                       when ID_EX_funct3(1 downto 0) = "01" else
	                 csr_read_data or csr_src       when ID_EX_funct3(1 downto 0) = "10" else
	                 csr_read_data and (not csr_src);            -- "11" clear

	-- Write always for csrrw/csrrwi; set/clear only when the source specifier is non-zero.
	csr_we <= '1' when (ID_EX_is_csr = '1' and
	                    (ID_EX_funct3(1 downto 0) = "01" or csr_src_zero = '0')) else '0';

	-- --- FLOATING-POINT EXECUTION UNIT (EX stage, combinational for M4a misc ops) ---
	-- Effective rounding mode: the instruction's rm field (funct3), or the dynamic frm when
	-- funct3 = 111 (DYN). (M4a misc ops ignore rm; arithmetic ops added in M4b use it.)
	fpu_rm <= csr_frm when ID_EX_funct3 = "111" else ID_EX_funct3;

	-- FPU operand a: fp[rs1] for normal FP ops; the (forwarded) integer rs1 for fcvt.int->fp
	-- (funct5 11010), which sources its value from the integer register file like fmv.w.x. For an FMA
	-- op funct5 carries rs3, so the int-source select must be suppressed (FMA always reads fp[rs1]).
	fpu_a_in <= (x"00000000" & alu_mux_a) when (ID_EX_funct5 = "11010" and ID_EX_is_fma = '0') else ID_EX_fp_data1;

	FPU_INST: fpu
	port map(clk => clk, reset => reset, start => ID_EX_is_fdivsqrt,
		is_double => ID_EX_is_double, funct5 => ID_EX_funct5, funct3 => ID_EX_funct3,
		rs2_field => ID_EX_rs2, rm => fpu_rm, is_fma => ID_EX_is_fma, fma_op => ID_EX_fma_op,
		a_raw => fpu_a_in, b_raw => ID_EX_fp_data2, c_raw => ID_EX_fp_data3,
		fp_result => fpu_fp_result, int_result => fpu_int_result, flags => fpu_flags, done => fpu_done);

	-- Branch target = branch PC + sign-extended B-type offset
	branch_target <= std_logic_vector(unsigned(ID_EX_pc) + unsigned(ID_EX_imm));

	-- Branch condition evaluated on the FORWARDED register operands, selected by funct3
	branch_compare: process(ID_EX_funct3, alu_mux_a, alu_mux_b)
	begin
		case ID_EX_funct3 is
			when "000" => -- BEQ
				if alu_mux_a = alu_mux_b then branch_cond <= '1'; else branch_cond <= '0'; end if;
			when "001" => -- BNE
				if alu_mux_a /= alu_mux_b then branch_cond <= '1'; else branch_cond <= '0'; end if;
			when "100" => -- BLT (signed)
				if signed(alu_mux_a) < signed(alu_mux_b) then branch_cond <= '1'; else branch_cond <= '0'; end if;
			when "101" => -- BGE (signed)
				if signed(alu_mux_a) >= signed(alu_mux_b) then branch_cond <= '1'; else branch_cond <= '0'; end if;
			when "110" => -- BLTU (unsigned)
				if unsigned(alu_mux_a) < unsigned(alu_mux_b) then branch_cond <= '1'; else branch_cond <= '0'; end if;
			when "111" => -- BGEU (unsigned)
				if unsigned(alu_mux_a) >= unsigned(alu_mux_b) then branch_cond <= '1'; else branch_cond <= '0'; end if;
			when others => branch_cond <= '0';
		end case;
	end process;

	branch_taken <= ID_EX_branch and branch_cond;

	-- JALR target: rs1 + imm (from the ALU) with the low bit forced to 0, per the spec
	jalr_target <= alu_calculated(31 downto 1) & '0';

	-- Non-sequential PC: JALR uses the ALU target, everything else (branch/JAL) is PC-relative
	redirect_target <= jalr_target when ID_EX_jalr = '1' else branch_target;
	take_redirect   <= branch_taken or ID_EX_jump;

	-- EX-stage FP result produced for the FP register file: the FPU result (fsgnj/fmin-max, later
	-- fadd/fmul/...), else fmv.w.x NaN-boxing the (forwarded) integer rs1 into a single.
	fp_ex_result <= fpu_fp_result when ID_EX_fpu_fp = '1' else NAN_BOX_HI & alu_mux_a;

	-- EX-stage integer result select: CSR old value, M-op result, FPU integer result (feq/flt/fle,
	-- fclass), fmv.x.w (fp[rs1] low 32), jump link (PC+4), else ALU.
	ex_result <= csr_read_data                                when ID_EX_is_csr = '1'     else
	             muldiv_result                                when ID_EX_is_muldiv = '1'  else
	             fpu_int_result                               when ID_EX_fpu_int = '1'    else
	             ID_EX_fp_data1(31 downto 0)                  when ID_EX_fmv_x_w = '1'    else
	             std_logic_vector(unsigned(ID_EX_pc) + 4)     when ID_EX_jump = '1'       else
	             alu_calculated;

	-- --- MEMORY ACCESS (MEM) STAGE ---
	-- Address and read strobe drive straight out to the external data memory bus
	dmem_addr  <= EX_MEM_alu_out;
	dmem_re    <= EX_MEM_mem_read;
	dmem_we    <= EX_MEM_mem_write;

	-- Store formatting: a base-ISA store touches at most 4 bytes within one 32-bit lane. Build the
	-- 32-bit store word + 4-bit strobe (as before), then place it on the low or high half of the
	-- 64-bit bus per addr(2). (fsd will override with a full 64-bit path in the FP milestone.)
	store_format: process(EX_MEM_mem_write, EX_MEM_funct3, EX_MEM_alu_out, EX_MEM_write_data,
	                      EX_MEM_is_fp_store, EX_MEM_fp_store_data)
		variable off   : integer range 0 to 3;
		variable word32 : std_logic_vector(31 downto 0);
		variable be4    : std_logic_vector(3 downto 0);
	begin
		off    := to_integer(unsigned(EX_MEM_alu_out(1 downto 0)));
		word32 := EX_MEM_write_data;
		be4    := "0000";

		if EX_MEM_is_fp_store = '1' and EX_MEM_funct3 = "011" then
			-- fsd: full 64-bit doubleword (doubleword-aligned address)
			dmem_wdata <= EX_MEM_fp_store_data;
			dmem_be    <= "11111111";
		elsif EX_MEM_is_fp_store = '1' then
			-- fsw (funct3 = 010): store the low 32 bits, steered onto the addressed lane
			word32 := EX_MEM_fp_store_data(31 downto 0);
			if EX_MEM_alu_out(2) = '1' then
				dmem_wdata <= word32 & x"00000000"; dmem_be <= "11110000";
			else
				dmem_wdata <= x"00000000" & word32; dmem_be <= "00001111";
			end if;
		else
			-- Integer store (sb/sh/sw): build the 32-bit lane word + 4-bit strobe, then steer.
			if EX_MEM_mem_write = '1' then
				case EX_MEM_funct3 is
					when "000" => -- SB: replicate byte across the lane, strobe the addressed one
						word32 := EX_MEM_write_data(7 downto 0) & EX_MEM_write_data(7 downto 0) &
						          EX_MEM_write_data(7 downto 0) & EX_MEM_write_data(7 downto 0);
						case off is
							when 0 => be4 := "0001";
							when 1 => be4 := "0010";
							when 2 => be4 := "0100";
							when 3 => be4 := "1000";
						end case;
					when "001" => -- SH: replicate half across the lane, strobe the addressed one
						word32 := EX_MEM_write_data(15 downto 0) & EX_MEM_write_data(15 downto 0);
						if off = 0 then be4 := "0011"; else be4 := "1100"; end if; -- off = 2
					when others => -- SW
						word32 := EX_MEM_write_data;
						be4    := "1111";
				end case;
			end if;

			-- Steer the 32-bit lane onto the 64-bit doubleword bus (addr(2) selects the lane)
			if EX_MEM_alu_out(2) = '1' then
				dmem_wdata <= word32 & x"00000000";
				dmem_be    <= be4 & "0000";
			else
				dmem_wdata <= x"00000000" & word32;
				dmem_be    <= "0000" & be4;
			end if;
		end if;
	end process;

	-- Load extraction: select the addressed 32-bit lane from the returned doubleword, then pick
	-- the addressed byte/half and sign/zero-extend. (fld will take the full 64 bits in the FP milestone.)
	load_extract: process(EX_MEM_funct3, EX_MEM_alu_out, dmem_rdata)
		variable off  : integer range 0 to 3;
		variable lane : std_logic_vector(31 downto 0);
		variable b    : std_logic_vector(7 downto 0);
		variable h    : std_logic_vector(15 downto 0);
	begin
		off := to_integer(unsigned(EX_MEM_alu_out(1 downto 0)));
		if EX_MEM_alu_out(2) = '1' then lane := dmem_rdata(63 downto 32); else lane := dmem_rdata(31 downto 0); end if;
		case off is
			when 0 => b := lane(7 downto 0);
			when 1 => b := lane(15 downto 8);
			when 2 => b := lane(23 downto 16);
			when 3 => b := lane(31 downto 24);
		end case;
		if off = 0 then h := lane(15 downto 0); else h := lane(31 downto 16); end if; -- off = 2

		case EX_MEM_funct3 is
			when "000"  => dmem_out <= (31 downto 8  => b(7))  & b; -- LB  (sign-extend)
			when "001"  => dmem_out <= (31 downto 16 => h(15)) & h; -- LH  (sign-extend)
			when "100"  => dmem_out <= (31 downto 8  => '0')   & b; -- LBU (zero-extend)
			when "101"  => dmem_out <= (31 downto 16 => '0')   & h; -- LHU (zero-extend)
			when others => dmem_out <= lane;                        -- LW
		end case;
	end process;

	-- FP load assembly: fld takes the full 64-bit doubleword; flw takes the addressed 32-bit lane
	-- and NaN-boxes it (upper 32 = all ones) so it reads back as a valid single.
	fp_load_assemble: process(EX_MEM_funct3, EX_MEM_alu_out, dmem_rdata)
		variable lane : std_logic_vector(31 downto 0);
	begin
		if EX_MEM_alu_out(2) = '1' then lane := dmem_rdata(63 downto 32); else lane := dmem_rdata(31 downto 0); end if;
		if EX_MEM_funct3 = "011" then           -- fld
			fp_mem_result <= dmem_rdata;
		else                                     -- flw (funct3 = 010)
			fp_mem_result <= NAN_BOX_HI & lane;
		end if;
	end process;

	-- MEM-stage FP result select: FP loads take the assembled memory value; everything else
	-- (fmv.w.x, later FPU ops) takes the EX-produced FP value.
	mem_stage_fp_res <= fp_mem_result when EX_MEM_is_fp_load = '1' else EX_MEM_fp_result;

	-- --- WRITE BACK (WB) STAGE ---
	wb_payload <= MEM_WB_dmem_data when MEM_WB_mem_to_reg = '1' else MEM_WB_alu_out;

	-- FP writeback payload feeds the FP register file (NaN-boxing already applied upstream).
	fp_wb_payload <= MEM_WB_fp_result;

end architecture;