bits 64
default rel

global mco_wrap_main
global mco_switch

section .text

; Trampoline: called on first resume to enter mco_main(co)
; r13 = coroutine pointer (1st arg via rcx on Windows x64)
; r12 = mco_main function pointer
mco_wrap_main:
    mov rcx, r13
    jmp r12

; Context switch: save callee-saved regs to `from`, restore from `to`, jump
; rcx = from (Ctx_Buf*)   -- Windows x64 1st arg
; rdx = to   (Ctx_Buf*)   -- Windows x64 2nd arg
;
; Ctx_Buf layout (240 bytes):
;   0x00  rip
;   0x08  rsp
;   0x10  rbp
;   0x18  rbx
;   0x20  rdi
;   0x28  rsi
;   0x30  r12
;   0x38  r13
;   0x40  r14
;   0x48  r15
;   0x50  xmm6   (16 bytes)
;   0x60  xmm7   (16 bytes)
;   0x70  xmm8   (16 bytes)
;   0x80  xmm9   (16 bytes)
;   0x90  xmm10  (16 bytes)
;   0xA0  xmm11  (16 bytes)
;   0xB0  xmm12  (16 bytes)
;   0xC0  xmm13  (16 bytes)
;   0xD0  xmm14  (16 bytes)
;   0xE0  xmm15  (16 bytes)
mco_switch:
    ; Save resume address
    lea rax, [.resume]
    mov [rcx + 0x00], rax       ; rip
    mov [rcx + 0x08], rsp
    mov [rcx + 0x10], rbp
    mov [rcx + 0x18], rbx
    mov [rcx + 0x20], rdi
    mov [rcx + 0x28], rsi
    mov [rcx + 0x30], r12
    mov [rcx + 0x38], r13
    mov [rcx + 0x40], r14
    mov [rcx + 0x48], r15
    movdqu [rcx + 0x50], xmm6
    movdqu [rcx + 0x60], xmm7
    movdqu [rcx + 0x70], xmm8
    movdqu [rcx + 0x80], xmm9
    movdqu [rcx + 0x90], xmm10
    movdqu [rcx + 0xA0], xmm11
    movdqu [rcx + 0xB0], xmm12
    movdqu [rcx + 0xC0], xmm13
    movdqu [rcx + 0xD0], xmm14
    movdqu [rcx + 0xE0], xmm15
    ; Restore from `to`
    movdqu xmm15, [rdx + 0xE0]
    movdqu xmm14, [rdx + 0xD0]
    movdqu xmm13, [rdx + 0xC0]
    movdqu xmm12, [rdx + 0xB0]
    movdqu xmm11, [rdx + 0xA0]
    movdqu xmm10, [rdx + 0x90]
    movdqu xmm9,  [rdx + 0x80]
    movdqu xmm8,  [rdx + 0x70]
    movdqu xmm7,  [rdx + 0x60]
    movdqu xmm6,  [rdx + 0x50]
    mov r15, [rdx + 0x48]
    mov r14, [rdx + 0x40]
    mov r13, [rdx + 0x38]
    mov r12, [rdx + 0x30]
    mov rsi, [rdx + 0x28]
    mov rdi, [rdx + 0x20]
    mov rbx, [rdx + 0x18]
    mov rbp, [rdx + 0x10]
    mov rsp, [rdx + 0x08]
    jmp [rdx + 0x00]
.resume:
    ret
