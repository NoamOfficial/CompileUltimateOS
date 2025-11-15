; ------------------------------
; NATA Read/Write/Pipeline Interface
; AH = 0 -> Write
; AH = 1 -> Read
; Otherwise -> continuous pipeline
; ------------------------------

section .data
MMIO_BASE       dd 0xFEC00000       ; chipset MMIO base
ROUTER_BUF_PTR  dd 0                 ; buffer pointer
DATA_SIZE       dd 0                 ; number of bytes (multiple of 4)

section .text
global nata_interface
nata_interface:

    cmp ah, 0
    je .write_mode
    cmp ah, 1
    je .read_mode
    jmp .pipeline_mode

; --------------------------
; WRITE MODE (AH=0)
; --------------------------
.write_mode:
    mov ebx, MMIO_BASE
    add ebx, 0x10          ; TX register offset
    mov esi, ROUTER_BUF_PTR
    mov ecx, DATA_SIZE
    shr ecx, 2             ; bytes -> dwords

.write_loop:
    cmp ecx, 0
    je .write_done
    mov eax, [esi]
    mov [ebx], eax
    add esi, 4
    dec ecx
    jmp .write_loop

.write_done:
    ; Fire command trigger
    mov al, [MMIO_BASE + 0x3]
    or al, 1 << 7
    mov [MMIO_BASE + 0x3], al
    ret

; --------------------------
; READ MODE (AH=1)
; --------------------------
.read_mode:
    mov ebx, MMIO_BASE
    add ebx, 0x20          ; RX register offset
    mov edi, ROUTER_BUF_PTR
    mov ecx, DATA_SIZE
    shr ecx, 2             ; bytes -> dwords

.read_loop:
    cmp ecx, 0
    je .read_done
    mov eax, [ebx]
    mov [edi], eax
    add edi, 4
    dec ecx
    jmp .read_loop

.read_done:
    ret

; --------------------------
; CONTINUOUS PIPELINE (AH != 0/1)
; --------------------------
.pipeline_mode:
    mov ebx, MMIO_BASE
    add ebx, 0x10          ; TX offset
    mov esi, ROUTER_BUF_PTR
    mov edi, ROUTER_BUF_PTR
    add edi, DATA_SIZE     ; RX buffer offset for demo
    mov ecx, DATA_SIZE
    shr ecx, 2

.pipeline_loop:
    cmp ecx, 0
    je .pipeline_done

    ; --- TX ---
    mov eax, [esi]
    mov [ebx], eax
    add esi, 4

    ; --- RX ---
    mov eax, [ebx + 0x10] ; RX offset
    mov [edi], eax
    add edi, 4

    dec ecx
    jmp .pipeline_loop

.pipeline_done:
    ; Fire command trigger
    mov al, [MMIO_BASE + 0x3]
    or al, 1 << 7
    mov [MMIO_BASE + 0x3], al
    ret
