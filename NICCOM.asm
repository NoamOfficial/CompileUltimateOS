; ==================================================
; UltimateOS COM-Ethernet Driver - Continuous Loop
; AH = 0 -> SEND
; AH = 1 -> RECEIVE
; ==================================================

SECTION .bss
server      resb 15        ; 15-byte receive buffer
client      resb 15        ; 15-byte send buffer
server_idx  resb 1
client_idx  resb 1
client_len  resb 1

SECTION .data
Packet_Data       dq 0      ; 8-byte payload
Packet_Protocol   dd 0      ; 4-byte protocol
Packet_ID         db 0      ; 1-byte ID
Packet_IP         dw 0      ; 2-byte IP

SECTION .text
global _start

COM1_PORT   equ 0x3F8
UART_LSR    equ COM1_PORT+5
THR_EMPTY   equ 0x20
DATA_READY  equ 0x01

; ==================================================
; SetupPacket: decide action based on AH
; ==================================================
SetupPacket:

    cmp ah, 0
    je do_send
    cmp ah, 1
    je do_receive
    jmp SetupPacket           ; invalid AH, loop

; ==================================================
; SEND routine
; ==================================================
do_send:
    mov esi, client
    mov ecx, 15
send_loop:
    mov al, [esi]
wait_thr:
    in ah, UART_LSR
    test ah, THR_EMPTY
    jz wait_thr
    out COM1_PORT, al
    inc esi
    loop send_loop
    jmp SetupPacket           ; loop back

; ==================================================
; RECEIVE routine
; ==================================================
do_receive:
    xor esi, esi              ; index into server
receive_loop:
    in al, COM1_PORT
    test al, DATA_READY
    jz receive_loop
    mov [server + esi], al
    movzx eax, al             ; move byte into EAX for immediate use
    inc esi
    cmp esi, 15
    jl receive_loop

    ; parse server into Packet
    mov edi, Packet_Data
    mov ecx, 8
parse_data_loop:
    mov al, [server]
    mov [edi], al
    inc server
    inc edi
    loop parse_data_loop

    mov edi, Packet_Protocol
    mov ecx, 4
parse_protocol_loop:
    mov al, [server]
    mov [edi], al
    inc server
    inc edi
    loop parse_protocol_loop

    ; ID db
    mov al, [server]
    inc byte [Packet_ID]
    inc server

    ; IP dw
    mov al, [server]        ; low byte
    mov [Packet_IP], al
    inc server
    mov al, [server]        ; high byte
    mov [Packet_IP+1], al

    jmp SetupPacket           ; loop back
