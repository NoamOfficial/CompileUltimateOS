; =====================================================
; NATA DRIVER - Noam ATA
; Multi-Sector, Chipset-Aware, 32MB Buffer
; 32-bit Sector Numbers
; =====================================================

section .bss
align 4096
NATA_BUFFER:
    resb 33554432   ; 32MB buffer for multi-sector transfers

section .text
global NATA_INIT
global NATA_MULTI_WRITE
global NATA_MULTI_READ
global SET_SECTOR_NUM_32
global SET_SECTOR_COUNT
global NATA_STATUS
global FIND_CHIPSET_BASE
global CHIPSET_INIT

; -----------------------------------------------------
; Constants / Ports
; -----------------------------------------------------
NATA_DATA_PORT      equ 0x02
NATA_CTRL_PORT      equ 0x03
NATA_STATUS_PORT    equ 0x04
NATA_SECTOR_PORT    equ 0x05
NATA_SECTOR_COUNT   equ 0x06

; -----------------------------------------------------
; Find chipset base dynamically
; Returns: AX = MMIO base (not used in I/O)
; -----------------------------------------------------
FIND_CHIPSET_BASE:
    mov dx, 0x40
    in al, dx
    mov ah, al
    in al, dx
    shl ax, 8
    or ax, ah
    ret

; -----------------------------------------------------
; Initialize chipset routing for NATA
; -----------------------------------------------------
CHIPSET_INIT:
    call FIND_CHIPSET_BASE

    ; Enable NATA line
    mov dx, 0x41
    mov al, 0x01
    out dx, al

    ; Map RN03 to storage controller
    mov dx, 0x42
    mov al, 0x03
    out dx, al

    ret

; -----------------------------------------------------
; Initialize NATA Controller
; -----------------------------------------------------
NATA_INIT:
    call CHIPSET_INIT

    ; Enable NATA controller (bit7)
    mov dx, NATA_CTRL_PORT
    mov al, 0x80
    out dx, al
    ret

; -----------------------------------------------------
; Set 32-bit sector number
; EAX = sector number
; -----------------------------------------------------
SET_SECTOR_NUM_32:
    mov dx, NATA_SECTOR_PORT

    out dx, al        ; bits 0-7
    shr eax, 8
    out dx, al        ; bits 8-15
    shr eax, 8
    out dx, al        ; bits 16-23
    shr eax, 8
    out dx, al        ; bits 24-31

    ret

; -----------------------------------------------------
; Set sector count
; AL = number of sectors
; -----------------------------------------------------
SET_SECTOR_COUNT:
    mov dx, NATA_SECTOR_COUNT
    out dx, al
    ret

; -----------------------------------------------------
; Check NATA status
; AL = 0 ready, 1 busy
; -----------------------------------------------------
NATA_STATUS:
    in al, NATA_STATUS_PORT
    and al, 0x01
    ret

; -----------------------------------------------------
; Multi-Sector Write
; AH=0 → write
; ECX = total bytes to write
; Uses 32MB buffer
; -----------------------------------------------------
NATA_MULTI_WRITE:
    mov esi, NATA_BUFFER   ; source buffer
.WRITE_LOOP:
    cmp ecx, 0
    je .DONE_WRITE
    in al, NATA_STATUS_PORT
    and al, 0x01
    cmp al, 0
    jne .WRITE_LOOP       ; wait until ready
    mov al, [esi]
    out NATA_DATA_PORT, al
    inc esi
    dec ecx
    jmp .WRITE_LOOP
.DONE_WRITE:
    ret

; -----------------------------------------------------
; Multi-Sector Read
; AH=1 → read
; ECX = total bytes to read
; Uses 32MB buffer
; -----------------------------------------------------
NATA_MULTI_READ:
    mov edi, NATA_BUFFER   ; destination buffer
.READ_LOOP:
    cmp ecx, 0
    je .DONE_READ
    in al, NATA_STATUS_PORT
    and al, 0x01
    cmp al, 0
    jne .READ_LOOP        ; wait until ready
    in al, NATA_DATA_PORT
    mov [edi], al
    inc edi
    dec ecx
    jmp .READ_LOOP
.DONE_READ:
    ret

