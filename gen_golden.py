#!/usr/bin/env python3
"""RV32IM assembler + architectural golden model + VCD writeback checker.

Usage:
  python3 tools/gen_golden.py emit          # print VHDL memory-init lines for the test program
  python3 tools/gen_golden.py check <vcd>   # parse the writeback stream and diff vs golden

The golden model executes the program instruction-by-instruction with correct RISC-V
integer + M-extension semantics (truncating signed div, remainder = sign of dividend,
div-by-zero and INT_MIN/-1 special cases). It tracks the *last committed value* per
register, which is exactly what the VCD register-file writeback ports let us reconstruct.
"""
import sys

MASK = 0xFFFFFFFF


def u32(x):
    return x & MASK


def s32(x):
    x &= MASK
    return x - (1 << 32) if x & 0x80000000 else x


# ---------------------------------------------------------------------------
# Minimal assembler (only the instruction forms used by the test program)
# ---------------------------------------------------------------------------
def R(funct7, rs2, rs1, funct3, rd, opcode):
    return (funct7 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode


def I(imm, rs1, funct3, rd, opcode):
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode


def addi(rd, rs1, imm):
    return I(imm, rs1, 0b000, rd, 0b0010011)


def lui(rd, imm20):
    return ((imm20 & 0xFFFFF) << 12) | (rd << 7) | 0b0110111


def add(rd, rs1, rs2):
    return R(0b0000000, rs2, rs1, 0b000, rd, 0b0110011)


def m(funct3, rd, rs1, rs2):
    return R(0b0000001, rs2, rs1, funct3, rd, 0b0110011)


MUL, MULH, MULHSU, MULHU = (lambda rd, a, b: m(0, rd, a, b),
                            lambda rd, a, b: m(1, rd, a, b),
                            lambda rd, a, b: m(2, rd, a, b),
                            lambda rd, a, b: m(3, rd, a, b))
DIV, DIVU, REM, REMU = (lambda rd, a, b: m(4, rd, a, b),
                        lambda rd, a, b: m(5, rd, a, b),
                        lambda rd, a, b: m(6, rd, a, b),
                        lambda rd, a, b: m(7, rd, a, b))

# Zicsr (SYSTEM opcode). csr address occupies imm[11:0]; rs1 field is a register or 5-bit uimm.
FFLAGS, FRM, FCSR = 0x001, 0x002, 0x003


def csr(funct3, rd, csr_addr, rs1_or_uimm):
    return ((csr_addr & 0xFFF) << 20) | ((rs1_or_uimm & 0x1F) << 15) | \
        (funct3 << 12) | (rd << 7) | 0b1110011


CSRRW = lambda rd, c, rs1: csr(0b001, rd, c, rs1)
CSRRS = lambda rd, c, rs1: csr(0b010, rd, c, rs1)
CSRRC = lambda rd, c, rs1: csr(0b011, rd, c, rs1)
CSRRWI = lambda rd, c, u: csr(0b101, rd, c, u)
CSRRSI = lambda rd, c, u: csr(0b110, rd, c, u)
CSRRCI = lambda rd, c, u: csr(0b111, rd, c, u)


# ---------------------------------------------------------------------------
# Floating-point load/store/move (F/D). Address = integer rs1 + imm.
# ---------------------------------------------------------------------------
def S(imm, rs2, rs1, funct3, opcode):
    imm &= 0xFFF
    return (((imm >> 5) & 0x7F) << 25) | (rs2 << 20) | (rs1 << 15) | \
        (funct3 << 12) | ((imm & 0x1F) << 7) | opcode


FLW = lambda frd, rs1, imm: I(imm, rs1, 0b010, frd, 0b0000111)
FLD = lambda frd, rs1, imm: I(imm, rs1, 0b011, frd, 0b0000111)
FSW = lambda frs2, rs1, imm: S(imm, frs2, rs1, 0b010, 0b0100111)
FSD = lambda frs2, rs1, imm: S(imm, frs2, rs1, 0b011, 0b0100111)
FMV_W_X = lambda frd, rs1: R(0b1111000, 0, rs1, 0b000, frd, 0b1010011)  # int -> fp (NaN-box)
FMV_X_W = lambda rd, frs1: R(0b1110000, 0, frs1, 0b000, rd, 0b1010011)  # fp(31:0) -> int


# ---------------------------------------------------------------------------
# FP-OP (opcode 1010011). funct7 = (funct5 << 2) | fmt, fmt: 00 = single, 01 = double.
# ---------------------------------------------------------------------------
def fpop(funct5, fmt, rs2, rs1, funct3, rd):
    return R(((funct5 & 0x1F) << 2) | (fmt & 0x3), rs2, rs1, funct3, rd, 0b1010011)


# Sign injection (fp result). funct5 00100; funct3 000=j / 001=jn / 010=jx
FSGNJ_S = lambda frd, a, b: fpop(0b00100, 0b00, b, a, 0b000, frd)
FSGNJN_S = lambda frd, a, b: fpop(0b00100, 0b00, b, a, 0b001, frd)
FSGNJX_S = lambda frd, a, b: fpop(0b00100, 0b00, b, a, 0b010, frd)
FSGNJ_D = lambda frd, a, b: fpop(0b00100, 0b01, b, a, 0b000, frd)
FSGNJN_D = lambda frd, a, b: fpop(0b00100, 0b01, b, a, 0b001, frd)
FSGNJX_D = lambda frd, a, b: fpop(0b00100, 0b01, b, a, 0b010, frd)
# fmin/fmax (fp result). funct5 00101; funct3 000=min / 001=max
FMIN_S = lambda frd, a, b: fpop(0b00101, 0b00, b, a, 0b000, frd)
FMAX_S = lambda frd, a, b: fpop(0b00101, 0b00, b, a, 0b001, frd)
FMIN_D = lambda frd, a, b: fpop(0b00101, 0b01, b, a, 0b000, frd)
FMAX_D = lambda frd, a, b: fpop(0b00101, 0b01, b, a, 0b001, frd)
# Comparisons (integer result). funct5 10100; funct3 010=eq / 001=lt / 000=le
FEQ_S = lambda rd, a, b: fpop(0b10100, 0b00, b, a, 0b010, rd)
FLT_S = lambda rd, a, b: fpop(0b10100, 0b00, b, a, 0b001, rd)
FLE_S = lambda rd, a, b: fpop(0b10100, 0b00, b, a, 0b000, rd)
FEQ_D = lambda rd, a, b: fpop(0b10100, 0b01, b, a, 0b010, rd)
FLT_D = lambda rd, a, b: fpop(0b10100, 0b01, b, a, 0b001, rd)
FLE_D = lambda rd, a, b: fpop(0b10100, 0b01, b, a, 0b000, rd)
# fclass (integer result). funct5 11100, funct3 001, rs2 = 0
FCLASS_S = lambda rd, a: fpop(0b11100, 0b00, 0, a, 0b001, rd)
FCLASS_D = lambda rd, a: fpop(0b11100, 0b01, 0, a, 0b001, rd)
# Arithmetic (fp result). funct5 00000=add / 00001=sub / 00010=mul; funct3 = rounding mode.
FADD_S = lambda frd, a, b, rm=0: fpop(0b00000, 0b00, b, a, rm, frd)
FSUB_S = lambda frd, a, b, rm=0: fpop(0b00001, 0b00, b, a, rm, frd)
FMUL_S = lambda frd, a, b, rm=0: fpop(0b00010, 0b00, b, a, rm, frd)
FADD_D = lambda frd, a, b, rm=0: fpop(0b00000, 0b01, b, a, rm, frd)
FSUB_D = lambda frd, a, b, rm=0: fpop(0b00001, 0b01, b, a, rm, frd)
FMUL_D = lambda frd, a, b, rm=0: fpop(0b00010, 0b01, b, a, rm, frd)
# Conversions. funct5 11000 fp->int, 11010 int->fp, 01000 fp<->fp; rs2 field selects endpoint/source.
FCVT_W_S  = lambda rd,  frs1, rm=0: fpop(0b11000, 0b00, 0b00000, frs1, rm, rd)   # int32   <- single (signed)
FCVT_WU_S = lambda rd,  frs1, rm=0: fpop(0b11000, 0b00, 0b00001, frs1, rm, rd)   # uint32  <- single
FCVT_W_D  = lambda rd,  frs1, rm=0: fpop(0b11000, 0b01, 0b00000, frs1, rm, rd)   # int32   <- double
FCVT_WU_D = lambda rd,  frs1, rm=0: fpop(0b11000, 0b01, 0b00001, frs1, rm, rd)   # uint32  <- double
FCVT_S_W  = lambda frd, rs1,  rm=0: fpop(0b11010, 0b00, 0b00000, rs1,  rm, frd)  # single  <- int32 (signed)
FCVT_S_WU = lambda frd, rs1,  rm=0: fpop(0b11010, 0b00, 0b00001, rs1,  rm, frd)  # single  <- uint32
FCVT_D_W  = lambda frd, rs1,  rm=0: fpop(0b11010, 0b01, 0b00000, rs1,  rm, frd)  # double  <- int32 (signed)
FCVT_D_WU = lambda frd, rs1,  rm=0: fpop(0b11010, 0b01, 0b00001, rs1,  rm, frd)  # double  <- uint32
FCVT_S_D  = lambda frd, frs1, rm=0: fpop(0b01000, 0b00, 0b00001, frs1, rm, frd)  # single  <- double (narrow)
FCVT_D_S  = lambda frd, frs1, rm=0: fpop(0b01000, 0b01, 0b00000, frs1, rm, frd)  # double  <- single (widen)
# Divide / square root (fp result). funct5 00011 fdiv, 01011 fsqrt (rs2 field = 0); funct3 = rounding.
FDIV_S  = lambda frd, a, b, rm=0: fpop(0b00011, 0b00, b, a, rm, frd)
FDIV_D  = lambda frd, a, b, rm=0: fpop(0b00011, 0b01, b, a, rm, frd)
FSQRT_S = lambda frd, a, rm=0:    fpop(0b01011, 0b00, 0b00000, a, rm, frd)
FSQRT_D = lambda frd, a, rm=0:    fpop(0b01011, 0b01, 0b00000, a, rm, frd)

# R4-type fused multiply-add: rs3(31:27) | fmt(26:25) | rs2 | rs1 | rm(funct3) | rd | opcode.
# opcodes: 1000011 fmadd, 1000111 fmsub, 1001011 fnmsub, 1001111 fnmadd. op = opcode(3:2).
def fma(opcode, fmt, rs3, rs2, rs1, rm, rd):
    return u32(((rs3 & 0x1F) << 27) | ((fmt & 0x3) << 25) | ((rs2 & 0x1F) << 20) |
               ((rs1 & 0x1F) << 15) | ((rm & 0x7) << 12) | ((rd & 0x1F) << 7) | (opcode & 0x7F))
FMADD_S  = lambda frd, a, b, c, rm=0: fma(0b1000011, 0b00, c, b, a, rm, frd)
FMSUB_S  = lambda frd, a, b, c, rm=0: fma(0b1000111, 0b00, c, b, a, rm, frd)
FNMSUB_S = lambda frd, a, b, c, rm=0: fma(0b1001011, 0b00, c, b, a, rm, frd)
FNMADD_S = lambda frd, a, b, c, rm=0: fma(0b1001111, 0b00, c, b, a, rm, frd)
FMADD_D  = lambda frd, a, b, c, rm=0: fma(0b1000011, 0b01, c, b, a, rm, frd)
FMSUB_D  = lambda frd, a, b, c, rm=0: fma(0b1000111, 0b01, c, b, a, rm, frd)
FNMSUB_D = lambda frd, a, b, c, rm=0: fma(0b1001011, 0b01, c, b, a, rm, frd)
FNMADD_D = lambda frd, a, b, c, rm=0: fma(0b1001111, 0b01, c, b, a, rm, frd)


def li(rd, imm):
    """Emit a lui/addi pair that materializes a full 32-bit immediate in rd."""
    imm &= MASK
    lo = imm & 0xFFF
    hi = (imm + 0x1000) >> 12 if (lo & 0x800) else (imm >> 12)
    hi &= 0xFFFFF
    lo_signed = lo - (1 << 12) if (lo & 0x800) else lo
    return [(f"lui  x{rd},0x{hi:05x}", lui(rd, hi)),
            (f"addi x{rd},x{rd},{lo_signed}", addi(rd, rd, lo_signed))]


# ---------------------------------------------------------------------------
# Test program: build operands, then exercise every M op incl. edge cases and
# a back-to-back dependency (M result feeding the next instruction via forwarding).
# ---------------------------------------------------------------------------
PROG_M = [
    ("addi x1,x0,6",       addi(1, 0, 6)),
    ("addi x2,x0,7",       addi(2, 0, 7)),
    ("mul  x3,x1,x2",      MUL(3, 1, 2)),          # 42
    ("addi x4,x0,-20",     addi(4, 0, -20)),
    ("addi x5,x0,3",       addi(5, 0, 3)),
    ("div  x6,x4,x5",      DIV(6, 4, 5)),          # -20/3 = -6
    ("rem  x7,x4,x5",      REM(7, 4, 5)),          # -20 rem 3 = -2
    ("divu x8,x1,x2",      DIVU(8, 1, 2)),         # 6/7 = 0
    ("remu x9,x1,x2",      REMU(9, 1, 2)),         # 6
    ("lui  x11,0x40000",   lui(11, 0x40000)),      # 0x40000000
    ("addi x12,x0,4",      addi(12, 0, 4)),
    ("mulh x10,x11,x12",   MULH(10, 11, 12)),      # (2^30 * 4) >> 32 = 1
    ("mulhu x13,x11,x12",  MULHU(13, 11, 12)),     # 1
    ("mulhsu x14,x11,x12", MULHSU(14, 11, 12)),    # 1
    ("div  x15,x1,x0",     DIV(15, 1, 0)),         # div by zero -> -1
    ("rem  x16,x1,x0",     REM(16, 1, 0)),         # rem by zero -> 6
    ("lui  x17,0x80000",   lui(17, 0x80000)),      # INT_MIN
    ("addi x18,x0,-1",     addi(18, 0, -1)),
    ("div  x19,x17,x18",   DIV(19, 17, 18)),       # INT_MIN / -1 -> INT_MIN
    ("rem  x20,x17,x18",   REM(20, 17, 18)),       # INT_MIN rem -1 -> 0
    ("mul  x21,x3,x5",     MUL(21, 3, 5)),         # 42 * 3 = 126
    ("add  x22,x21,x1",    add(22, 21, 1)),        # forward M result: 126 + 6 = 132
]

# CSR / FCSR program: exercises csrrw/s/c and the immediate forms against fcsr/fflags/frm,
# including back-to-back read-after-write on the same CSR and set/clear no-write (rs1=x0).
PROG_CSR = [
    ("addi  x1,x0,0x15",     addi(1, 0, 0x15)),        # 0b10101 = NV|OF|NX
    ("csrrw x2,fcsr,x1",     CSRRW(2, FCSR, 1)),       # x2=old fcsr=0; fcsr={frm0,fflags=0x15}
    ("csrrs x3,fcsr,x0",     CSRRS(3, FCSR, 0)),       # x3=fcsr=0x15; no write
    ("addi  x4,x0,0x0E",     addi(4, 0, 0x0E)),        # 0b01110
    ("csrrc x5,fflags,x4",   CSRRC(5, FFLAGS, 4)),     # x5=0x15; fflags=0x15&~0x0E=0x11
    ("csrrs x6,fflags,x0",   CSRRS(6, FFLAGS, 0)),     # x6=fflags=0x11
    ("addi  x7,x0,7",        addi(7, 0, 7)),
    ("csrrw x8,frm,x7",      CSRRW(8, FRM, 7)),        # x8=old frm=0; frm=7
    ("csrrs x9,fcsr,x0",     CSRRS(9, FCSR, 0)),       # x9=(7<<5)|0x11=0xF1
    ("csrrwi x10,frm,3",     CSRRWI(10, FRM, 3)),      # x10=old frm=7; frm=3
    ("csrrsi x11,fflags,1",  CSRRSI(11, FFLAGS, 1)),   # x11=0x11; fflags|=1 -> 0x11
    ("csrrci x12,fflags,0x11", CSRRCI(12, FFLAGS, 0x11)),  # x12=0x11; fflags&=~0x11 -> 0
    ("csrrs x13,fcsr,x0",    CSRRS(13, FCSR, 0)),      # x13=(3<<5)|0=0x60
]

# FP load/store/move program (M3b): NaN-boxed single moves, single & double store/reload
# round-trips through data memory, and back-to-back FP-register dependencies exercising the
# interlock (fmv.w.x -> fmv.x.w, flw -> fmv.x.w, fld -> fsd).
def _build_prog_fp():
    p = []
    p += li(1, 0x3F800000)   # x1 = 1.0f bit pattern
    p += li(2, 0x40490FDB)   # x2 = pi (single) bit pattern
    p += li(3, 0x11223344)   # x3 = double low word
    p += li(4, 0x55667788)   # x4 = double high word
    p += li(10, 0x100)       # x10 = data base address
    p += [
        ("fmv.w.x f0,x1",  FMV_W_X(0, 1)),   # f0 = NaNbox(0x3F800000)
        ("fmv.w.x f1,x2",  FMV_W_X(1, 2)),   # f1 = NaNbox(0x40490FDB)
        ("fmv.x.w x5,f0",  FMV_X_W(5, 0)),   # x5 = 0x3F800000   (interlock on f0)
        ("fmv.x.w x6,f1",  FMV_X_W(6, 1)),   # x6 = 0x40490FDB   (interlock on f1)
        ("fsw f0,0(x10)",  FSW(0, 10, 0)),   # mem[0x100] = 0x3F800000
        ("flw f2,0(x10)",  FLW(2, 10, 0)),   # f2 = NaNbox(0x3F800000)
        ("fmv.x.w x7,f2",  FMV_X_W(7, 2)),   # x7 = 0x3F800000   (load -> move interlock)
        ("sw  x3,8(x10)",  S(8, 3, 10, 0b010, 0b0100011)),
        ("sw  x4,12(x10)", S(12, 4, 10, 0b010, 0b0100011)),
        ("fld f3,8(x10)",  FLD(3, 10, 8)),   # f3 = 0x5566778811223344
        ("fsd f3,16(x10)", FSD(3, 10, 16)),  # mem[0x110] = 0x5566778811223344 (interlock on f3)
        ("fld f4,16(x10)", FLD(4, 10, 16)),  # f4 = 0x5566778811223344
    ]
    return p


PROG_FP = _build_prog_fp()


# FP misc program (M4a): fsgnj/n/x, fmin/max, feq/flt/fle, fclass on both single and double,
# covering signed zero, +/-inf, qNaN/sNaN (NV-flag) cases. FP-register results are checked
# directly from the FP writeback stream; comparison/fclass write integer regs; the accrued
# fflags are read out at the end via csrrs.
#  single bit patterns loaded via fmv.w.x; doubles via sw pair + fld.
SP = {
    "1.0": 0x3F800000, "-1.0": 0xBF800000, "2.0": 0x40000000,
    "-0.0": 0x80000000, "+0.0": 0x00000000, "+inf": 0x7F800000,
    "qNaN": 0x7FC00000, "sNaN": 0x7F800001,
}


def _build_prog_fmisc():
    p = []
    # Load the eight single operands into f0..f7 (scratch integer reg x1, adjacent forwarding).
    order = ["1.0", "-1.0", "2.0", "-0.0", "+0.0", "+inf", "qNaN", "sNaN"]
    for i, key in enumerate(order):
        p += li(1, SP[key])
        p += [(f"fmv.w.x f{i},x1  # {key}", FMV_W_X(i, 1))]

    # Single FP-result ops -> f8..f16 (checked directly from the FP writeback stream)
    p += [
        ("fsgnj.s  f8,f0,f1",  FSGNJ_S(8, 0, 1)),    # sign(-1) onto 1.0 -> -1.0
        ("fsgnjn.s f9,f0,f1",  FSGNJN_S(9, 0, 1)),   # ~sign(-1)=+ -> +1.0
        ("fsgnjx.s f10,f1,f2", FSGNJX_S(10, 1, 2)),  # sign(1^0)=- , mag(-1) -> -1.0
        ("fmin.s   f11,f1,f0", FMIN_S(11, 1, 0)),    # min(-1,1) -> -1.0
        ("fmax.s   f12,f1,f0", FMAX_S(12, 1, 0)),    # max(-1,1) -> 1.0
        ("fmin.s   f13,f3,f4", FMIN_S(13, 3, 4)),    # min(-0,+0) -> -0.0
        ("fmax.s   f14,f3,f4", FMAX_S(14, 3, 4)),    # max(-0,+0) -> +0.0
        ("fmin.s   f15,f6,f0", FMIN_S(15, 6, 0)),    # min(qNaN,1) -> 1.0 (no NV)
        ("fmin.s   f16,f7,f0", FMIN_S(16, 7, 0)),    # min(sNaN,1) -> 1.0 (NV)
    ]

    # Single comparisons + fclass -> integer regs
    p += [
        ("feq.s  x5,f0,f0",  FEQ_S(5, 0, 0)),        # 1
        ("flt.s  x6,f1,f0",  FLT_S(6, 1, 0)),        # 1
        ("fle.s  x7,f0,f0",  FLE_S(7, 0, 0)),        # 1
        ("flt.s  x8,f6,f0",  FLT_S(8, 6, 0)),        # qNaN -> 0, NV
        ("feq.s  x9,f6,f0",  FEQ_S(9, 6, 0)),        # qNaN quiet -> 0, no NV
        ("feq.s  x28,f7,f0", FEQ_S(28, 7, 0)),       # sNaN -> 0, NV
        ("fclass.s x20,f0",  FCLASS_S(20, 0)),       # +normal -> 0x040
        ("fclass.s x21,f3",  FCLASS_S(21, 3)),       # -0      -> 0x008
        ("fclass.s x22,f5",  FCLASS_S(22, 5)),       # +inf    -> 0x080
        ("fclass.s x23,f6",  FCLASS_S(23, 6)),       # qNaN    -> 0x200
        ("fclass.s x24,f7",  FCLASS_S(24, 7)),       # sNaN    -> 0x100
    ]

    # Doubles: build 1.5 (0x3FF8..) and -1.5 (0xBFF8..) in memory, fld into f17,f18.
    p += li(10, 0x200)      # data base
    p += li(16, 0x00000000)
    p += li(17, 0x3FF80000)
    p += li(18, 0x00000000)
    p += li(19, 0xBFF80000)
    p += [
        ("sw x16,0(x10)",  S(0, 16, 10, 0b010, 0b0100011)),
        ("sw x17,4(x10)",  S(4, 17, 10, 0b010, 0b0100011)),
        ("sw x18,8(x10)",  S(8, 18, 10, 0b010, 0b0100011)),
        ("sw x19,12(x10)", S(12, 19, 10, 0b010, 0b0100011)),
        ("fld f17,0(x10)", FLD(17, 10, 0)),    # 1.5d
        ("fld f18,8(x10)", FLD(18, 10, 8)),    # -1.5d
    ]
    # Double FP-result ops -> f19,f20 ; double compares/fclass -> int regs
    p += [
        ("fsgnj.d f19,f17,f18", FSGNJ_D(19, 17, 18)),  # sign(-1.5) onto 1.5 -> -1.5d
        ("fmin.d  f20,f18,f17", FMIN_D(20, 18, 17)),   # min(-1.5,1.5) -> -1.5d
        ("feq.d  x25,f17,f17",  FEQ_D(25, 17, 17)),    # 1
        ("flt.d  x26,f18,f17",  FLT_D(26, 18, 17)),    # -1.5<1.5 -> 1
        ("fclass.d x27,f18",    FCLASS_D(27, 18)),     # -normal -> 0x002
    ]
    # Read the accrued exception flags (expect NV only = 0x10)
    p += [("csrrs x30,fflags,x0", CSRRS(30, FFLAGS, 0))]
    return p


PROG_FMISC = _build_prog_fmisc()


# FP arithmetic program (M4b): fadd/fsub/fmul on single + double covering exact and inexact
# results, all five rounding modes (static funct3 + one dynamic via frm), overflow, gradual
# underflow / flush-to-zero, signed-zero cancellation, inf and inf-inf / sNaN invalid cases.
# FP results are checked from the FP writeback stream; exception flags for the four flag-critical
# ops (NX, OF, UF, NV) are isolated by clearing fflags before the op and reading them after.
SPA = {
    "1.0": 0x3F800000, "2.0": 0x40000000, "3.0": 0x40400000, "-2.0": 0xC0000000,
    "0.1": 0x3DCCCCCD, "0.2": 0x3E4CCCCD, "big": 0x7F000000, "+inf": 0x7F800000,
    "sNaN": 0x7F800001, "minN": 0x00800000,
}
RM_RNE, RM_RTZ, RM_RDN, RM_RUP, RM_RMM, RM_DYN = 0, 1, 2, 3, 4, 7


def _build_prog_farith():
    p = []
    order = ["1.0", "2.0", "3.0", "-2.0", "0.1", "0.2", "big", "+inf", "sNaN", "minN"]
    for i, key in enumerate(order):
        p += li(1, SPA[key])
        p += [(f"fmv.w.x f{i},x1  # {key}", FMV_W_X(i, 1))]

    def clear():
        return [("csrrci x0,fflags,0x1f", CSRRCI(0, FFLAGS, 0x1F))]

    def readflags(rd):
        return [(f"csrrs x{rd},fflags,x0", CSRRS(rd, FFLAGS, 0))]

    # Exact / basic single ops
    p += [
        ("fadd.s f10,f0,f1", FADD_S(10, 0, 1)),   # 1+2 = 3.0
        ("fsub.s f11,f0,f1", FSUB_S(11, 0, 1)),   # 1-2 = -1.0
        ("fmul.s f12,f1,f2", FMUL_S(12, 1, 2)),   # 2*3 = 6.0
        ("fadd.s f14,f0,f3", FADD_S(14, 0, 3)),   # 1.0 + (-2.0) = -1.0
        ("fsub.s f17,f0,f0", FSUB_S(17, 0, 0)),   # 1-1 = +0.0
        ("fadd.s f18,f7,f7", FADD_S(18, 7, 7)),   # +inf + +inf = +inf (no flag)
    ]
    # inexact add (measure NX)
    p += clear()
    p += [("fadd.s f13,f5,f4", FADD_S(13, 5, 4))]   # 0.2 + 0.1 inexact -> NX
    p += readflags(5)
    # overflow (measure OF|NX):  big * big -> +inf
    p += clear()
    p += [("fmul.s f15,f6,f6", FMUL_S(15, 6, 6))]
    p += readflags(6)
    # underflow flush to zero (measure UF|NX):  minN * minN -> +0
    p += clear()
    p += [("fmul.s f16,f9,f9", FMUL_S(16, 9, 9))]
    p += readflags(7)
    # inf - inf invalid (measure NV)
    p += clear()
    p += [("fsub.s f19,f7,f7", FSUB_S(19, 7, 7))]
    p += readflags(8)

    # Rounding-mode sweep on 0.2 + 0.1 (inexact); results -> f20..f24
    p += [
        ("fadd.s f20,f5,f4,rtz", FADD_S(20, 5, 4, RM_RTZ)),
        ("fadd.s f21,f5,f4,rdn", FADD_S(21, 5, 4, RM_RDN)),
        ("fadd.s f22,f5,f4,rup", FADD_S(22, 5, 4, RM_RUP)),
        ("fadd.s f23,f5,f4,rmm", FADD_S(23, 5, 4, RM_RMM)),
    ]
    # Dynamic rounding mode = RUP via frm, then a dyn-rm add
    p += [("csrrwi x0,frm,3", CSRRWI(0, FRM, RM_RUP))]
    p += [("fadd.s f24,f5,f4,dyn", FADD_S(24, 5, 4, RM_DYN))]
    p += [("csrrwi x0,frm,0", CSRRWI(0, FRM, RM_RNE))]   # restore

    # Doubles: build 1.5, 0.5, 0.1, 0.2 in memory (base 0x200) and fld them.
    p += li(10, 0x200)
    dbls = [
        (0x00000000, 0x3FF80000),  # 1.5
        (0x00000000, 0x3FE00000),  # 0.5
        (0x9999999A, 0x3FB99999),  # 0.1
        (0x9999999A, 0x3FC99999),  # 0.2
    ]
    for i, (lo, hi) in enumerate(dbls):
        p += li(16, lo)
        p += li(17, hi)
        p += [(f"sw x16,{i*8}(x10)", S(i * 8, 16, 10, 0b010, 0b0100011)),
              (f"sw x17,{i*8+4}(x10)", S(i * 8 + 4, 17, 10, 0b010, 0b0100011))]
    p += [
        ("fld f25,0(x10)",  FLD(25, 10, 0)),    # 1.5
        ("fld f26,8(x10)",  FLD(26, 10, 8)),    # 0.5
        ("fld f27,16(x10)", FLD(27, 10, 16)),   # 0.1
        ("fld f28,24(x10)", FLD(28, 10, 24)),   # 0.2
        ("fadd.d f29,f25,f26", FADD_D(29, 25, 26)),  # 2.0
        ("fmul.d f30,f25,f26", FMUL_D(30, 25, 26)),  # 0.75
        ("fsub.d f31,f26,f25", FSUB_D(31, 26, 25)),  # -1.0
        ("fadd.d f8,f27,f28",  FADD_D(8, 27, 28)),   # 0.1 + 0.2 (double, inexact)
    ]
    return p


PROG_FARITH = _build_prog_farith()


# FP conversion program (M5): fcvt int<->float and single<->double, all five rounding modes,
# saturation + NV on out-of-range / NaN / inf float->int, NX on inexact int results and on
# narrowing, exact widening and exact int->double. Per-op exception flags are isolated for a
# representative subset via csrrci-clear + csrrs-read.
def _build_prog_fcvt():
    p = []

    def li1(v):
        return li(1, v)

    def clear():
        return [("csrrci x0,fflags,0x1f", CSRRCI(0, FFLAGS, 0x1F))]

    def readflags(rd):
        return [(f"csrrs x{rd},fflags,x0", CSRRS(rd, FFLAGS, 0))]

    # ---- int -> float (operand from integer x1) ----
    p += li1(5)
    p += [("fcvt.s.w  f0,x1", FCVT_S_W(0, 1)),      # 5.0
          ("fcvt.d.w  f1,x1", FCVT_D_W(1, 1))]      # 5.0 (double)
    p += li1(u32(-7))
    p += [("fcvt.s.w  f2,x1", FCVT_S_W(2, 1)),      # -7.0
          ("fcvt.d.w  f3,x1", FCVT_D_W(3, 1))]
    p += li1(0x80000000)
    p += [("fcvt.s.w  f4,x1", FCVT_S_W(4, 1)),      # -2^31 (exact single)
          ("fcvt.s.wu f5,x1", FCVT_S_WU(5, 1)),     # +2^31 (exact single)
          ("fcvt.d.w  f6,x1", FCVT_D_W(6, 1)),      # -2^31 (exact double)
          ("fcvt.d.wu f7,x1", FCVT_D_WU(7, 1))]     # +2^31 (exact double)
    p += li1(0xFFFFFFFF)
    p += clear()
    p += [("fcvt.s.wu f8,x1", FCVT_S_WU(8, 1))]     # 2^32-1 -> rounds up (NX)
    p += readflags(2)                               # expect NX = 0x01
    p += [("fcvt.d.wu f9,x1", FCVT_D_WU(9, 1))]     # 2^32-1 exact in double
    p += li1(0x01000001)                            # 16777217 (needs 25 bits)
    p += clear()
    p += [("fcvt.s.w  f10,x1", FCVT_S_W(10, 1))]    # ties-to-even -> 16777216 (NX)
    p += readflags(3)                               # expect NX = 0x01
    p += [("fcvt.d.w  f11,x1", FCVT_D_W(11, 1))]    # exact in double

    # ---- float -> int : single sources built via fmv.w.x ----
    def mkS(bits, frd):
        return li1(bits) + [(f"fmv.w.x f{frd},x1", FMV_W_X(frd, 1))]

    p += mkS(0x40200000, 12)    # f12 = 2.5
    p += mkS(0xC0200000, 13)    # f13 = -2.5
    p += mkS(0x40600000, 14)    # f14 = 3.5
    p += mkS(0x7FC00000, 15)    # f15 = qNaN
    p += mkS(0x7F800000, 16)    # f16 = +inf
    p += mkS(0xFF800000, 17)    # f17 = -inf
    p += mkS(0xBF000000, 18)    # f18 = -0.5
    p += mkS(0x4F000000, 19)    # f19 = 2^31
    p += mkS(0x50000000, 20)    # f20 = 2^33 (> 2^32)

    p += clear()
    p += [("fcvt.w.s  x20,f12,rne", FCVT_W_S(20, 12, RM_RNE))]   # 2.5 -> 2 (NX)
    p += readflags(4)                                            # expect NX = 0x01
    p += [("fcvt.w.s  x21,f12,rtz", FCVT_W_S(21, 12, RM_RTZ)),   # 2.5 -> 2
          ("fcvt.w.s  x22,f12,rup", FCVT_W_S(22, 12, RM_RUP)),   # 2.5 -> 3
          ("fcvt.w.s  x23,f13,rdn", FCVT_W_S(23, 13, RM_RDN)),   # -2.5 -> -3
          ("fcvt.w.s  x24,f13,rmm", FCVT_W_S(24, 13, RM_RMM)),   # -2.5 -> -3
          ("fcvt.w.s  x25,f14,rne", FCVT_W_S(25, 14, RM_RNE))]   # 3.5 -> 4
    p += clear()
    p += [("fcvt.w.s  x26,f15", FCVT_W_S(26, 15))]               # NaN -> INT_MAX (NV)
    p += readflags(11)                                           # expect NV = 0x10
    p += [("fcvt.wu.s x27,f15", FCVT_WU_S(27, 15)),              # NaN -> UINT_MAX (NV)
          ("fcvt.w.s  x28,f16", FCVT_W_S(28, 16)),               # +inf -> INT_MAX (NV)
          ("fcvt.w.s  x29,f17", FCVT_W_S(29, 17)),               # -inf -> INT_MIN (NV)
          ("fcvt.wu.s x30,f17", FCVT_WU_S(30, 17))]              # -inf -> 0 (NV)
    p += clear()
    p += [("fcvt.wu.s x31,f18", FCVT_WU_S(31, 18))]              # -0.5 -> 0 (NX, rounds to zero)
    p += readflags(12)                                           # expect NX = 0x01
    p += clear()
    p += [("fcvt.w.s  x5,f19", FCVT_W_S(5, 19))]                 # 2^31 -> INT_MAX (NV, overflow)
    p += readflags(13)                                           # expect NV = 0x10
    p += [("fcvt.wu.s x6,f19", FCVT_WU_S(6, 19)),                # 2^31 -> exact unsigned
          ("fcvt.wu.s x7,f20", FCVT_WU_S(7, 20))]                # 2^33 -> UINT_MAX (NV)

    # ---- float -> int : double sources built in memory ----
    # Data base 0x280 (RAM word 160) sits above the ~147 program words so the shared
    # instruction/data RAM does not alias (fcvt has more instructions than farith).
    p += li(10, 0x280)
    dbls = [
        (0x00000000, 0x40040000),  # 0: 2.5
        (0x00000000, 0xC0040000),  # 1: -2.5
        (0x20000000, 0x4202A05F),  # 2: 1e10 (> 2^32)
        (0x00000000, 0x7FF80000),  # 3: qNaN (double)
    ]
    for i, (lo, hi) in enumerate(dbls):
        p += li(16, lo)
        p += li(17, hi)
        p += [(f"sw x16,{i*8}(x10)", S(i * 8, 16, 10, 0b010, 0b0100011)),
              (f"sw x17,{i*8+4}(x10)", S(i * 8 + 4, 17, 10, 0b010, 0b0100011))]
    p += [("fld f21,0(x10)",  FLD(21, 10, 0)),      # 2.5
          ("fld f22,8(x10)",  FLD(22, 10, 8)),      # -2.5
          ("fld f23,16(x10)", FLD(23, 10, 16)),     # 1e10
          ("fld f24,24(x10)", FLD(24, 10, 24))]     # qNaN
    p += [("fcvt.w.d  x8,f21,rne",  FCVT_W_D(8, 21, RM_RNE)),    # 2.5 -> 2
          ("fcvt.w.d  x9,f22,rdn",  FCVT_W_D(9, 22, RM_RDN)),    # -2.5 -> -3
          ("fcvt.wu.d x18,f23",     FCVT_WU_D(18, 23)),          # 1e10 -> UINT_MAX (NV)
          ("fcvt.w.d  x19,f23",     FCVT_W_D(19, 23)),           # 1e10 -> INT_MAX (NV)
          ("fcvt.w.d  x14,f24",     FCVT_W_D(14, 24))]           # NaN -> INT_MAX (NV)

    # ---- float <-> float ----
    # widen (exact): single 2.5 (f12) and single 0.1 -> double
    p += mkS(0x3DCCCCCD, 0)      # f0 = single 0.1 (overwrite f0; last-write semantics)
    p += [("fcvt.d.s  f25,f12", FCVT_D_S(25, 12)),  # 2.5f -> 2.5d (exact)
          ("fcvt.d.s  f26,f0",  FCVT_D_S(26, 0))]   # 0.1f -> exact double of the single bits
    # narrow (rounds): doubles built above and two new ones for OF/UF
    p += li(16, 0x9999999A)
    p += li(17, 0x3FB99999)
    p += [("sw x16,32(x10)", S(32, 16, 10, 0b010, 0b0100011)),
          ("sw x17,36(x10)", S(36, 17, 10, 0b010, 0b0100011))]   # 0.1 double
    p += li(16, 0x8800759C)
    p += li(17, 0x7E37E43C)
    p += [("sw x16,40(x10)", S(40, 16, 10, 0b010, 0b0100011)),
          ("sw x17,44(x10)", S(44, 17, 10, 0b010, 0b0100011))]   # 1e300 double
    p += li(16, 0xB1552D83)
    p += li(17, 0x37D5C72F)
    p += [("sw x16,48(x10)", S(48, 16, 10, 0b010, 0b0100011)),
          ("sw x17,52(x10)", S(52, 17, 10, 0b010, 0b0100011))]   # 1e-40 double
    p += [("fld f27,32(x10)", FLD(27, 10, 32)),     # 0.1 double
          ("fld f28,40(x10)", FLD(28, 10, 40)),     # 1e300 double
          ("fld f29,48(x10)", FLD(29, 10, 48))]     # 1e-40 double
    p += clear()
    p += [("fcvt.s.d  f30,f27", FCVT_S_D(30, 27))]  # 0.1d -> single 0.1 (NX)
    p += readflags(15)                              # expect NX = 0x01
    p += [("fcvt.s.d  f31,f21", FCVT_S_D(31, 21))]  # 2.5d -> 2.5f (exact)
    p += clear()
    p += [("fcvt.s.d  f8,f28", FCVT_S_D(8, 28))]    # 1e300 -> +inf (OF|NX)
    p += readflags(20)                              # expect 0x05
    p += clear()
    p += [("fcvt.s.d  f9,f29", FCVT_S_D(9, 29))]    # 1e-40 -> single subnormal (UF|NX)
    p += readflags(21)                              # expect 0x03
    # Halt: jal x0,0 loops on itself so the PC never walks into the data region (word 160+),
    # whose double-precision constants would otherwise be fetched and executed as garbage.
    p += [("j .", 0x0000006F)]
    return p


PROG_FCVT = _build_prog_fcvt()


# FP divide / square root program (M6): exercises fdiv/fsqrt on single and double, all with
# exact and inexact results, several rounding modes, and the special/exception cases (x/0 -> DZ,
# 0/0 and sqrt(neg) -> NV, overflow -> OF|NX). fdiv/fsqrt are multi-cycle, so this also exercises
# the pipeline freeze (ex_stall) and single-shot fflags accrual. Doubles are materialized in the
# data region (base 0x200 = RAM word 128) via sw pairs + fld; singles via fmv.w.x.
def _build_prog_fdivsqrt():
    import struct

    def dbits(x):
        return struct.unpack("<Q", struct.pack("<d", x))[0]

    def sbits(x):
        return struct.unpack("<I", struct.pack("<f", x))[0]

    p = []

    # ---- single operands into f0..f7 via fmv.w.x (scratch x1) ----
    singles = [(0, 1.0), (1, 3.0), (2, 7.0), (3, 2.0), (4, 0.0), (5, -1.0), (6, 4.0), (7, 9.0)]
    for fr, val in singles:
        p += li(1, sbits(val))
        p += [(f"fmv.w.x f{fr},x1  # {val}", FMV_W_X(fr, 1))]

    # ---- single divides / sqrts ----
    p += [
        ("fdiv.s f8,f0,f1,rne",  FDIV_S(8, 0, 1, RM_RNE)),    # 1/3 -> 0x3EAAAAAB (NX)
        ("fdiv.s f9,f0,f1,rtz",  FDIV_S(9, 0, 1, RM_RTZ)),    # 1/3 truncated
        ("fdiv.s f10,f0,f1,rup", FDIV_S(10, 0, 1, RM_RUP)),   # 1/3 rounded up
        ("fdiv.s f11,f2,f3",     FDIV_S(11, 2, 3, RM_RNE)),   # 7/2 = 3.5 exact
    ]
    # x/0 -> +inf + DZ (isolate flags into x5)
    p += [("csrrci x0,fflags,0x1f", CSRRCI(0, FFLAGS, 0x1f)),
          ("fdiv.s f12,f0,f4",     FDIV_S(12, 0, 4, RM_RNE)),  # 1/0 -> +inf
          ("csrrs x5,fflags,x0",   CSRRS(5, FFLAGS, 0))]       # x5 = 0x08 (DZ)
    p += [("fdiv.s f13,f5,f4",     FDIV_S(13, 5, 4, RM_RNE))]  # -1/0 -> -inf
    # 0/0 -> qNaN + NV (isolate into x6)
    p += [("csrrci x0,fflags,0x1f", CSRRCI(0, FFLAGS, 0x1f)),
          ("fdiv.s f14,f4,f4",     FDIV_S(14, 4, 4, RM_RNE)),  # 0/0 -> qNaN
          ("csrrs x6,fflags,x0",   CSRRS(6, FFLAGS, 0))]       # x6 = 0x10 (NV)
    p += [
        ("fsqrt.s f15,f6",       FSQRT_S(15, 6, RM_RNE)),      # sqrt(4) = 2 exact
        ("fsqrt.s f16,f3",       FSQRT_S(16, 3, RM_RNE)),      # sqrt(2) -> 0x3FB504F3 (NX)
        ("fsqrt.s f17,f7",       FSQRT_S(17, 7, RM_RNE)),      # sqrt(9) = 3 exact
    ]
    # sqrt(-1) -> qNaN + NV (isolate into x7)
    p += [("csrrci x0,fflags,0x1f", CSRRCI(0, FFLAGS, 0x1f)),
          ("fsqrt.s f18,f5",       FSQRT_S(18, 5, RM_RNE)),    # sqrt(-1) -> qNaN
          ("csrrs x7,fflags,x0",   CSRRS(7, FFLAGS, 0))]       # x7 = 0x10 (NV)

    # ---- double operands into f20..f25 via data region (base 0x200 in x10) ----
    p += li(10, 0x200)
    dbl_ops = [(20, 1.0), (21, 3.0), (22, 2.0), (23, 4.0), (24, 1e300), (25, 1e-300)]
    for i, (fr, val) in enumerate(dbl_ops):
        off = i * 8
        bits = dbits(val)
        p += li(16, bits & MASK)
        p += [(f"sw x16,{off}(x10)", S(off, 16, 10, 0b010, 0b0100011))]
        p += li(17, (bits >> 32) & MASK)
        p += [(f"sw x17,{off + 4}(x10)", S(off + 4, 17, 10, 0b010, 0b0100011))]
        p += [(f"fld f{fr},{off}(x10)  # {val}", FLD(fr, 10, off))]

    # ---- double divides / sqrts ----
    p += [
        ("fdiv.d f26,f20,f21,rne", FDIV_D(26, 20, 21, RM_RNE)),  # 1/3 -> 0x3FD5555555555555 (NX)
        ("fdiv.d f27,f20,f21,rtz", FDIV_D(27, 20, 21, RM_RTZ)),  # 1/3 truncated
        ("fdiv.d f28,f22,f23",     FDIV_D(28, 22, 23, RM_RNE)),  # 2/4 = 0.5 exact
    ]
    # overflow: 1e300 / 1e-300 -> +inf + OF|NX (isolate into x8)
    p += [("csrrci x0,fflags,0x1f", CSRRCI(0, FFLAGS, 0x1f)),
          ("fdiv.d f29,f24,f25",   FDIV_D(29, 24, 25, RM_RNE)),  # -> +inf, OF|NX
          ("csrrs x8,fflags,x0",   CSRRS(8, FFLAGS, 0))]         # x8 = 0x05
    p += [
        ("fsqrt.d f30,f22",      FSQRT_D(30, 22, RM_RNE)),       # sqrt(2) -> 0x3FF6A09E667F3BCD (NX)
        ("fsqrt.d f31,f23",      FSQRT_D(31, 23, RM_RNE)),       # sqrt(4) = 2 exact
    ]

    p += [("j .", 0x0000006F)]   # self-loop halt so PC never runs into the data region
    return p


PROG_FDIVSQRT = _build_prog_fdivsqrt()


# Fused multiply-add regression (M7): all four variants (fmadd/fmsub/fnmsub/fnmadd) for single and
# double, plus fused exactness (no intermediate product rounding), exact cancellation, several
# rounding modes, and the special/exception cases (overflow -> OF|NX, inf*0 -> NV). Also exercises
# the rs3 read port and the FP interlock via a back-to-back producer->consumer FMA dependency.
def _build_prog_fma():
    import struct

    def dbits(x):
        return struct.unpack("<Q", struct.pack("<d", x))[0]

    def sbits(x):
        return struct.unpack("<I", struct.pack("<f", x))[0]

    p = []

    # ---- single operands into f0..f7 via fmv.w.x (scratch x1) ----
    singles = [(0, 2.0), (1, 3.0), (2, 1.0), (3, 1.5), (4, 0.0), (5, 1e30), (6, 0.1), (7, 0.2)]
    for fr, val in singles:
        p += li(1, sbits(val))
        p += [(f"fmv.w.x f{fr},x1  # {val}", FMV_W_X(fr, 1))]

    # ---- single fused multiply-adds ----
    p += [
        ("fmadd.s  f8,f0,f1,f2",  FMADD_S(8, 0, 1, 2)),      # 2*3+1 = 7.0 exact
        ("fmsub.s  f9,f3,f3,f0",  FMSUB_S(9, 3, 3, 0)),      # 1.5*1.5-2 = 0.25 exact
        ("fnmsub.s f10,f0,f1,f2", FNMSUB_S(10, 0, 1, 2)),    # -(2*3)+1 = -5.0
        ("fnmadd.s f11,f0,f1,f2", FNMADD_S(11, 0, 1, 2)),    # -(2*3)-1 = -7.0
        ("fmadd.s  f12,f6,f1,f7", FMADD_S(12, 6, 1, 7)),     # 0.1*3+0.2 = 0.5 (fused, NX)
        ("fmadd.s  f15,f8,f2,f4", FMADD_S(15, 8, 2, 4)),     # 7*1+0 = 7.0 (interlock on f8)
    ]
    # overflow: 1e30*1e30 + 0 -> +inf, OF|NX (isolate into x5)
    p += [("csrrci x0,fflags,0x1f", CSRRCI(0, FFLAGS, 0x1f)),
          ("fmadd.s f13,f5,f5,f4", FMADD_S(13, 5, 5, 4)),    # +inf, OF|NX
          ("csrrs x5,fflags,x0",   CSRRS(5, FFLAGS, 0))]     # x5 = 0x05
    # RUP inexact: 0.1*0.1 + 0 rounded up -> NX (isolate into x9)
    p += [("csrrci x0,fflags,0x1f", CSRRCI(0, FFLAGS, 0x1f)),
          ("fmadd.s f14,f6,f6,f4,rup", FMADD_S(14, 6, 6, 4, RM_RUP)),
          ("csrrs x9,fflags,x0",   CSRRS(9, FFLAGS, 0))]     # x9 = 0x01 (NX)

    # ---- double operands into f20..f27 via data region (base 0x200 in x10) ----
    p += li(10, 0x200)
    dbl_ops = [(20, 2.0), (21, 3.0), (22, 1.0), (23, None), (24, 1e300),
               (25, 0.0), (26, None), (27, 4.0)]
    dbl_bits = {23: 0x3FF0000000000001,   # 1 + 2^-52 (tests exact fused product)
                26: 0x7FF0000000000000}   # +inf
    for i, (fr, val) in enumerate(dbl_ops):
        off = i * 8
        bits = dbl_bits[fr] if val is None else dbits(val)
        p += li(16, bits & MASK)
        p += [(f"sw x16,{off}(x10)", S(off, 16, 10, 0b010, 0b0100011))]
        p += li(17, (bits >> 32) & MASK)
        p += [(f"sw x17,{off + 4}(x10)", S(off + 4, 17, 10, 0b010, 0b0100011))]
        p += [(f"fld f{fr},{off}(x10)", FLD(fr, 10, off))]

    # ---- double fused multiply-adds ----
    p += [
        ("fmadd.d  f16,f20,f21,f22", FMADD_D(16, 20, 21, 22)),   # 2*3+1 = 7.0
        ("fmsub.d  f17,f20,f21,f22", FMSUB_D(17, 20, 21, 22)),   # 2*3-1 = 5.0
        ("fnmsub.d f18,f20,f21,f22", FNMSUB_D(18, 20, 21, 22)),  # -(2*3)+1 = -5.0
        ("fnmadd.d f19,f20,f21,f22", FNMADD_D(19, 20, 21, 22)),  # -(2*3)-1 = -7.0
        ("fmsub.d  f28,f23,f23,f22", FMSUB_D(28, 23, 23, 22)),   # (1+2^-52)^2 - 1 (exact fused, NX)
        ("fmsub.d  f29,f22,f22,f22", FMSUB_D(29, 22, 22, 22)),   # 1*1-1 = +0.0 exact cancellation
    ]
    # overflow: 1e300*1e300 + 0 -> +inf, OF|NX (isolate into x6)
    p += [("csrrci x0,fflags,0x1f", CSRRCI(0, FFLAGS, 0x1f)),
          ("fmadd.d f30,f24,f24,f25", FMADD_D(30, 24, 24, 25)),  # +inf, OF|NX
          ("csrrs x6,fflags,x0",   CSRRS(6, FFLAGS, 0))]         # x6 = 0x05
    # inf*0 + finite -> qNaN, NV (isolate into x7)
    p += [("csrrci x0,fflags,0x1f", CSRRCI(0, FFLAGS, 0x1f)),
          ("fmadd.d f31,f26,f25,f22", FMADD_D(31, 26, 25, 22)),  # inf*0 -> qNaN, NV
          ("csrrs x7,fflags,x0",   CSRRS(7, FFLAGS, 0))]         # x7 = 0x10

    p += [("j .", 0x0000006F)]   # self-loop halt
    return p


PROG_FMA = _build_prog_fma()

PROGRAMS = {"m": PROG_M, "csr": PROG_CSR, "fp": PROG_FP}


def golden(prog):
    """Return dict {reg: last_committed_u32_value} by architectural simulation.

    Includes any register that is the destination of a committing instruction, even
    when the result is 0 (e.g. divu 6/7, rem INT_MIN/-1), so the check matches the
    hardware writeback stream exactly.
    """
    reg = [0] * 32
    written = set()
    fflags = 0   # NV(4) DZ(3) OF(2) UF(1) NX(0)
    frm = 0

    def csr_read(addr):
        if addr == FFLAGS:
            return fflags & 0x1F
        if addr == FRM:
            return frm & 0x7
        if addr == FCSR:
            return ((frm & 0x7) << 5) | (fflags & 0x1F)
        return 0

    def csr_write(addr, v):
        nonlocal fflags, frm
        if addr == FFLAGS:
            fflags = v & 0x1F
        elif addr == FRM:
            frm = v & 0x7
        elif addr == FCSR:
            frm = (v >> 5) & 0x7
            fflags = v & 0x1F

    def divs(a, b):
        a, b = s32(a), s32(b)
        if b == 0:
            return MASK
        if a == -(1 << 31) and b == -1:
            return u32(-(1 << 31))
        q = abs(a) // abs(b)
        if (a < 0) != (b < 0):
            q = -q
        return u32(q)

    def rems(a, b):
        a, b = s32(a), s32(b)
        if b == 0:
            return u32(a)
        if a == -(1 << 31) and b == -1:
            return 0
        r = abs(a) % abs(b)
        if a < 0:
            r = -r
        return u32(r)

    ops = {
        0: lambda a, b: u32(u32(a) * u32(b)),
        1: lambda a, b: u32((s32(a) * s32(b)) >> 32),
        2: lambda a, b: u32((s32(a) * u32(b)) >> 32),
        3: lambda a, b: u32((u32(a) * u32(b)) >> 32),
        4: divs,
        5: lambda a, b: MASK if u32(b) == 0 else u32(u32(a) // u32(b)),
        6: rems,
        7: lambda a, b: u32(a) if u32(b) == 0 else u32(u32(a) % u32(b)),
    }

    for _, word in prog:
        opcode = word & 0x7F
        rd = (word >> 7) & 0x1F
        rs1 = (word >> 15) & 0x1F
        rs2 = (word >> 20) & 0x1F
        funct3 = (word >> 12) & 0x7
        funct7 = (word >> 25) & 0x7F
        val = None
        if opcode == 0b0010011 and funct3 == 0:      # addi
            val = u32(reg[rs1] + s32(sext12(word >> 20)))
        elif opcode == 0b0110111:                     # lui
            val = u32(((word >> 12) & 0xFFFFF) << 12)
        elif opcode == 0b0110011 and funct7 == 0b0000001:  # M op
            val = ops[funct3](reg[rs1], reg[rs2])
        elif opcode == 0b0110011 and funct3 == 0 and funct7 == 0:  # add
            val = u32(reg[rs1] + reg[rs2])
        elif opcode == 0b1110011 and funct3 != 0:     # CSR op
            addr = (word >> 20) & 0xFFF
            old = csr_read(addr)
            imm = funct3 & 0b100          # immediate form?
            src = rs1 if imm else reg[rs1]
            lo2 = funct3 & 0b011
            write = (lo2 == 0b01) or (rs1 != 0)   # RW always; S/C only if specifier != 0
            if lo2 == 0b01:
                new = src
            elif lo2 == 0b10:
                new = old | src
            else:
                new = old & (~src & 0xFFFFFFFF)
            if write:
                csr_write(addr, new)
            val = u32(old)
        if val is not None and rd != 0:
            reg[rd] = val
            written.add(rd)
    return {i: reg[i] for i in sorted(written)}


def sext12(v):
    v &= 0xFFF
    return v - (1 << 12) if v & 0x800 else v


NANBOX = 0xFFFFFFFF00000000  # upper 32 bits set marks a boxed single


def golden_fp(prog):
    """Architectural model for the FP load/store/move program.

    Returns (int_regs, fp_regs): {reg: u32} for integer writebacks and {freg: u64} for
    FP-register writebacks (f0 included -- it is a real register). Models a little-endian
    byte-addressable data memory shared by integer and FP loads/stores.
    """
    reg = [0] * 32
    freg = [0] * 32
    int_written = set()
    fp_written = set()
    mem = {}  # byte address -> byte value

    def load(addr, n):
        v = 0
        for k in range(n):
            v |= mem.get(addr + k, 0) << (8 * k)
        return v

    def store(addr, v, n):
        for k in range(n):
            mem[addr + k] = (v >> (8 * k)) & 0xFF

    for _, word in prog:
        opcode = word & 0x7F
        rd = (word >> 7) & 0x1F
        rs1 = (word >> 15) & 0x1F
        rs2 = (word >> 20) & 0x1F
        funct3 = (word >> 12) & 0x7
        funct7 = (word >> 25) & 0x7F
        imm_i = s32(sext12(word >> 20))
        imm_s = s32(sext12((((word >> 25) & 0x7F) << 5) | ((word >> 7) & 0x1F)))

        if opcode == 0b0010011 and funct3 == 0:          # addi
            if rd:
                reg[rd] = u32(reg[rs1] + imm_i); int_written.add(rd)
        elif opcode == 0b0110111:                          # lui
            if rd:
                reg[rd] = u32(((word >> 12) & 0xFFFFF) << 12); int_written.add(rd)
        elif opcode == 0b0100011:                          # integer store (sb/sh/sw)
            addr = u32(reg[rs1] + imm_s)
            n = {0: 1, 1: 2, 2: 4}[funct3]
            store(addr, reg[rs2], n)
        elif opcode == 0b0000111:                          # FP load (flw/fld)
            addr = u32(reg[rs1] + imm_i)
            if funct3 == 0b011:                            # fld
                freg[rd] = load(addr, 8)
            else:                                          # flw (NaN-boxed)
                freg[rd] = NANBOX | load(addr, 4)
            fp_written.add(rd)
        elif opcode == 0b0100111:                          # FP store (fsw/fsd)
            addr = u32(reg[rs1] + imm_s)
            if funct3 == 0b011:                            # fsd
                store(addr, freg[rs2] & ((1 << 64) - 1), 8)
            else:                                          # fsw (low 32 bits)
                store(addr, freg[rs2] & MASK, 4)
        elif opcode == 0b1010011 and funct7 == 0b1111000:  # fmv.w.x (int -> fp, NaN-box)
            freg[rd] = NANBOX | u32(reg[rs1]); fp_written.add(rd)
        elif opcode == 0b1010011 and funct7 == 0b1110000:  # fmv.x.w (fp(31:0) -> int)
            if rd:
                reg[rd] = freg[rs1] & MASK; int_written.add(rd)

    return ({i: reg[i] for i in sorted(int_written)},
            {i: freg[i] for i in sorted(fp_written)})


def golden_fmisc(prog):
    """Architectural model for the FP misc program (fsgnj/n/x, fmin/max, feq/flt/fle, fclass).

    Mirrors fp_misc.vhd bit-for-bit: single operands are NaN-unboxed on entry (non-boxed ->
    canonical qNaN) and single FP results are NaN-boxed on exit; comparisons/fclass produce
    integer results; NV is accrued into fflags and read out at the end via csrrs.
    Returns (int_regs, fp_regs) like golden_fp.
    """
    reg = [0] * 32
    freg = [0] * 32
    int_written, fp_written = set(), set()
    mem = {}
    fflags = 0

    QNAN_S, QNAN_D = 0x7FC00000, 0x7FF8000000000000

    def load(addr, n):
        v = 0
        for k in range(n):
            v |= mem.get(addr + k, 0) << (8 * k)
        return v

    def store(addr, v, n):
        for k in range(n):
            mem[addr + k] = (v >> (8 * k)) & 0xFF

    def unbox_s(x):
        return x & MASK if (x >> 32) & MASK == 0xFFFFFFFF else QNAN_S

    def classify(v, dbl):
        """Return (sign, exp, frac, mag, is_zero, is_inf, is_nan, is_snan)."""
        if dbl:
            s = (v >> 63) & 1
            exp = (v >> 52) & 0x7FF
            frac = v & ((1 << 52) - 1)
            mag = v & ((1 << 63) - 1)
            emax = (exp == 0x7FF)
            topfrac = (v >> 51) & 1
        else:
            s = (v >> 31) & 1
            exp = (v >> 23) & 0xFF
            frac = v & ((1 << 23) - 1)
            mag = v & ((1 << 31) - 1)
            emax = (exp == 0xFF)
            topfrac = (v >> 22) & 1
        is_zero = (exp == 0 and frac == 0)
        is_inf = (emax and frac == 0)
        is_nan = (emax and frac != 0)
        is_snan = (is_nan and topfrac == 0)
        return s, exp, frac, mag, is_zero, is_inf, is_nan, is_snan

    def box_single(x):
        return NANBOX | (x & MASK)

    for _, word in prog:
        opcode = word & 0x7F
        rd = (word >> 7) & 0x1F
        rs1 = (word >> 15) & 0x1F
        rs2 = (word >> 20) & 0x1F
        funct3 = (word >> 12) & 0x7
        funct7 = (word >> 25) & 0x7F
        funct5 = (word >> 27) & 0x1F
        fmt = (word >> 25) & 0x3
        imm_i = s32(sext12(word >> 20))
        imm_s = s32(sext12((((word >> 25) & 0x7F) << 5) | ((word >> 7) & 0x1F)))

        if opcode == 0b0010011 and funct3 == 0:            # addi
            if rd:
                reg[rd] = u32(reg[rs1] + imm_i); int_written.add(rd)
        elif opcode == 0b0110111:                            # lui
            if rd:
                reg[rd] = u32(((word >> 12) & 0xFFFFF) << 12); int_written.add(rd)
        elif opcode == 0b0100011:                            # integer store
            addr = u32(reg[rs1] + imm_s)
            store(addr, reg[rs2], {0: 1, 1: 2, 2: 4}[funct3])
        elif opcode == 0b0000111:                            # FP load
            addr = u32(reg[rs1] + imm_i)
            freg[rd] = load(addr, 8) if funct3 == 0b011 else (NANBOX | load(addr, 4))
            fp_written.add(rd)
        elif opcode == 0b0100111:                            # FP store
            addr = u32(reg[rs1] + imm_s)
            if funct3 == 0b011:
                store(addr, freg[rs2] & ((1 << 64) - 1), 8)
            else:
                store(addr, freg[rs2] & MASK, 4)
        elif opcode == 0b1110011 and funct3 != 0:            # csrrs fflags (read accrued flags)
            addr = (word >> 20) & 0xFFF
            old = fflags & 0x1F if addr == FFLAGS else (
                ((0) << 5) | (fflags & 0x1F) if addr == FCSR else 0)
            if rd:
                reg[rd] = u32(old); int_written.add(rd)
        elif opcode == 0b1010011:                            # FP-OP
            dbl = (fmt == 0b01)
            if funct7 == 0b1111000:                          # fmv.w.x
                freg[rd] = NANBOX | u32(reg[rs1]); fp_written.add(rd); continue
            if funct7 == 0b1110000 and funct3 == 0:          # fmv.x.w
                if rd:
                    reg[rd] = freg[rs1] & MASK; int_written.add(rd)
                continue
            # Unbox operands
            araw, braw = freg[rs1], freg[rs2]
            if dbl:
                av, bv = araw & ((1 << 64) - 1), braw & ((1 << 64) - 1)
            else:
                av, bv = unbox_s(araw), unbox_s(braw)
            sa, ea, fa, maga, za, ia, na, sna = classify(av, dbl)
            sb, eb, fb, magb, zb, ib, nb, snb = classify(bv, dbl)

            # Ordered comparison (valid only when neither is NaN)
            if za and zb:
                eq, lt = True, False
            elif sa != sb:
                eq, lt = False, (sa == 1)
            elif sa == 0:
                eq, lt = (maga == magb), (maga < magb)
            else:
                eq, lt = (maga == magb), (maga > magb)

            nv = 0
            res_fp = 0
            res_int = 0
            if funct5 == 0b00100:                            # fsgnj/n/x
                if funct3 == 0b000:
                    sgn = sb
                elif funct3 == 0b001:
                    sgn = sb ^ 1
                else:
                    sgn = sa ^ sb
                if dbl:
                    res_fp = (sgn << 63) | (av & ((1 << 63) - 1))
                else:
                    res_fp = (sgn << 31) | (av & ((1 << 31) - 1))
            elif funct5 == 0b00101:                          # fmin/fmax
                if sna or snb:
                    nv = 1
                if na and nb:
                    res_fp = QNAN_D if dbl else QNAN_S
                elif na:
                    res_fp = bv
                elif nb:
                    res_fp = av
                else:
                    if funct3 == 0b000:                      # fmin
                        pick_a = lt or (eq and sa == 1)
                    else:                                     # fmax
                        pick_a = (not lt and not eq) or (eq and sa == 0)
                    res_fp = av if pick_a else bv
            elif funct5 == 0b10100:                          # feq/flt/fle
                if funct3 == 0b010:                          # feq (quiet)
                    if sna or snb:
                        nv = 1
                    res_int = 1 if (not (na or nb) and eq) else 0
                elif funct3 == 0b001:                        # flt (signaling)
                    if na or nb:
                        nv = 1; res_int = 0
                    else:
                        res_int = 1 if lt else 0
                else:                                         # fle (signaling)
                    if na or nb:
                        nv = 1; res_int = 0
                    else:
                        res_int = 1 if (lt or eq) else 0
            elif funct5 == 0b11100 and funct3 == 0b001:      # fclass
                cls = 0
                if na:
                    cls = (1 << 8) if sna else (1 << 9)
                elif ia:
                    cls = (1 << 0) if sa else (1 << 7)
                elif za:
                    cls = (1 << 3) if sa else (1 << 4)
                elif ea == 0:                                # subnormal
                    cls = (1 << 2) if sa else (1 << 5)
                else:                                         # normal
                    cls = (1 << 1) if sa else (1 << 6)
                res_int = cls

            # NaN-box single FP results
            if not dbl:
                res_fp = box_single(res_fp)

            fflags |= (nv << 4)
            is_fp_res = funct5 in (0b00100, 0b00101)
            if is_fp_res:
                freg[rd] = res_fp & ((1 << 64) - 1); fp_written.add(rd)
            else:
                if rd:
                    reg[rd] = u32(res_int); int_written.add(rd)

    return ({i: reg[i] for i in sorted(int_written)},
            {i: freg[i] for i in sorted(fp_written)})


# ---------------------------------------------------------------------------
# Independent IEEE-754 reference for fadd/fsub/fmul (fractions-based exact value +
# correctly-rounded quantization for all five rounding modes; tininess after rounding).
# This is deliberately written NOT to mirror the VHDL, so it is a true oracle.
# ---------------------------------------------------------------------------
from fractions import Fraction

_RNE, _RTZ, _RDN, _RUP, _RMM = 0, 1, 2, 3, 4


def _fmt_params(dbl):
    # MW (fraction bits), BIAS, EMIN (min normal unbiased exp), EW (exp bits)
    return (52, 1023, -1022, 11) if dbl else (23, 127, -126, 8)


def _fp_fields(v, dbl):
    if dbl:
        s = (v >> 63) & 1; e = (v >> 52) & 0x7FF; f = v & ((1 << 52) - 1)
        emax = (e == 0x7FF); top = (v >> 51) & 1
    else:
        s = (v >> 31) & 1; e = (v >> 23) & 0xFF; f = v & ((1 << 23) - 1)
        emax = (e == 0xFF); top = (v >> 22) & 1
    return s, e, f, (e == 0 and f == 0), (emax and f == 0), (emax and f != 0), (emax and f != 0 and top == 0)


def _fp_mag(v, dbl):
    """Magnitude (>=0 Fraction) of a finite value."""
    MW, BIAS, EMIN, _ = _fmt_params(dbl)
    _, e, f, _, _, _, _ = _fp_fields(v, dbl)
    if e == 0:
        return Fraction(f) * Fraction(2) ** (EMIN - MW)
    return Fraction((1 << MW) | f) * Fraction(2) ** (e - BIAS - MW)


def _floor_log2(m):
    """Integer e with 2^e <= m < 2^(e+1) for Fraction m > 0."""
    e = 0
    two = Fraction(2)
    if m >= 1:
        while two ** (e + 1) <= m:
            e += 1
    else:
        while two ** e > m:
            e -= 1
    return e


def _round_real(m, s, dbl, rm):
    """Round positive real magnitude m (Fraction) with sign s to (bits, of, uf, nx)."""
    MW, BIAS, EMIN, EW = _fmt_params(dbl)
    EXPMAX = (1 << EW) - 1
    sbit = 63 if dbl else 31
    e = _floor_log2(m)
    scale = max(e, EMIN) - MW
    scaled = m / (Fraction(2) ** scale)
    qf = scaled.numerator // scaled.denominator
    rem = scaled - qf
    nx = 1 if rem != 0 else 0
    half = Fraction(1, 2)
    if rem == 0:
        q = qf
    elif rm == _RNE:
        q = qf + 1 if rem > half else (qf if rem < half else qf + (qf & 1))
    elif rm == _RTZ:
        q = qf
    elif rm == _RDN:
        q = qf + (1 if s == 1 else 0)
    elif rm == _RUP:
        q = qf + (1 if s == 0 else 0)
    else:  # _RMM
        q = qf + (1 if rem >= half else 0)

    if q >= (1 << (MW + 1)):     # rounding carried out of the significand
        q >>= 1
        scale += 1

    if q == 0:                   # flushed to zero (necessarily tiny + inexact)
        return (s << sbit), 0, nx, nx

    unbiased = scale + MW
    if q >= (1 << MW):           # normal
        E = unbiased + BIAS
        frac = q - (1 << MW)
        if E >= EXPMAX:          # overflow
            if rm == _RTZ:
                inf = False
            elif rm == _RDN:
                inf = (s == 1)
            elif rm == _RUP:
                inf = (s == 0)
            else:
                inf = True
            if inf:
                return (s << sbit) | (EXPMAX << MW), 1, 0, 1
            return (s << sbit) | ((EXPMAX - 1) << MW) | ((1 << MW) - 1), 1, 0, 1
        return (s << sbit) | (E << MW) | frac, 0, 0, nx
    # subnormal
    return (s << sbit) | q, 0, nx, nx


def _qnan(dbl):
    return 0x7FF8000000000000 if dbl else 0x7FC00000


def _inf(s, dbl):
    MW, _, _, EW = _fmt_params(dbl)
    return (s << (63 if dbl else 31)) | (((1 << EW) - 1) << MW)


def _do_addsub(av, bv, dbl, rm, is_sub):
    sa, _, _, za, ia, na, sna = _fp_fields(av, dbl)
    sb, _, _, zb, ib, nb, snb = _fp_fields(bv, dbl)
    if is_sub:
        sb ^= 1
    sbit = 63 if dbl else 31
    if na or nb:
        return _qnan(dbl), (0x10 if (sna or snb) else 0)
    if ia or ib:
        if ia and ib:
            if sa != sb:
                return _qnan(dbl), 0x10           # inf - inf
            return _inf(sa, dbl), 0
        return _inf(sa if ia else sb, dbl), 0
    va = (-1 if sa else 1) * _fp_mag(av, dbl)
    vb = (-1 if sb else 1) * _fp_mag(bv, dbl)
    res = va + vb
    if res == 0:
        if za and zb and sa == sb:
            s = sa
        else:
            s = 1 if rm == _RDN else 0            # exact-zero sum: -0 only under round-down
        return (s << sbit), 0
    s = 1 if res < 0 else 0
    bits, of, uf, nx = _round_real(abs(res), s, dbl, rm)
    return bits, (of << 2) | (uf << 1) | nx


def _do_mul(av, bv, dbl, rm):
    sa, _, _, za, ia, na, sna = _fp_fields(av, dbl)
    sb, _, _, zb, ib, nb, snb = _fp_fields(bv, dbl)
    sr = sa ^ sb
    if na or nb:
        return _qnan(dbl), (0x10 if (sna or snb) else 0)
    if (ia and zb) or (ib and za):
        return _qnan(dbl), 0x10                   # inf * 0
    if ia or ib:
        return _inf(sr, dbl), 0
    if za or zb:
        return (sr << (63 if dbl else 31)), 0     # signed zero
    bits, of, uf, nx = _round_real(_fp_mag(av, dbl) * _fp_mag(bv, dbl), sr, dbl, rm)
    return bits, (of << 2) | (uf << 1) | nx


# ---------------------------------------------------------------------------
# Independent IEEE-754 reference for the conversions (fcvt). Same oracle style as
# above: exact Fraction value, then correctly-rounded quantization for all five modes.
# ---------------------------------------------------------------------------
def _do_i2f(ival32, dbl, signed_conv, rm):
    """32-bit integer (raw bits) -> float. Returns (bits, flags). NX only (never OF/UF)."""
    ival32 &= MASK
    if signed_conv and (ival32 >> 31):
        s = 1
        mag = (1 << 32) - ival32              # two's-complement magnitude
    else:
        s = 0
        mag = ival32
    sbit = 63 if dbl else 31
    if mag == 0:
        bits = 0                              # +0.0
        fl = 0
    else:
        bits, of, uf, nx = _round_real(Fraction(mag), s, dbl, rm)   # |int| >= 1 -> normal
        fl = nx                               # of/uf impossible for a 32-bit int magnitude
    if not dbl:
        bits = NANBOX | (bits & MASK)
    return bits & ((1 << 64) - 1), fl


def _do_f2i(av, dbl, signed_conv, rm):
    """float -> 32-bit int. Returns (u32 result, flags). NV (saturate) and NX are exclusive."""
    s, e, f, zero, inf, nan, snan = _fp_fields(av, dbl)
    INT_MAX, INT_MIN, UINT_MAX = 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF
    if nan:
        return (INT_MAX if signed_conv else UINT_MAX), 0x10
    if inf:
        if signed_conv:
            return (INT_MIN if s else INT_MAX), 0x10
        return (0 if s else UINT_MAX), 0x10
    if zero:
        return 0, 0
    mag = _fp_mag(av, dbl)                     # Fraction >= 0
    fq = mag.numerator // mag.denominator
    rem = mag - fq
    inexact = rem != 0
    half = Fraction(1, 2)
    if not inexact:
        q = fq
    elif rm == _RTZ:
        q = fq
    elif rm == _RDN:
        q = fq + (1 if s == 1 else 0)          # toward -inf: negative grows in magnitude
    elif rm == _RUP:
        q = fq + (1 if s == 0 else 0)          # toward +inf: positive grows in magnitude
    elif rm == _RMM:
        q = fq + (1 if rem >= half else 0)      # ties to max magnitude
    else:  # _RNE
        q = fq + 1 if rem > half else (fq if rem < half else fq + (fq & 1))

    if signed_conv:
        if s == 0:
            if q > 0x7FFFFFFF:
                return INT_MAX, 0x10
            return q & MASK, (0x01 if inexact else 0)
        else:
            if q > 0x80000000:
                return INT_MIN, 0x10
            return u32(-q), (0x01 if inexact else 0)
    else:
        if s == 1:
            if q == 0:
                return 0, (0x01 if inexact else 0)   # rounds to zero: in range, inexact
            return 0, 0x10                            # negative, magnitude >= 1: below 0
        else:
            if q > 0xFFFFFFFF:
                return UINT_MAX, 0x10
            return q & MASK, (0x01 if inexact else 0)


def _do_f2f(av, dest_dbl, rm):
    """float -> float (source precision is the other format). Returns (bits, flags)."""
    src_dbl = not dest_dbl
    s, e, f, zero, inf, nan, snan = _fp_fields(av, src_dbl)
    sbit = 63 if dest_dbl else 31
    if nan:
        bits = _qnan(dest_dbl); fl = 0x10 if snan else 0
    elif inf:
        bits = _inf(s, dest_dbl); fl = 0
    elif zero:
        bits = (s << sbit); fl = 0
    else:
        bits, of, uf, nx = _round_real(_fp_mag(av, src_dbl), s, dest_dbl, rm)
        fl = (of << 2) | (uf << 1) | nx        # widen is always exact; narrow may round
    if not dest_dbl:
        bits = NANBOX | (bits & MASK)
    return bits & ((1 << 64) - 1), fl


# ---------------------------------------------------------------------------
# Independent IEEE-754 reference for divide and square root (fdiv/fsqrt).
# Division reuses the exact-Fraction _round_real. Square root is irrational, so it uses an
# exact integer-sqrt variant that decides guard/round/sticky by comparing the exact scaled
# radicand against qf^2 and (qf+1/2)^2 -- no floating point, fully correct rounding.
# ---------------------------------------------------------------------------
def _isqrt_frac_floor(X):
    """floor(sqrt(X)) for a Fraction X >= 0, via the identity floor(sqrt(n/d)) = isqrt(n*d)//d."""
    from math import isqrt
    return isqrt(X.numerator * X.denominator) // X.denominator


def _round_sqrt(mag, dbl, rm):
    """Correctly-rounded sqrt of positive Fraction magnitude -> (bits, of, uf, nx). sign always 0.

    sqrt of a finite positive normal/subnormal is always a normal (exponent halves toward 0), so
    only NX is ever set; the normal/subnormal/overflow tail mirrors _round_real for safety.
    """
    MW, BIAS, EMIN, EW = _fmt_params(dbl)
    EXPMAX = (1 << EW) - 1
    sbit = 63 if dbl else 31
    s = 0
    em = _floor_log2(mag)                 # 2^em <= mag < 2^(em+1)
    e = em // 2                           # floor(log2(sqrt(mag)))
    scale = max(e, EMIN) - MW
    X = mag * (Fraction(2) ** (-2 * scale))   # X = (sqrt(mag)/2^scale)^2 = scaled^2
    qf = _isqrt_frac_floor(X)
    if X == Fraction(qf * qf):
        nx = 0
        q = qf
    else:
        nx = 1
        mid = Fraction((2 * qf + 1) ** 2, 4)  # (qf + 1/2)^2
        if rm == _RNE:
            q = qf + 1 if X > mid else (qf if X < mid else qf + (qf & 1))
        elif rm == _RTZ:
            q = qf
        elif rm == _RDN:
            q = qf                          # s == 0
        elif rm == _RUP:
            q = qf + 1                      # s == 0
        else:  # _RMM
            q = qf + 1 if X >= mid else qf

    if q >= (1 << (MW + 1)):
        q >>= 1
        scale += 1
    if q == 0:
        return (s << sbit), 0, nx, nx
    unbiased = scale + MW
    if q >= (1 << MW):
        E = unbiased + BIAS
        frac = q - (1 << MW)
        if E >= EXPMAX:
            return (s << sbit) | (EXPMAX << MW), 1, 0, 1
        return (s << sbit) | (E << MW) | frac, 0, 0, nx
    return (s << sbit) | q, 0, nx, nx


def _do_div(av, bv, dbl, rm):
    sa, _, _, za, ia, na, sna = _fp_fields(av, dbl)
    sb, _, _, zb, ib, nb, snb = _fp_fields(bv, dbl)
    sr = sa ^ sb
    sbit = 63 if dbl else 31
    if na or nb:
        return _qnan(dbl), (0x10 if (sna or snb) else 0)
    if (ia and ib) or (za and zb):
        return _qnan(dbl), 0x10               # inf/inf or 0/0
    if ia:
        return _inf(sr, dbl), 0               # inf / finite (incl inf/0)
    if ib or za:
        return (sr << sbit), 0                # finite/inf or 0/finite -> signed 0
    if zb:
        return _inf(sr, dbl), 0x08            # finite non-zero / 0 -> inf + DZ
    bits, of, uf, nx = _round_real(_fp_mag(av, dbl) / _fp_mag(bv, dbl), sr, dbl, rm)
    return bits, (of << 2) | (uf << 1) | nx


def _do_sqrt(av, dbl, rm):
    s, e, f, zero, inf, nan, snan = _fp_fields(av, dbl)
    sbit = 63 if dbl else 31
    if nan:
        return _qnan(dbl), (0x10 if snan else 0)
    if zero:
        return (s << sbit), 0                 # +/-0 -> same-signed zero
    if s == 1:
        return _qnan(dbl), 0x10               # negative (incl -inf, -normal) -> NV
    if inf:
        return _inf(0, dbl), 0                # +inf
    bits, of, uf, nx = _round_sqrt(_fp_mag(av, dbl), dbl, rm)
    return bits, (of << 2) | (uf << 1) | nx


def _do_fma(av, bv, cv, dbl, op, rm):
    """Exact fused multiply-add: (a*b) +/- c, single rounding. op(1) negates product, op(0) c.

    00 fmadd = a*b+c, 01 fmsub = a*b-c, 10 fnmsub = -a*b+c, 11 fnmadd = -a*b-c.
    Product+addend are summed EXACTLY as rationals, then rounded once via _round_real (so this is
    an independent reference for fp_fma.vhd, not a re-derivation of its accumulator).
    """
    sa, _, _, za, ia, na, sna = _fp_fields(av, dbl)
    sb, _, _, zb, ib, nb, snb = _fp_fields(bv, dbl)
    scc, _, _, zc, ic, nc, snc = _fp_fields(cv, dbl)
    sbit = 63 if dbl else 31
    sp = (sa ^ sb) ^ ((op >> 1) & 1)              # effective product sign
    se = scc ^ (op & 1)                           # effective addend sign
    if na or nb or nc:
        return _qnan(dbl), (0x10 if (sna or snb or snc) else 0)
    if (ia and zb) or (za and ib):
        return _qnan(dbl), 0x10                   # inf * 0
    if ia or ib:                                  # infinite product
        if ic and (se != sp):
            return _qnan(dbl), 0x10               # inf - inf
        return _inf(sp, dbl), 0
    if ic:                                        # finite product + infinite addend
        return _inf(se, dbl), 0
    pmag = _fp_mag(av, dbl) * _fp_mag(bv, dbl)
    cmag = _fp_mag(cv, dbl)
    s = ((-pmag) if sp else pmag) + ((-cmag) if se else cmag)
    if s == 0:
        if sp == se:
            zsign = sp                            # (+.)+(+.) or (-.)+(-.) keeps the sign
        else:
            zsign = 1 if rm == _RDN else 0        # exact cancellation: -0 only under round-down
        return (zsign << sbit), 0
    sign = 1 if s < 0 else 0
    bits, of, uf, nx = _round_real(abs(s), sign, dbl, rm)
    return bits, (of << 2) | (uf << 1) | nx


def golden_farith(prog):
    """Architectural model for the FP arithmetic program. Returns (int_regs, fp_regs).

    Uses the independent IEEE reference above for fadd/fsub/fmul; models fflags accrual and
    the csrrs/csrrci reads/clears used to isolate per-op exception flags. Single results are
    NaN-boxed on write.
    """
    reg = [0] * 32
    freg = [0] * 32
    int_written, fp_written = set(), set()
    mem = {}
    fflags = 0
    frm = 0

    def load(addr, n):
        v = 0
        for k in range(n):
            v |= mem.get(addr + k, 0) << (8 * k)
        return v

    def store(addr, v, n):
        for k in range(n):
            mem[addr + k] = (v >> (8 * k)) & 0xFF

    def unbox_s(x):
        return x & MASK if (x >> 32) & MASK == 0xFFFFFFFF else 0x7FC00000

    for _, word in prog:
        opcode = word & 0x7F
        rd = (word >> 7) & 0x1F
        rs1 = (word >> 15) & 0x1F
        rs2 = (word >> 20) & 0x1F
        funct3 = (word >> 12) & 0x7
        funct7 = (word >> 25) & 0x7F
        funct5 = (word >> 27) & 0x1F
        fmt = (word >> 25) & 0x3
        imm_i = s32(sext12(word >> 20))
        imm_s = s32(sext12((((word >> 25) & 0x7F) << 5) | ((word >> 7) & 0x1F)))

        if opcode == 0b0010011 and funct3 == 0:            # addi
            if rd:
                reg[rd] = u32(reg[rs1] + imm_i); int_written.add(rd)
        elif opcode == 0b0110111:                          # lui
            if rd:
                reg[rd] = u32(((word >> 12) & 0xFFFFF) << 12); int_written.add(rd)
        elif opcode == 0b0100011:                          # integer store
            store(u32(reg[rs1] + imm_s), reg[rs2], {0: 1, 1: 2, 2: 4}[funct3])
        elif opcode == 0b0000111:                          # FP load
            addr = u32(reg[rs1] + imm_i)
            freg[rd] = load(addr, 8) if funct3 == 0b011 else (NANBOX | load(addr, 4))
            fp_written.add(rd)
        elif opcode == 0b0100111:                          # FP store
            addr = u32(reg[rs1] + imm_s)
            store(addr, freg[rs2] & ((1 << 64) - 1), 8) if funct3 == 0b011 else store(addr, freg[rs2] & MASK, 4)
        elif opcode == 0b1110011 and funct3 != 0:          # CSR
            addr = (word >> 20) & 0xFFF
            is_imm = (funct3 & 0b100) != 0
            src = rs1 if is_imm else reg[rs1]
            if addr == FFLAGS:
                old = fflags & 0x1F
            elif addr == FRM:
                old = frm & 0x7
            elif addr == FCSR:
                old = ((frm & 0x7) << 5) | (fflags & 0x1F)
            else:
                old = 0
            if rd:
                reg[rd] = u32(old); int_written.add(rd)
            op = funct3 & 0b11
            if op == 0b01:
                newv = src
            elif op == 0b10:
                newv = old | src
            else:
                newv = old & (~src)
            do_write = (op == 0b01) or (src != 0)
            if do_write:
                if addr == FFLAGS:
                    fflags = newv & 0x1F
                elif addr == FRM:
                    frm = newv & 0x7
                elif addr == FCSR:
                    frm = (newv >> 5) & 0x7; fflags = newv & 0x1F
        elif opcode == 0b1010011:                          # FP-OP
            dbl = (fmt == 0b01)
            if funct7 == 0b1111000:                        # fmv.w.x
                freg[rd] = NANBOX | u32(reg[rs1]); fp_written.add(rd); continue
            av, bv = freg[rs1], freg[rs2]
            if not dbl:
                av, bv = unbox_s(av), unbox_s(bv)
            else:
                av, bv = av & ((1 << 64) - 1), bv & ((1 << 64) - 1)
            rm = frm if funct3 == 0b111 else funct3
            if funct5 == 0b00000:
                bits, fl = _do_addsub(av, bv, dbl, rm, False)
            elif funct5 == 0b00001:
                bits, fl = _do_addsub(av, bv, dbl, rm, True)
            else:  # 0b00010 fmul
                bits, fl = _do_mul(av, bv, dbl, rm)
            if not dbl:
                bits = NANBOX | (bits & MASK)
            freg[rd] = bits & ((1 << 64) - 1); fp_written.add(rd)
            fflags |= fl

    return ({i: reg[i] for i in sorted(int_written)},
            {i: freg[i] for i in sorted(fp_written)})


def golden_fcvt(prog):
    """Architectural model for the fcvt program. Returns (int_regs, fp_regs).

    Uses the independent conversion oracles above. Note fcvt.fp.int (funct5 11010) reads the
    INTEGER register file for its operand; fcvt.int.fp (11000) writes an integer register.
    """
    reg = [0] * 32
    freg = [0] * 32
    int_written, fp_written = set(), set()
    mem = {}
    fflags = 0
    frm = 0

    def load(addr, n):
        v = 0
        for k in range(n):
            v |= mem.get(addr + k, 0) << (8 * k)
        return v

    def store(addr, v, n):
        for k in range(n):
            mem[addr + k] = (v >> (8 * k)) & 0xFF

    def unbox_s(x):
        return x & MASK if (x >> 32) & MASK == 0xFFFFFFFF else 0x7FC00000

    for _, word in prog:
        opcode = word & 0x7F
        rd = (word >> 7) & 0x1F
        rs1 = (word >> 15) & 0x1F
        rs2 = (word >> 20) & 0x1F
        funct3 = (word >> 12) & 0x7
        funct7 = (word >> 25) & 0x7F
        funct5 = (word >> 27) & 0x1F
        fmt = (word >> 25) & 0x3
        imm_i = s32(sext12(word >> 20))
        imm_s = s32(sext12((((word >> 25) & 0x7F) << 5) | ((word >> 7) & 0x1F)))

        if opcode == 0b0010011 and funct3 == 0:            # addi
            if rd:
                reg[rd] = u32(reg[rs1] + imm_i); int_written.add(rd)
        elif opcode == 0b0110111:                          # lui
            if rd:
                reg[rd] = u32(((word >> 12) & 0xFFFFF) << 12); int_written.add(rd)
        elif opcode == 0b0100011:                          # integer store
            store(u32(reg[rs1] + imm_s), reg[rs2], {0: 1, 1: 2, 2: 4}[funct3])
        elif opcode == 0b0000111:                          # FP load
            addr = u32(reg[rs1] + imm_i)
            freg[rd] = load(addr, 8) if funct3 == 0b011 else (NANBOX | load(addr, 4))
            fp_written.add(rd)
        elif opcode == 0b0100111:                          # FP store
            addr = u32(reg[rs1] + imm_s)
            store(addr, freg[rs2] & ((1 << 64) - 1), 8) if funct3 == 0b011 else store(addr, freg[rs2] & MASK, 4)
        elif opcode == 0b1110011 and funct3 != 0:          # CSR
            addr = (word >> 20) & 0xFFF
            is_imm = (funct3 & 0b100) != 0
            src = rs1 if is_imm else reg[rs1]
            if addr == FFLAGS:
                old = fflags & 0x1F
            elif addr == FRM:
                old = frm & 0x7
            elif addr == FCSR:
                old = ((frm & 0x7) << 5) | (fflags & 0x1F)
            else:
                old = 0
            if rd:
                reg[rd] = u32(old); int_written.add(rd)
            op = funct3 & 0b11
            if op == 0b01:
                newv = src
            elif op == 0b10:
                newv = old | src
            else:
                newv = old & (~src)
            do_write = (op == 0b01) or (src != 0)
            if do_write:
                if addr == FFLAGS:
                    fflags = newv & 0x1F
                elif addr == FRM:
                    frm = newv & 0x7
                elif addr == FCSR:
                    frm = (newv >> 5) & 0x7; fflags = newv & 0x1F
        elif opcode == 0b1010011:                          # FP-OP (conversions)
            dbl = (fmt == 0b01)
            rm = frm if funct3 == 0b111 else funct3
            signed_conv = (rs2 & 1) == 0
            if funct7 == 0b1111000:                        # fmv.w.x (build single operands)
                freg[rd] = NANBOX | u32(reg[rs1]); fp_written.add(rd); continue
            if funct5 == 0b11010:                          # int -> float (reads integer rs1)
                bits, fl = _do_i2f(reg[rs1], dbl, signed_conv, rm)
                freg[rd] = bits; fp_written.add(rd); fflags |= fl
            elif funct5 == 0b11000:                        # float -> int (writes integer rd)
                av = unbox_s(freg[rs1]) if not dbl else (freg[rs1] & ((1 << 64) - 1))
                res, fl = _do_f2i(av, dbl, signed_conv, rm)
                if rd:
                    reg[rd] = u32(res); int_written.add(rd)
                fflags |= fl
            elif funct5 == 0b01000:                        # float -> float
                src_dbl = not dbl
                av = (freg[rs1] & ((1 << 64) - 1)) if src_dbl else unbox_s(freg[rs1])
                bits, fl = _do_f2f(av, dbl, rm)
                freg[rd] = bits; fp_written.add(rd); fflags |= fl

    return ({i: reg[i] for i in sorted(int_written)},
            {i: freg[i] for i in sorted(fp_written)})


def golden_fdivsqrt(prog):
    """Architectural model for the fdiv/fsqrt program. Returns (int_regs, fp_regs).

    Uses the independent references _do_div/_do_sqrt (exact Fraction division, exact integer-sqrt
    rounding). Models fflags accrual and the csrrci/csrrs isolation reads. Single results boxed.
    """
    reg = [0] * 32
    freg = [0] * 32
    int_written, fp_written = set(), set()
    mem = {}
    fflags = 0
    frm = 0

    def load(addr, n):
        v = 0
        for k in range(n):
            v |= mem.get(addr + k, 0) << (8 * k)
        return v

    def store(addr, v, n):
        for k in range(n):
            mem[addr + k] = (v >> (8 * k)) & 0xFF

    def unbox_s(x):
        return x & MASK if (x >> 32) & MASK == 0xFFFFFFFF else 0x7FC00000

    for _, word in prog:
        opcode = word & 0x7F
        rd = (word >> 7) & 0x1F
        rs1 = (word >> 15) & 0x1F
        rs2 = (word >> 20) & 0x1F
        funct3 = (word >> 12) & 0x7
        funct7 = (word >> 25) & 0x7F
        funct5 = (word >> 27) & 0x1F
        fmt = (word >> 25) & 0x3
        imm_i = s32(sext12(word >> 20))
        imm_s = s32(sext12((((word >> 25) & 0x7F) << 5) | ((word >> 7) & 0x1F)))

        if opcode == 0b0010011 and funct3 == 0:            # addi
            if rd:
                reg[rd] = u32(reg[rs1] + imm_i); int_written.add(rd)
        elif opcode == 0b0110111:                          # lui
            if rd:
                reg[rd] = u32(((word >> 12) & 0xFFFFF) << 12); int_written.add(rd)
        elif opcode == 0b0100011:                          # integer store
            store(u32(reg[rs1] + imm_s), reg[rs2], {0: 1, 1: 2, 2: 4}[funct3])
        elif opcode == 0b0000111:                          # FP load
            addr = u32(reg[rs1] + imm_i)
            freg[rd] = load(addr, 8) if funct3 == 0b011 else (NANBOX | load(addr, 4))
            fp_written.add(rd)
        elif opcode == 0b0100111:                          # FP store
            addr = u32(reg[rs1] + imm_s)
            store(addr, freg[rs2] & ((1 << 64) - 1), 8) if funct3 == 0b011 else store(addr, freg[rs2] & MASK, 4)
        elif opcode == 0b1110011 and funct3 != 0:          # CSR
            addr = (word >> 20) & 0xFFF
            is_imm = (funct3 & 0b100) != 0
            src = rs1 if is_imm else reg[rs1]
            if addr == FFLAGS:
                old = fflags & 0x1F
            elif addr == FRM:
                old = frm & 0x7
            elif addr == FCSR:
                old = ((frm & 0x7) << 5) | (fflags & 0x1F)
            else:
                old = 0
            if rd:
                reg[rd] = u32(old); int_written.add(rd)
            op = funct3 & 0b11
            if op == 0b01:
                newv = src
            elif op == 0b10:
                newv = old | src
            else:
                newv = old & (~src)
            do_write = (op == 0b01) or (src != 0)
            if do_write:
                if addr == FFLAGS:
                    fflags = newv & 0x1F
                elif addr == FRM:
                    frm = newv & 0x7
                elif addr == FCSR:
                    frm = (newv >> 5) & 0x7; fflags = newv & 0x1F
        elif opcode == 0b1010011:                          # FP-OP (fmv.w.x, fdiv, fsqrt)
            dbl = (fmt == 0b01)
            if funct7 == 0b1111000:                        # fmv.w.x (build single operands)
                freg[rd] = NANBOX | u32(reg[rs1]); fp_written.add(rd); continue
            av, bv = freg[rs1], freg[rs2]
            if not dbl:
                av, bv = unbox_s(av), unbox_s(bv)
            else:
                av, bv = av & ((1 << 64) - 1), bv & ((1 << 64) - 1)
            rm = frm if funct3 == 0b111 else funct3
            if funct5 == 0b00011:                          # fdiv
                bits, fl = _do_div(av, bv, dbl, rm)
            else:                                          # 0b01011 fsqrt
                bits, fl = _do_sqrt(av, dbl, rm)
            if not dbl:
                bits = NANBOX | (bits & MASK)
            freg[rd] = bits & ((1 << 64) - 1); fp_written.add(rd)
            fflags |= fl

    return ({i: reg[i] for i in sorted(int_written)},
            {i: freg[i] for i in sorted(fp_written)})


def golden_fma(prog):
    """Architectural model for the fused multiply-add program. Returns (int_regs, fp_regs).

    Uses the independent reference _do_fma (exact rational product+sum, single rounding). Models
    fflags accrual and the csrrci/csrrs isolation reads. Single results NaN-boxed.
    """
    reg = [0] * 32
    freg = [0] * 32
    int_written, fp_written = set(), set()
    mem = {}
    fflags = 0
    frm = 0

    def load(addr, n):
        v = 0
        for k in range(n):
            v |= mem.get(addr + k, 0) << (8 * k)
        return v

    def store(addr, v, n):
        for k in range(n):
            mem[addr + k] = (v >> (8 * k)) & 0xFF

    def unbox_s(x):
        return x & MASK if (x >> 32) & MASK == 0xFFFFFFFF else 0x7FC00000

    for _, word in prog:
        opcode = word & 0x7F
        rd = (word >> 7) & 0x1F
        rs1 = (word >> 15) & 0x1F
        rs2 = (word >> 20) & 0x1F
        rs3 = (word >> 27) & 0x1F
        funct3 = (word >> 12) & 0x7
        funct7 = (word >> 25) & 0x7F
        fmt = (word >> 25) & 0x3
        imm_i = s32(sext12(word >> 20))
        imm_s = s32(sext12((((word >> 25) & 0x7F) << 5) | ((word >> 7) & 0x1F)))

        if opcode == 0b0010011 and funct3 == 0:            # addi
            if rd:
                reg[rd] = u32(reg[rs1] + imm_i); int_written.add(rd)
        elif opcode == 0b0110111:                          # lui
            if rd:
                reg[rd] = u32(((word >> 12) & 0xFFFFF) << 12); int_written.add(rd)
        elif opcode == 0b0100011:                          # integer store
            store(u32(reg[rs1] + imm_s), reg[rs2], {0: 1, 1: 2, 2: 4}[funct3])
        elif opcode == 0b0000111:                          # FP load
            addr = u32(reg[rs1] + imm_i)
            freg[rd] = load(addr, 8) if funct3 == 0b011 else (NANBOX | load(addr, 4))
            fp_written.add(rd)
        elif opcode == 0b1110011 and funct3 != 0:          # CSR
            addr = (word >> 20) & 0xFFF
            is_imm = (funct3 & 0b100) != 0
            src = rs1 if is_imm else reg[rs1]
            if addr == FFLAGS:
                old = fflags & 0x1F
            elif addr == FRM:
                old = frm & 0x7
            elif addr == FCSR:
                old = ((frm & 0x7) << 5) | (fflags & 0x1F)
            else:
                old = 0
            if rd:
                reg[rd] = u32(old); int_written.add(rd)
            csop = funct3 & 0b11
            if csop == 0b01:
                newv = src
            elif csop == 0b10:
                newv = old | src
            else:
                newv = old & (~src)
            if (csop == 0b01) or (src != 0):
                if addr == FFLAGS:
                    fflags = newv & 0x1F
                elif addr == FRM:
                    frm = newv & 0x7
                elif addr == FCSR:
                    frm = (newv >> 5) & 0x7; fflags = newv & 0x1F
        elif opcode == 0b1010011 and funct7 == 0b1111000:  # fmv.w.x (build single operands)
            freg[rd] = NANBOX | u32(reg[rs1]); fp_written.add(rd)
        elif (opcode >> 4) == 0b100 and (opcode & 0b11) == 0b11:   # FMA family
            op = (opcode >> 2) & 0b11
            dbl = (fmt == 0b01)
            av, bv, cv = freg[rs1], freg[rs2], freg[rs3]
            if not dbl:
                av, bv, cv = unbox_s(av), unbox_s(bv), unbox_s(cv)
            else:
                av, bv, cv = av & ((1 << 64) - 1), bv & ((1 << 64) - 1), cv & ((1 << 64) - 1)
            rm = frm if funct3 == 0b111 else funct3
            bits, fl = _do_fma(av, bv, cv, dbl, op, rm)
            if not dbl:
                bits = NANBOX | (bits & MASK)
            freg[rd] = bits & ((1 << 64) - 1); fp_written.add(rd)
            fflags |= fl

    return ({i: reg[i] for i in sorted(int_written)},
            {i: freg[i] for i in sorted(fp_written)})


def check_fp(prog, vcd_path, golden_fn=golden_fp):
    """Parse both the integer and FP register-file writeback streams and diff vs golden_fn."""
    with open(vcd_path) as f:
        lines = f.readlines()

    # symbol -> (domain, field). domain in {"int","fp","top"}.
    sym_map = {}
    scope = []
    for ln in lines:
        t = ln.split()
        if not t:
            continue
        if t[0] == "$scope":
            scope.append(t[2])
        elif t[0] == "$upscope":
            if scope:
                scope.pop()
        elif t[0] == "$var":
            sym = t[3]
            name = t[4].split("[")[0]
            # Classify by the innermost (register-file instance) scope only -- the testbench name
            # itself may contain "fp" and would otherwise pollute a full-path match.
            inner = scope[-1].lower() if scope else ""
            in_fp = ("fp" in inner and "reg_file" in inner)
            in_int = ("reg_file" in inner and "fp" not in inner)
            if name in ("clk", "reset"):
                sym_map.setdefault(sym, ("top", name))
            elif in_fp and name in ("fp_write", "write_reg", "write_data"):
                sym_map[sym] = ("fp", name)
            elif in_int and name in ("reg_write", "write_reg", "write_data"):
                sym_map[sym] = ("int", name)
        elif t[0] == "$enddefinitions":
            break

    def have(domain, field):
        return any(d == domain and f == field for d, f in sym_map.values())

    need = [("top", "clk"), ("top", "reset"),
            ("int", "reg_write"), ("int", "write_reg"), ("int", "write_data"),
            ("fp", "fp_write"), ("fp", "write_reg"), ("fp", "write_data")]
    missing = [(d, f) for d, f in need if not have(d, f)]
    if missing:
        print("VCD parse error: missing", missing)
        print("found:", sorted(set(sym_map.values())))
        sys.exit(2)

    cur = {k: "x" for k in need}

    def bits_to_int(b):
        b = b.replace("x", "0").replace("z", "0").replace("u", "0").replace("U", "0")
        try:
            return int(b, 2)
        except ValueError:
            return 0

    int_commit, fp_commit = {}, {}
    prev_clk = "x"
    for ln in lines:
        ln = ln.strip()
        if not ln:
            continue
        if ln[0] == "b":
            parts = ln.split()
            if len(parts) == 2 and parts[1] in sym_map:
                cur[sym_map[parts[1]]] = bits_to_int(parts[0][1:])
        elif ln[0] in "01xzUuZ" and len(ln) >= 2 and ln[1:] in sym_map:
            cur[sym_map[ln[1:]]] = ln[0]
        else:
            continue
        clk = cur[("top", "clk")]
        if prev_clk == "0" and clk == "1":
            if cur[("top", "reset")] == "0":
                if cur[("int", "reg_write")] == "1":
                    rd = cur[("int", "write_reg")] if isinstance(cur[("int", "write_reg")], int) else 0
                    if rd != 0:
                        d = cur[("int", "write_data")]
                        int_commit[rd] = (d if isinstance(d, int) else 0) & MASK
                if cur[("fp", "fp_write")] == "1":
                    frd = cur[("fp", "write_reg")] if isinstance(cur[("fp", "write_reg")], int) else 0
                    d = cur[("fp", "write_data")]
                    fp_commit[frd] = (d if isinstance(d, int) else 0) & ((1 << 64) - 1)
        prev_clk = clk

    exp_int, exp_fp = golden_fn(prog)
    ok = True
    print("== integer writebacks ==")
    print("reg | expected  | got       | result")
    for r in sorted(exp_int):
        got = int_commit.get(r)
        gs = f"0x{got:08x}" if got is not None else "   --   "
        status = "PASS" if got == exp_int[r] else "FAIL"
        ok = ok and got == exp_int[r]
        print(f"x{r:<2} | 0x{exp_int[r]:08x} | {gs} | {status}")
    print("== FP writebacks ==")
    print("freg | expected          | got               | result")
    for r in sorted(exp_fp):
        got = fp_commit.get(r)
        gs = f"0x{got:016x}" if got is not None else "        --        "
        status = "PASS" if got == exp_fp[r] else "FAIL"
        ok = ok and got == exp_fp[r]
        print(f"f{r:<3} | 0x{exp_fp[r]:016x} | {gs} | {status}")
    print("\nRESULT:", "ALL PASS" if ok else "FAILURES DETECTED")
    sys.exit(0 if ok else 1)


# ---------------------------------------------------------------------------
# VHDL emission
# ---------------------------------------------------------------------------
def emit(prog):
    for idx, (asm, word) in enumerate(prog):
        print(f'        {idx:<3}=> x"{word & MASK:08x}", -- {asm}')
    print("    -- golden (last committed value per register):")
    for r, v in sorted(golden(prog).items()):
        print(f"    --   x{r} = 0x{v:08x} ({s32(v)})")


# ---------------------------------------------------------------------------
# VCD writeback-stream parser + check
# ---------------------------------------------------------------------------
def check(prog, vcd_path):
    with open(vcd_path) as f:
        lines = f.readlines()

    # Map signal identifiers within the reg_file_inst scope.
    ids = {}            # symbol -> logical name
    widths = {}
    scope = []
    want = {"reg_write", "write_reg", "write_data", "clk", "reset"}
    for ln in lines:
        t = ln.split()
        if not t:
            continue
        if t[0] == "$scope":
            scope.append(t[2])
        elif t[0] == "$upscope":
            if scope:
                scope.pop()
        elif t[0] == "$var":
            width = int(t[2])
            sym = t[3]
            name = t[4].split("[")[0]  # strip vector suffix, e.g. write_data[31:0]
            # Integer reg file = innermost scope contains "reg_file" but not "fp" (the FP
            # register file shares write_reg/write_data names and must not be captured here).
            inner = scope[-1].lower() if scope else ""
            in_rf = ("reg_file" in inner and "fp" not in inner)
            if name in want and (in_rf or name in ("clk", "reset")):
                # Prefer reg-file-scoped copies for the writeback ports
                key = name
                if name in ("reg_write", "write_reg", "write_data") and not in_rf:
                    continue
                ids[sym] = key
                widths[sym] = width
        elif t[0] == "$enddefinitions":
            break

    # Reverse: logical name -> symbol
    sym_of = {v: k for k, v in ids.items()}
    needed = ("clk", "reset", "reg_write", "write_reg", "write_data")
    missing = [n for n in needed if n not in sym_of]
    if missing:
        print(f"VCD parse error: missing signals {missing}")
        print(f"found: {sorted(set(ids.values()))}")
        sys.exit(2)

    cur = {n: "x" for n in needed}
    committed = {}
    prev_clk = "x"

    def bits_to_int(b):
        b = b.replace("x", "0").replace("z", "0").replace("u", "0").replace("U", "0")
        try:
            return int(b, 2)
        except ValueError:
            return 0

    for ln in lines:
        ln = ln.strip()
        if not ln:
            continue
        if ln[0] == "b":
            parts = ln.split()
            if len(parts) == 2 and parts[1] in ids:
                cur[ids[parts[1]]] = bits_to_int(parts[0][1:])
        elif ln[0] in "01xzUuZ" and len(ln) >= 2 and ln[1:] in ids:
            cur[ids[ln[1:]]] = ln[0]
        else:
            continue
        # On rising edge of clk with reset low and reg_write high, commit.
        clk = cur["clk"]
        if prev_clk in ("0",) and clk == "1":
            if cur["reset"] == "0" and cur["reg_write"] == "1":
                rd = cur["write_reg"] if isinstance(cur["write_reg"], int) else 0
                data = cur["write_data"] if isinstance(cur["write_data"], int) else 0
                if rd != 0:
                    committed[rd] = data & MASK
        prev_clk = clk

    exp = golden(prog)
    ok = True
    print("reg | expected  | got       | result")
    print("----+-----------+-----------+-------")
    for r in sorted(exp):
        got = committed.get(r)
        gs = f"0x{got:08x}" if got is not None else "   --   "
        status = "PASS" if got == exp[r] else "FAIL"
        if got != exp[r]:
            ok = False
        print(f"x{r:<2} | 0x{exp[r]:08x} | {gs} | {status}")
    # Report any unexpected extra commits
    extra = {r: v for r, v in committed.items() if r not in exp}
    if extra:
        print("unexpected commits:", {f"x{r}": f"0x{v:08x}" for r, v in extra.items()})
    print("\nRESULT:", "ALL PASS" if ok else "FAILURES DETECTED")
    sys.exit(0 if ok else 1)


def emit_fp(prog, golden_fn=golden_fp):
    for idx, (asm, word) in enumerate(prog):
        print(f'        {idx:<3}=> x"{word & MASK:08x}", -- {asm}')
    ints, fps = golden_fn(prog)
    print("    -- golden integer regs:")
    for r, v in sorted(ints.items()):
        print(f"    --   x{r} = 0x{v:08x}")
    print("    -- golden FP regs:")
    for r, v in sorted(fps.items()):
        print(f"    --   f{r} = 0x{v:016x}")


if __name__ == "__main__":
    # Usage: emit <prog> | check <prog> <vcd>     (prog = m | csr | fp | fmisc)
    if len(sys.argv) >= 3 and sys.argv[1] == "emit" and sys.argv[2] == "fp":
        emit_fp(PROG_FP)
    elif len(sys.argv) >= 4 and sys.argv[1] == "check" and sys.argv[2] == "fp":
        check_fp(PROG_FP, sys.argv[3])
    elif len(sys.argv) >= 3 and sys.argv[1] == "emit" and sys.argv[2] == "fmisc":
        emit_fp(PROG_FMISC, golden_fmisc)
    elif len(sys.argv) >= 4 and sys.argv[1] == "check" and sys.argv[2] == "fmisc":
        check_fp(PROG_FMISC, sys.argv[3], golden_fmisc)
    elif len(sys.argv) >= 3 and sys.argv[1] == "emit" and sys.argv[2] == "farith":
        emit_fp(PROG_FARITH, golden_farith)
    elif len(sys.argv) >= 4 and sys.argv[1] == "check" and sys.argv[2] == "farith":
        check_fp(PROG_FARITH, sys.argv[3], golden_farith)
    elif len(sys.argv) >= 3 and sys.argv[1] == "emit" and sys.argv[2] == "fcvt":
        emit_fp(PROG_FCVT, golden_fcvt)
    elif len(sys.argv) >= 4 and sys.argv[1] == "check" and sys.argv[2] == "fcvt":
        check_fp(PROG_FCVT, sys.argv[3], golden_fcvt)
    elif len(sys.argv) >= 3 and sys.argv[1] == "emit" and sys.argv[2] == "fdivsqrt":
        emit_fp(PROG_FDIVSQRT, golden_fdivsqrt)
    elif len(sys.argv) >= 4 and sys.argv[1] == "check" and sys.argv[2] == "fdivsqrt":
        check_fp(PROG_FDIVSQRT, sys.argv[3], golden_fdivsqrt)
    elif len(sys.argv) >= 3 and sys.argv[1] == "emit" and sys.argv[2] == "fma":
        emit_fp(PROG_FMA, golden_fma)
    elif len(sys.argv) >= 4 and sys.argv[1] == "check" and sys.argv[2] == "fma":
        check_fp(PROG_FMA, sys.argv[3], golden_fma)
    elif len(sys.argv) >= 3 and sys.argv[1] == "emit" and sys.argv[2] in PROGRAMS:
        emit(PROGRAMS[sys.argv[2]])
    elif len(sys.argv) >= 4 and sys.argv[1] == "check" and sys.argv[2] in PROGRAMS:
        check(PROGRAMS[sys.argv[2]], sys.argv[3])
    else:
        print(__doc__)
        print("programs:", ", ".join(PROGRAMS))
        sys.exit(1)
