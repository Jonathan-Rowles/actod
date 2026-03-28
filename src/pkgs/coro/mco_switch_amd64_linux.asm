bits 64

global mco_wrap_main
global mco_switch

section .note.GNU-stack
section .text

; Trampoline: called on first resume to enter _mco_main(co)
; r13 = coroutine pointer (1st arg via rdi)
; r12 = _mco_main function pointer
mco_wrap_main:
    mov rdi, r13
    jmp r12

; Context switch: save callee-saved regs to `from`, restore from `to`, jump
; rdi = from (_mco_ctxbuf*)
; rsi = to   (_mco_ctxbuf*)
;
; Ctx_Buf layout (8 fields, 64 bytes):
;   0x00  rip
;   0x08  rsp
;   0x10  rbp
;   0x18  rbx
;   0x20  r12
;   0x28  r13
;   0x30  r14
;   0x38  r15
mco_switch:
    ; Save resume address — when we restore this context, we jump to .resume
    lea rax, [rel .resume]
    mov [rdi + 0x00], rax       ; rip
    mov [rdi + 0x08], rsp
    mov [rdi + 0x10], rbp
    mov [rdi + 0x18], rbx
    mov [rdi + 0x20], r12
    mov [rdi + 0x28], r13
    mov [rdi + 0x30], r14
    mov [rdi + 0x38], r15
    ; Restore from `to`
    mov r15, [rsi + 0x38]
    mov r14, [rsi + 0x30]
    mov r13, [rsi + 0x28]
    mov r12, [rsi + 0x20]
    mov rbx, [rsi + 0x18]
    mov rbp, [rsi + 0x10]
    mov rsp, [rsi + 0x08]
    jmp [rsi + 0x00]
.resume:
    ret
