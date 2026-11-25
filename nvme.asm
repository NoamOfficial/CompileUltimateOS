; ============================================================================
; nvme.asm - Minimal polling NVMe driver, x86-64 long mode, NASM
; ----------------------------------------------------------------------------
; Public API (System V style arguments, return value in eax/rax):
;
;   nvme_init            -> eax = number of NVMe drives found (scans PCI,
;                           brings up every controller, creates I/O queues,
;                           identifies namespace 1). Selects disk 0 if any.
;   nvme_disk_count      -> eax = number of detected drives
;   nvme_select_disk     edi = disk index           -> eax = 0 ok, -1 bad index
;   nvme_get_disk_info   edi = disk index           -> rax = ptr to DISK struct
;                                                      (0 if bad index)
;   nvme_read   rdi = start LBA, rsi = sector count, rdx = dest buffer
;   nvme_write  rdi = start LBA, rsi = sector count, rdx = source buffer
;   nvme_flush                                      (flush volatile write cache)
;        read/write/flush -> eax = 0 ok, else NVMe status (bits 14:0 of
;        status field), 0xFFFFFFFF = timeout, 0xFFFFFFFE = no disk selected
;
; Assumptions (adapt to your kernel):
;   * Long mode, virtual address == physical address for the driver's .bss,
;     for caller buffers, and for the controller BAR0 (identity map).
;   * BAR0 region is mapped UNCACHED (PCD/PWT or UC MTRR/PAT).
;   * BAR0 was already assigned an address by firmware (BIOS/UEFI).
;   * Caller buffers are dword (4-byte) aligned, and physically contiguous
;     per page (guaranteed under identity mapping).
;   * Single CPU, no reentrancy (one shared command scratch buffer),
;     polling only (no interrupts, INTx disabled, controller INTMS masked).
;   * Each controller = one "disk", using namespace ID 1.
;   * Logical block size 512..4096 bytes (read from Identify Namespace).
;
; Assemble:  nasm -f elf64 nvme.asm -o nvme.o   (or -f bin / %include it)
; ============================================================================

bits 64
default rel

global nvme_init, nvme_disk_count, nvme_select_disk, nvme_get_disk_info
global nvme_read, nvme_write, nvme_flush

; ---------------------------------------------------------------- constants
MAX_DISKS       equ 4
QDEPTH          equ 64              ; entries per queue (SQ and CQ)

; controller registers (offsets from BAR0)
REG_CAP         equ 0x00
REG_INTMS       equ 0x0C
REG_CC          equ 0x14
REG_CSTS        equ 0x1C
REG_AQA         equ 0x24
REG_ASQ         equ 0x28
REG_ACQ         equ 0x30
REG_DOORBELL    equ 0x1000

; per-disk DMA memory layout (each region is one 4 KiB page)
OFF_ASQ         equ 0               ; admin submission queue
OFF_ACQ         equ 4096            ; admin completion queue
OFF_ISQ         equ 8192            ; I/O submission queue  (= ASQ + 8192)
OFF_ICQ         equ 12288           ; I/O completion queue  (= ACQ + 8192)
OFF_IDB         equ 16384           ; identify data buffer
OFF_PRPL        equ 20480           ; PRP list page
DISK_MEM_SIZE   equ 24576

; transfer cap per command when MDTS is 0 or large (bytes)
XFER_CAP        equ 0x20000         ; 128 KiB -> at most 33 PRP entries

; NVMe opcodes
ADM_CREATE_SQ   equ 0x01
ADM_CREATE_CQ   equ 0x05
ADM_IDENTIFY    equ 0x06
IO_FLUSH        equ 0x00
IO_WRITE        equ 0x01
IO_READ         equ 0x02

; ---------------------------------------------------------- disk descriptor
struc DISK
    .bar        resq 1              ; controller BAR0 base
    .mem        resq 1              ; base of this disk's DMA memory
    .stride     resq 1              ; doorbell stride in bytes
    .nlba       resq 1              ; namespace size in logical blocks
    .max_bytes  resq 1              ; max bytes per command
    .to         resd 1              ; CAP.TO (500 ms units)
    .cid        resd 1              ; last command id
    .lba_shift  resd 1              ; log2(logical block size)
    .nsid       resd 1
    .present    resd 1
    .pci        resd 1              ; PCI config address (bus/dev/func)
    .sq_tail    resd 2              ; [0]=admin, [1]=I/O
    .cq_head    resd 2
    .cq_phase   resd 2
    .model      resb 41             ; NUL-terminated model string
    alignb 8
endstruc

; ============================================================================
section .text

; ----------------------------------------------------------------------------
; PCI config space access via ports 0xCF8 / 0xCFC
; edi = (bus<<16)|(dev<<11)|(func<<8)|offset
; ----------------------------------------------------------------------------
pci_read32:
    mov eax, edi
    or  eax, 0x80000000
    mov dx, 0xCF8
    out dx, eax
    mov dx, 0xCFC
    in  eax, dx
    ret

; edi = config address, esi = value
pci_write32:
    mov eax, edi
    or  eax, 0x80000000
    mov dx, 0xCF8
    out dx, eax
    mov dx, 0xCFC
    mov eax, esi
    out dx, eax
    ret

; ----------------------------------------------------------------------------
; cmd_clear: zero the 64-byte scratch command. Clobbers rax, rcx, rdi.
; ----------------------------------------------------------------------------
cmd_clear:
    cld
    lea rdi, [cmd_buf]
    xor eax, eax
    mov ecx, 8
    rep stosq
    ret

; ----------------------------------------------------------------------------
; nvme_wait_rdy: rdi = DISK*, esi = expected CSTS.RDY (0/1)
; returns eax = 0 ok, -1 timeout
; ----------------------------------------------------------------------------
nvme_wait_rdy:
    mov rax, [rdi + DISK.bar]
    mov ecx, [rdi + DISK.to]
    inc ecx
    shl rcx, 24                     ; ~ (TO+1) * 500 ms worth of spins
.l:
    mov edx, [rax + REG_CSTS]
    and edx, 1
    cmp edx, esi
    je  .ok
    pause
    dec rcx
    jnz .l
    mov eax, -1
    ret
.ok:
    xor eax, eax
    ret

; ----------------------------------------------------------------------------
; nvme_exec: submit the command in cmd_buf and poll for completion.
;   rdi = DISK*, esi = queue id (0 = admin, 1 = I/O)
; returns eax = 0 ok, NVMe status code, or -1 on timeout
; ----------------------------------------------------------------------------
nvme_exec:
    push rbx
    push r12
    push r13
    push r14
    cld
    mov rbx, rdi
    mov r12d, esi

    ; assign command id (DW0 bits 31:16)
    mov eax, [rbx + DISK.cid]
    inc eax
    and eax, 0xFFFF
    mov [rbx + DISK.cid], eax
    mov [cmd_buf + 2], ax

    ; r13 = SQ base (CQ base = r13 + 4096)
    mov r13, r12
    shl r13, 13
    add r13, [rbx + DISK.mem]

    ; copy command into SQ slot [tail]
    lea rcx, [rbx + DISK.sq_tail]
    mov eax, [rcx + r12*4]
    mov edx, eax
    shl rdx, 6
    add rdx, r13
    lea rsi, [cmd_buf]
    mov rdi, rdx
    mov ecx, 8
    rep movsq

    ; advance tail
    inc eax
    cmp eax, QDEPTH
    jb  .tail_ok
    xor eax, eax
.tail_ok:
    lea rcx, [rbx + DISK.sq_tail]
    mov [rcx + r12*4], eax

    ; ring SQ tail doorbell: bar + 0x1000 + (2*qid)*stride
    mov rdx, [rbx + DISK.stride]
    mov rcx, r12
    shl rcx, 1
    imul rcx, rdx
    add rcx, [rbx + DISK.bar]
    add rcx, REG_DOORBELL
    mov r14, rcx                    ; keep SQ doorbell address
    mfence
    mov [rcx], eax

    ; poll CQ entry at [head] for the phase bit
    lea rcx, [rbx + DISK.cq_head]
    mov eax, [rcx + r12*4]
    mov edx, eax
    shl rdx, 4
    lea rdx, [rdx + r13 + 4096]     ; rdx = CQ entry
    lea rcx, [rbx + DISK.cq_phase]
    mov r8d, [rcx + r12*4]          ; expected phase
    mov r9d, 0x10000000             ; spin budget
.poll:
    mov ecx, [rdx + 12]             ; CQE DW3
    mov r10d, ecx
    shr r10d, 16
    and r10d, 1
    cmp r10d, r8d
    je  .done
    pause
    dec r9d
    jnz .poll
    mov eax, -1
    jmp .exit

.done:
    shr ecx, 17                     ; status field (SCT/SC/M/DNR), 0 = success
    mov r11d, ecx

    ; advance CQ head, flip phase on wrap
    inc eax
    cmp eax, QDEPTH
    jb  .head_ok
    xor eax, eax
    xor r8d, 1
.head_ok:
    lea rcx, [rbx + DISK.cq_head]
    mov [rcx + r12*4], eax
    lea rcx, [rbx + DISK.cq_phase]
    mov [rcx + r12*4], r8d

    ; ring CQ head doorbell
    mov rcx, r14
    add rcx, [rbx + DISK.stride]
    mov [rcx], eax
    mov eax, r11d
.exit:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; nvme_setup_controller: edi = PCI config address (func base, offset 0)
; Initialises the controller and registers it as a disk on success.
; ----------------------------------------------------------------------------
nvme_setup_controller:
    push rbx
    push r12
    push r13
    push r14
    push r15
    cld
    mov r15d, edi

    mov eax, [disk_count]
    cmp eax, MAX_DISKS
    jae .fail

    ; rbx = &disks[count], cleared
    imul rax, rax, DISK_size
    lea rbx, [disks]
    add rbx, rax
    mov rdi, rbx
    xor eax, eax
    mov ecx, DISK_size
    rep stosb
    mov [rbx + DISK.pci], r15d

    ; ---- BAR0 -------------------------------------------------------------
    mov edi, r15d
    or  edi, 0x10
    call pci_read32
    test al, 1                      ; I/O BAR? not valid for NVMe
    jnz .fail
    mov r12d, eax                   ; raw low BAR
    and eax, 0xFFFFFFF0
    mov r13d, eax                   ; r13 = base (low 32)
    mov eax, r12d
    and eax, 6
    cmp eax, 4                      ; 64-bit BAR?
    jne .bar_done
    mov edi, r15d
    or  edi, 0x14
    call pci_read32
    shl rax, 32
    or  r13, rax
.bar_done:
    test r13, r13
    jz  .fail
    mov [rbx + DISK.bar], r13

    ; ---- enable memory space + bus master, disable INTx --------------------
    mov edi, r15d
    or  edi, 0x04
    call pci_read32
    and eax, 0xFFFF                 ; don't write-1-to-clear status bits
    or  eax, 0x0406
    mov esi, eax
    mov edi, r15d
    or  edi, 0x04
    call pci_write32

    ; ---- read CAP ----------------------------------------------------------
    mov r14, [r13 + REG_CAP]
    movzx ecx, r14w                 ; MQES (0-based)
    cmp ecx, QDEPTH - 1
    jb  .fail
    bt  r14, 37                     ; CSS: NVM command set supported
    jnc .fail
    mov rax, r14
    shr rax, 48
    and eax, 0xF                    ; MPSMIN must be 0 (4 KiB pages)
    jnz .fail
    mov rcx, r14
    shr rcx, 32
    and ecx, 0xF                    ; DSTRD
    mov edx, 4
    shl edx, cl
    mov [rbx + DISK.stride], rdx
    mov ecx, r14d
    shr ecx, 24
    and ecx, 0xFF                   ; TO
    mov [rbx + DISK.to], ecx

    ; ---- disable controller -----------------------------------------------
    mov eax, [r13 + REG_CC]
    and eax, ~1
    mov [r13 + REG_CC], eax
    mov rdi, rbx
    xor esi, esi
    call nvme_wait_rdy
    test eax, eax
    jnz .fail

    mov dword [r13 + 0x0C], 0xFFFFFFFF  ; INTMS: mask all vectors

    ; ---- DMA memory for this disk -----------------------------------------
    mov eax, [disk_count]
    imul rax, rax, DISK_MEM_SIZE
    lea rdx, [disk_mem]
    add rax, rdx
    mov [rbx + DISK.mem], rax
    mov rdi, rax
    xor eax, eax
    mov ecx, DISK_MEM_SIZE / 8
    rep stosq

    ; ---- admin queues -------------------------------------------------------
    mov dword [r13 + REG_AQA], ((QDEPTH - 1) << 16) | (QDEPTH - 1)
    mov rax, [rbx + DISK.mem]
    mov [r13 + REG_ASQ], eax
    mov rdx, rax
    shr rdx, 32
    mov [r13 + REG_ASQ + 4], edx
    add rax, OFF_ACQ
    mov [r13 + REG_ACQ], eax
    shr rax, 32
    mov [r13 + REG_ACQ + 4], eax

    ; ---- enable: IOCQES=4 (16B), IOSQES=6 (64B), MPS=0, CSS=0, EN=1 --------
    mov dword [r13 + REG_CC], (4 << 20) | (6 << 16) | 1
    mov rdi, rbx
    mov esi, 1
    call nvme_wait_rdy
    test eax, eax
    jnz .fail

    mov dword [rbx + DISK.cq_phase],     1
    mov dword [rbx + DISK.cq_phase + 4], 1

    ; ---- Identify Controller (CNS=1) --------------------------------------
    call cmd_clear
    mov byte  [cmd_buf], ADM_IDENTIFY
    mov rax, [rbx + DISK.mem]
    add rax, OFF_IDB
    mov [cmd_buf + 24], rax
    mov dword [cmd_buf + 40], 1
    mov rdi, rbx
    xor esi, esi
    call nvme_exec
    test eax, eax
    jnz .fail

    mov rsi, [rbx + DISK.mem]
    add rsi, OFF_IDB
    movzx eax, byte [rsi + 77]      ; MDTS (power of 2 in 4 KiB units)
    mov edx, XFER_CAP
    test eax, eax
    jz  .mdts_done
    cmp eax, 5
    jae .mdts_done
    mov edx, 4096
    mov ecx, eax
    shl edx, cl
.mdts_done:
    mov [rbx + DISK.max_bytes], rdx
    add rsi, 24                     ; model number (40 bytes)
    lea rdi, [rbx + DISK.model]
    mov ecx, 40
    rep movsb
    mov byte [rdi], 0

    ; ---- Identify Namespace 1 (CNS=0) --------------------------------------
    call cmd_clear
    mov byte  [cmd_buf], ADM_IDENTIFY
    mov dword [cmd_buf + 4], 1
    mov rax, [rbx + DISK.mem]
    add rax, OFF_IDB
    mov [cmd_buf + 24], rax
    mov dword [cmd_buf + 40], 0
    mov rdi, rbx
    xor esi, esi
    call nvme_exec
    test eax, eax
    jnz .fail

    mov rsi, [rbx + DISK.mem]
    add rsi, OFF_IDB
    mov rax, [rsi]                  ; NSZE
    test rax, rax
    jz  .fail
    mov [rbx + DISK.nlba], rax
    movzx ecx, byte [rsi + 26]      ; FLBAS
    and ecx, 0x0F
    mov eax, [rsi + 128 + rcx*4]    ; LBAF[n]
    shr eax, 16
    and eax, 0xFF                   ; LBADS
    cmp eax, 9
    jb  .fail
    cmp eax, 12
    ja  .fail
    mov [rbx + DISK.lba_shift], eax
    mov dword [rbx + DISK.nsid], 1

    ; ---- Create I/O Completion Queue (qid 1) ------------------------------
    call cmd_clear
    mov byte [cmd_buf], ADM_CREATE_CQ
    mov rax, [rbx + DISK.mem]
    add rax, OFF_ICQ
    mov [cmd_buf + 24], rax
    mov dword [cmd_buf + 40], ((QDEPTH - 1) << 16) | 1
    mov dword [cmd_buf + 44], 1     ; PC=1, IEN=0 (polled)
    mov rdi, rbx
    xor esi, esi
    call nvme_exec
    test eax, eax
    jnz .fail

    ; ---- Create I/O Submission Queue (qid 1, bound to CQ 1) ---------------
    call cmd_clear
    mov byte [cmd_buf], ADM_CREATE_SQ
    mov rax, [rbx + DISK.mem]
    add rax, OFF_ISQ
    mov [cmd_buf + 24], rax
    mov dword [cmd_buf + 40], ((QDEPTH - 1) << 16) | 1
    mov dword [cmd_buf + 44], (1 << 16) | 1
    mov rdi, rbx
    xor esi, esi
    call nvme_exec
    test eax, eax
    jnz .fail

    ; ---- success -----------------------------------------------------------
    mov dword [rbx + DISK.present], 1
    inc dword [disk_count]
.fail:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; nvme_init: scan PCI for class 01h/08h/02h (NVM Express) and set each up.
; returns eax = number of disks
; ----------------------------------------------------------------------------
nvme_init:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov dword [disk_count], 0
    mov qword [cur_disk], 0

    xor r12d, r12d                  ; bus
.bus:
    xor r13d, r13d                  ; device
.dev:
    xor r14d, r14d                  ; function
.func:
    mov edi, r12d
    shl edi, 16
    mov eax, r13d
    shl eax, 11
    or  edi, eax
    mov eax, r14d
    shl eax, 8
    or  edi, eax
    mov r15d, edi

    call pci_read32                 ; vendor/device
    cmp ax, 0xFFFF
    je  .next
    mov edi, r15d
    or  edi, 0x08
    call pci_read32                 ; class/subclass/prog-if/revision
    shr eax, 8
    cmp eax, 0x010802
    jne .next
    mov edi, r15d
    call nvme_setup_controller
.next:
    inc r14d
    cmp r14d, 8
    jb  .func
    inc r13d
    cmp r13d, 32
    jb  .dev
    inc r12d
    cmp r12d, 256
    jb  .bus

    mov eax, [disk_count]
    test eax, eax
    jz  .out
    xor edi, edi
    call nvme_select_disk           ; default to disk 0
    mov eax, [disk_count]
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
nvme_disk_count:
    mov eax, [disk_count]
    ret

; edi = index -> eax = 0 ok / -1
nvme_select_disk:
    mov edi, edi
    cmp edi, [disk_count]
    jae .bad
    imul rax, rdi, DISK_size
    lea rdx, [disks]
    add rax, rdx
    mov [cur_disk], rax
    xor eax, eax
    ret
.bad:
    mov eax, -1
    ret

; edi = index -> rax = DISK* or 0
nvme_get_disk_info:
    mov edi, edi
    cmp edi, [disk_count]
    jae .bad
    imul rax, rdi, DISK_size
    lea rdx, [disks]
    add rax, rdx
    ret
.bad:
    xor eax, eax
    ret

; ----------------------------------------------------------------------------
; nvme_read / nvme_write: rdi = LBA, rsi = sector count, rdx = buffer
; ----------------------------------------------------------------------------
nvme_read:
    mov ecx, IO_READ
    jmp nvme_rw
nvme_write:
    mov ecx, IO_WRITE
    jmp nvme_rw

nvme_flush:
    push rbx
    mov rbx, [cur_disk]
    test rbx, rbx
    jz  .nodisk
    call cmd_clear
    mov byte [cmd_buf], IO_FLUSH
    mov eax, [rbx + DISK.nsid]
    mov [cmd_buf + 4], eax
    mov rdi, rbx
    mov esi, 1
    call nvme_exec
    pop rbx
    ret
.nodisk:
    mov eax, 0xFFFFFFFE
    pop rbx
    ret

; ecx = opcode. Splits the request into chunks <= max_bytes and builds PRPs.
nvme_rw:
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rbp
    mov rbx, [cur_disk]
    test rbx, rbx
    jz  .nodisk
    mov r12, rdi                    ; current LBA
    mov r13, rsi                    ; sectors remaining
    mov r14, rdx                    ; current buffer
    mov r15d, ecx                   ; opcode
    test r13, r13
    jz  .ok

.chunk:
    ; rbp = sectors in this chunk = min(remaining, max_bytes >> shift)
    mov ecx, [rbx + DISK.lba_shift]
    mov rbp, [rbx + DISK.max_bytes]
    shr rbp, cl
    cmp r13, rbp
    cmovb rbp, r13

    call cmd_clear
    mov [cmd_buf], r15b
    mov eax, [rbx + DISK.nsid]
    mov [cmd_buf + 4], eax
    mov [cmd_buf + 24], r14         ; PRP1

    ; total bytes of this chunk
    mov ecx, [rbx + DISK.lba_shift]
    mov rax, rbp
    shl rax, cl

    mov rdx, r14
    and edx, 0xFFF                  ; offset inside first page
    mov r8d, 4096
    sub r8, rdx                     ; bytes available in first page
    xor r9d, r9d                    ; PRP2 = 0
    cmp rax, r8
    jbe .prp_done
    sub rax, r8                     ; bytes beyond the first page
    mov r10, r14
    and r10, -4096
    add r10, 4096                   ; address of 2nd page
    cmp rax, 4096
    jbe .prp2_direct

    ; more than two pages: build a PRP list
    mov r11, [rbx + DISK.mem]
    add r11, OFF_PRPL
    mov r9, r11                     ; PRP2 -> list
    add rax, 4095
    shr rax, 12                     ; entry count
.fill:
    mov [r11], r10
    add r11, 8
    add r10, 4096
    dec rax
    jnz .fill
    jmp .prp_done
.prp2_direct:
    mov r9, r10
.prp_done:
    mov [cmd_buf + 32], r9          ; PRP2

    mov rax, r12
    mov [cmd_buf + 40], eax         ; SLBA low  (CDW10)
    shr rax, 32
    mov [cmd_buf + 44], eax         ; SLBA high (CDW11)
    lea eax, [rbp - 1]
    mov [cmd_buf + 48], eax         ; NLB, 0-based (CDW12)

    mov rdi, rbx
    mov esi, 1
    call nvme_exec
    test eax, eax
    jnz .out

    ; advance
    add r12, rbp
    sub r13, rbp
    mov ecx, [rbx + DISK.lba_shift]
    mov rax, rbp
    shl rax, cl
    add r14, rax
    test r13, r13
    jnz .chunk
.ok:
    xor eax, eax
    jmp .out
.nodisk:
    mov eax, 0xFFFFFFFE
.out:
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================================
section .bss
alignb 8
disk_count: resd 1
            resd 1
cur_disk:   resq 1
cmd_buf:    resb 64
disks:      resb DISK_size * MAX_DISKS

alignb 4096
disk_mem:   resb DISK_MEM_SIZE * MAX_DISKS

; ============================================================================
; Example usage from your kernel:
;
;     call nvme_init              ; eax = drives found
;     test eax, eax
;     jz   .no_drives
;     mov  edi, 0
;     call nvme_select_disk
;     mov  rdi, 0                 ; LBA 0
;     mov  rsi, 1                 ; 1 sector
;     lea  rdx, [sector_buf]
;     call nvme_read
;
;     mov  edi, 0
;     call nvme_get_disk_info     ; rax -> DISK struct:
;                                 ;   [rax+DISK.nlba]      size in sectors
;                                 ;   [rax+DISK.lba_shift] log2(sector size)
;                                 ;   rax+DISK.model       model string
; ============================================================================
