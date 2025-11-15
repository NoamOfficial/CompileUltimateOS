; ------------------------------
; Initialize SATA Routing Interface
; MMIO_BASE  - base of controller MMIO
; ------------------------------

section .data
MMIO_BASE       dd 0xFEC00000        ; example MMIO base
INIT_CTRL       db 0                  ; control byte

section .bss
; 32MB reserved buffer
ROUTER_BUF      resb 32*1024*1024

section .text
global init_sata_router
init_sata_router:

    ; --------------------------
    ; Step 1: Prepare control byte
    ; --------------------------
    mov al, 0
    or al, 1 << 0      ; EXTERNAL_BUFFER_ENABLE
    or al, 1 << 1      ; AHCI_BYPASS
    or al, 1 << 2      ; TX_ENABLE
    or al, 1 << 3      ; RX_ENABLE
    or al, 1 << 4      ; ROUTE_EXTERNAL
    or al, 1 << 6      ; PHY_RESET
    mov [INIT_CTRL], al

    ; --------------------------
    ; Step 2: Write control byte to 0x3
    ; --------------------------
    mov ebx, MMIO_BASE
    add ebx, 0x3
    mov al, [INIT_CTRL]
    mov [ebx], al

    ; --------------------------
    ; Step 3: Pulse PHY_RESET (bit6)
    ; --------------------------
    mov al, [INIT_CTRL]
    and al, ~(1 << 6)      ; clear PHY_RESET
    mov [ebx], al

    ; --------------------------
    ; Step 4: Trigger COMMAND (bit7)
    ; --------------------------
    mov al, [INIT_CTRL]
    or al, 1 << 7           ; COMMAND_TRIGGER
    mov [ebx], al

    ret
