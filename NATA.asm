; =====================================================
; NATA DRIVER - Noam ATA
; Multi-Sector, Chipset-Aware, 32MB Buffer
; 32-bit Sector Numbers
; Unified read/write routine (AH = 0 → write, AH = 1 → read)
; =====================================================

section .bss
align 4096
NATA_BUFFER:
    resb 33554432   ; 32MB buffer for multi-sector transfers

section .text
global NATA_INIT
global NATA_MULTI_IO
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
; Returns: AX = combined 2 bytes
; -----------------------------------------------------
FIND_CHIPSET_BASE:
    mov dx, 0x40       ; port to read chipset info

    in al, dx          ; read first byte
    mov bl, al         ; store first byte in BL

    in al, dx          ; read second byte

    mov ah, al         ; AH = second byte
    mov al, bl         ; AL = first byte

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
; Unified Multi-Sector I/O
; AH = 0 → write, 1 → read
; ECX = total bytes
; Uses 32MB buffer
; -----------------------------------------------------
NATA_MULTI_IO:
    cmp ah, 0
    je .WRITE_PATH
    cmp ah, 1
    je .READ_PATH
    ret              ; if AH not 0 or 1, return

.WRITE_PATH:
    mov esi, NATA_BUFFER
.WRITE_LOOP:
    cmp ecx, 0
    je .DONE
    in al, NATA_STATUS_PORT
    and al, 0x01
    cmp al, 0
    jne .WRITE_LOOP       ; wait until ready
    mov al, [esi]
    out NATA_DATA_PORT, al
    inc esi
    dec ecx
    jmp .WRITE_LOOP

.READ_PATH:
    mov edi, NATA_BUFFER
.READ_LOOP:
    cmp ecx, 0
    je .DONE
    in al, NATA_STATUS_PORT
    and al, 0x01
    cmp al, 0
    jne .READ_LOOP        ; wait until ready
    in al, NATA_DATA_PORT
    mov [edi], al
    inc edi
    dec ecx
    jmp .READ_LOOP

.DONE:
    ret



