library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Floating-point execution unit (top). Dispatches an FP operation identified by funct5/funct3
-- and precision (is_double) to the appropriate sub-unit and returns an FP result, an integer
-- result, and the IEEE-754 exception flags. In M4a only the non-arithmetic sub-unit (fp_misc)
-- is wired; fadd/fmul/fcvt/fdiv/fsqrt/fma attach to this same interface in later milestones.
entity fpu is
    port(
        clk        : in  std_logic;
        reset      : in  std_logic;
        start      : in  std_logic;                    -- '1' while the FP op sits in EX (for div/sqrt)
        is_double  : in  std_logic;
        funct5     : in  std_logic_vector(4 downto 0); -- instr(31:27) = funct7(6:2)
        funct3     : in  std_logic_vector(2 downto 0);
        rs2_field  : in  std_logic_vector(4 downto 0); -- instr(24:20) (fcvt int-endpoint/source select)
        rm         : in  std_logic_vector(2 downto 0); -- effective rounding mode (arith units)
        is_fma     : in  std_logic;                    -- fused multiply-add family (own major opcodes)
        fma_op     : in  std_logic_vector(1 downto 0); -- 00 fmadd 01 fmsub 10 fnmsub 11 fnmadd
        a_raw      : in  std_logic_vector(63 downto 0);
        b_raw      : in  std_logic_vector(63 downto 0);
        c_raw      : in  std_logic_vector(63 downto 0); -- fp[rs3] addend for FMA
        fp_result  : out std_logic_vector(63 downto 0);
        int_result : out std_logic_vector(31 downto 0);
        flags      : out std_logic_vector(4 downto 0); -- NV DZ OF UF NX
        done       : out std_logic                     -- '1' when the current op's result is valid
        );
end entity;

architecture structural of fpu is

    component fp_misc is
        port(
            is_double  : in  std_logic;
            funct5     : in  std_logic_vector(4 downto 0);
            funct3     : in  std_logic_vector(2 downto 0);
            a_raw      : in  std_logic_vector(63 downto 0);
            b_raw      : in  std_logic_vector(63 downto 0);
            fp_result  : out std_logic_vector(63 downto 0);
            int_result : out std_logic_vector(31 downto 0);
            flags      : out std_logic_vector(4 downto 0)
            );
    end component;

    component fp_addsub is
        port(
            is_double : in  std_logic;
            is_sub    : in  std_logic;
            rm        : in  std_logic_vector(2 downto 0);
            a_raw     : in  std_logic_vector(63 downto 0);
            b_raw     : in  std_logic_vector(63 downto 0);
            fp_result : out std_logic_vector(63 downto 0);
            flags     : out std_logic_vector(4 downto 0)
            );
    end component;

    component fp_mul is
        port(
            is_double : in  std_logic;
            rm        : in  std_logic_vector(2 downto 0);
            a_raw     : in  std_logic_vector(63 downto 0);
            b_raw     : in  std_logic_vector(63 downto 0);
            fp_result : out std_logic_vector(63 downto 0);
            flags     : out std_logic_vector(4 downto 0)
            );
    end component;

    component fp_cvt is
        port(
            is_double  : in  std_logic;
            funct5     : in  std_logic_vector(4 downto 0);
            rs2_field  : in  std_logic_vector(4 downto 0);
            rm         : in  std_logic_vector(2 downto 0);
            a_raw      : in  std_logic_vector(63 downto 0);
            fp_result  : out std_logic_vector(63 downto 0);
            int_result : out std_logic_vector(31 downto 0);
            flags      : out std_logic_vector(4 downto 0)
            );
    end component;

    component fp_divsqrt is
        port(
            clk, reset : in  std_logic;
            start      : in  std_logic;
            is_sqrt    : in  std_logic;
            is_double  : in  std_logic;
            rm         : in  std_logic_vector(2 downto 0);
            a_raw      : in  std_logic_vector(63 downto 0);
            b_raw      : in  std_logic_vector(63 downto 0);
            fp_result  : out std_logic_vector(63 downto 0);
            flags      : out std_logic_vector(4 downto 0);
            done       : out std_logic
            );
    end component;

    component fp_fma is
        port(
            is_double : in  std_logic;
            op        : in  std_logic_vector(1 downto 0);
            rm        : in  std_logic_vector(2 downto 0);
            a_raw     : in  std_logic_vector(63 downto 0);
            b_raw     : in  std_logic_vector(63 downto 0);
            c_raw     : in  std_logic_vector(63 downto 0);
            fp_result : out std_logic_vector(63 downto 0);
            flags     : out std_logic_vector(4 downto 0)
            );
    end component;

    signal misc_fp   : std_logic_vector(63 downto 0);
    signal misc_int  : std_logic_vector(31 downto 0);
    signal misc_flags : std_logic_vector(4 downto 0);

    signal add_fp    : std_logic_vector(63 downto 0);
    signal add_flags : std_logic_vector(4 downto 0);
    signal mul_fp    : std_logic_vector(63 downto 0);
    signal mul_flags : std_logic_vector(4 downto 0);
    signal cvt_fp    : std_logic_vector(63 downto 0);
    signal cvt_int   : std_logic_vector(31 downto 0);
    signal cvt_flags : std_logic_vector(4 downto 0);
    signal ds_fp     : std_logic_vector(63 downto 0);
    signal ds_flags  : std_logic_vector(4 downto 0);
    signal ds_done   : std_logic;
    signal is_ds     : std_logic;                        -- fdiv (00011) or fsqrt (01011)
    signal fma_fp    : std_logic_vector(63 downto 0);
    signal fma_flags : std_logic_vector(4 downto 0);

begin

    MISC_INST: fp_misc
        port map(is_double => is_double, funct5 => funct5, funct3 => funct3,
                 a_raw => a_raw, b_raw => b_raw,
                 fp_result => misc_fp, int_result => misc_int, flags => misc_flags);

    ADDSUB_INST: fp_addsub
        port map(is_double => is_double, is_sub => funct5(0), rm => rm,
                 a_raw => a_raw, b_raw => b_raw,
                 fp_result => add_fp, flags => add_flags);

    MUL_INST: fp_mul
        port map(is_double => is_double, rm => rm,
                 a_raw => a_raw, b_raw => b_raw,
                 fp_result => mul_fp, flags => mul_flags);

    CVT_INST: fp_cvt
        port map(is_double => is_double, funct5 => funct5, rs2_field => rs2_field, rm => rm,
                 a_raw => a_raw,
                 fp_result => cvt_fp, int_result => cvt_int, flags => cvt_flags);

    FMA_INST: fp_fma
        port map(is_double => is_double, op => fma_op, rm => rm,
                 a_raw => a_raw, b_raw => b_raw, c_raw => c_raw,
                 fp_result => fma_fp, flags => fma_flags);

    -- fdiv (funct5 00011) / fsqrt (funct5 01011): multi-cycle. `start` is asserted by the core while
    -- the op is in EX; `done` gates the pipeline freeze (ex_stall) and marks the result valid. Gate on
    -- (not is_fma): for an FMA op funct5 carries rs3 and may collide with the div/sqrt encodings.
    is_ds <= '1' when ((funct5 = "00011" or funct5 = "01011") and is_fma = '0') else '0';

    DIVSQRT_INST: fp_divsqrt
        port map(clk => clk, reset => reset, start => (start and is_ds),
                 is_sqrt => funct5(3),  -- 00011 fdiv -> 0, 01011 fsqrt -> 1
                 is_double => is_double, rm => rm, a_raw => a_raw, b_raw => b_raw,
                 fp_result => ds_fp, flags => ds_flags, done => ds_done);

    -- `done` for the pipeline: single-cycle ops complete immediately; div/sqrt wait for ds_done.
    done <= ds_done when is_ds = '1' else '1';

    -- Result mux by op group. FP-register result: 00000 fadd, 00001 fsub, 00010 fmul,
    -- 11010 fcvt.int->fp, 01000 fcvt.fp->fp; else fp_misc. Integer result: 11000 fcvt.fp->int
    -- (else fp_misc for feq/flt/fle/fclass).
    fp_result <= fma_fp when (is_fma = '1') else
                 add_fp when (funct5 = "00000" or funct5 = "00001") else
                 mul_fp when (funct5 = "00010") else
                 ds_fp  when (funct5 = "00011" or funct5 = "01011") else
                 cvt_fp when (funct5 = "11010" or funct5 = "01000") else
                 misc_fp;
    flags     <= fma_flags when (is_fma = '1') else
                 add_flags when (funct5 = "00000" or funct5 = "00001") else
                 mul_flags when (funct5 = "00010") else
                 ds_flags  when (funct5 = "00011" or funct5 = "01011") else
                 cvt_flags when (funct5 = "11010" or funct5 = "01000" or funct5 = "11000") else
                 misc_flags;
    int_result <= cvt_int when (funct5 = "11000") else misc_int;

end architecture;
