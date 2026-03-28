.text

// Trampoline: called on first resume to enter _mco_main(co)
// x19 = coroutine pointer (1st arg via x0)
// x20 = _mco_main function pointer
// x21 = dummy return address (loaded into lr)
.globl mco_wrap_main
.type mco_wrap_main, @function
mco_wrap_main:
    mov x0, x19
    mov x30, x21
    br x20
.size mco_wrap_main, .-mco_wrap_main

// Context switch: save callee-saved regs to `from` (x0), restore from `to` (x1)
//
// Ctx_Buf layout (22 fields, 176 bytes):
//   0*16:  x19, x20
//   1*16:  x21, x22
//   2*16:  x23, x24
//   3*16:  x25, x26
//   4*16:  x27, x28
//   5*16:  x29, x30
//   6*16:  sp,  lr (entry point)
//   7*16:  d8,  d9
//   8*16:  d10, d11
//   9*16:  d12, d13
//  10*16:  d14, d15
.globl mco_switch
.type mco_switch, @function
mco_switch:
    mov x10, sp
    mov x11, x30
    stp x19, x20, [x0, #(0*16)]
    stp x21, x22, [x0, #(1*16)]
    stp d8,  d9,  [x0, #(7*16)]
    stp x23, x24, [x0, #(2*16)]
    stp d10, d11, [x0, #(8*16)]
    stp x25, x26, [x0, #(3*16)]
    stp d12, d13, [x0, #(9*16)]
    stp x27, x28, [x0, #(4*16)]
    stp d14, d15, [x0, #(10*16)]
    stp x29, x30, [x0, #(5*16)]
    stp x10, x11, [x0, #(6*16)]
    ldp x19, x20, [x1, #(0*16)]
    ldp x21, x22, [x1, #(1*16)]
    ldp d8,  d9,  [x1, #(7*16)]
    ldp x23, x24, [x1, #(2*16)]
    ldp d10, d11, [x1, #(8*16)]
    ldp x25, x26, [x1, #(3*16)]
    ldp d12, d13, [x1, #(9*16)]
    ldp x27, x28, [x1, #(4*16)]
    ldp d14, d15, [x1, #(10*16)]
    ldp x29, x30, [x1, #(5*16)]
    ldp x10, x11, [x1, #(6*16)]
    mov sp, x10
    br x11
.size mco_switch, .-mco_switch

.section .note.GNU-stack,"",%progbits
