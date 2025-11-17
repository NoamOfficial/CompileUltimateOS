BITS 32



%define DATA_SELECTOR 0x130

section .data
buffer: resb 65335       ; main buffer
db 0FFh                  ; sentinel byte at end

section .text
global _start

_start:
    ; initialize segment registers
    mov ax, DATA_SELECTOR
    mov ds, ax
    mov es, ax

    ; initialize indexes
    xor esi, esi          ; source index in DS
    xor edi, edi          ; destination index in ES

copy_loop:
    mov al, [ds:esi]
    cmp al, 0FFh
    je copy_loop           ; repeat on sentinel
    cmp al, 8Fh
    je read_message
    cmp al, 9Fh
    je get_service
    cmp al, 02h
    je clear_shared
    cmp al, 0Fh
    je write_message
    inc esi
    jmp copy_loop

; -------------------------------
read_message:
    ; copy byte from DS to ES
    mov al, [ds:esi]
    mov [es:edi], al
    inc esi
    inc edi
    jmp copy_loop

get_service:
    ; read service address table at 0x900, put result in AH
    push esi               ; save current pointer
    push edi
    mov esi, 0x900         ; start of Service Address Table
search_service:
    lodsw                  ; load word from [ds:esi] into AX, esi += 2
    cmp ah, dl             ; optional compare, can adjust
    je copy_service
    add esi, 2
    jmp search_service
copy_service:
    ; AH now contains the high byte of the service address
    ; AX already loaded from lodsw
    pop edi
    pop esi
    jmp copy_loop

clear_shared:
    mov ecx, 65335
    xor eax, eax
    xor edi, edi
clear_loop:
    mov [es:edi], al
    inc edi
    loop clear_loop
    jmp copy_loop

write_message:
    ; write value from stack to buffer at offset 0x400
    mov eax, [esp + 4]      ; 32-bit stack offset
    mov [es:0x400], eax
    jmp copy_loop






