SECTION .bss
server      resb 15
client      resb 15
server_idx  resb 1
client_idx  resb 1
client_len  resb 1

SECTION .data
Packet_Data       dq 0
Packet_Protocol   dd 0
Packet_ID         db 0
Packet_IP         dw 0

SECTION .text
global _start

COM1_PORT   equ 0x3F8
UART_LSR    equ COM1_PORT+5
THR_EMPTY   equ 0x20
DATA_READY  equ 0x01

_start:

SetupPacket:
    cmp ah, 0
    je do_send
    cmp ah, 1
    je do_receive
    jmp SetupPacket

do_send:
    mov esi, client
    mov ecx, 15
send_loop:
    mov al, [esi]
wait_thr:
    in al, UART_LSR
    test al, THR_EMPTY
    jz wait_thr
    mov al, [esi]
    out COM1_PORT, al
    inc esi
    loop send_loop
    jmp SetupPacket

do_receive:
    xor esi, esi
receive_loop:
    in al, COM1_PORT
    in dx, UART_LSR
    test dx, DATA_READY
    jz receive_loop
    mov [server + esi], al
    movzx eax, al
    inc esi
    cmp esi, 15
    jl receive_loop

    mov esi, server
    mov edi, Packet_Data
    mov ecx, 8
parse_data:
    mov al, [esi]
    mov [edi], al
    inc esi
    inc edi
    loop parse_data

    mov edi, Packet_Protocol
    mov ecx, 4
parse_protocol:
    mov al, [esi]
    mov [edi], al
    inc esi
    inc edi
    loop parse_protocol

    mov al, [esi]
    inc byte [Packet_ID]
    inc esi

    mov al, [esi]
    mov [Packet_IP], al
    inc esi
    mov al, [esi]
    mov [Packet_IP+1], al

    jmp SetupPacket

