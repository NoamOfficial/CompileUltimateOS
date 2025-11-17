.386

SECTION .bss
server      resb 15
client      resb 15

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

DriverLoop:
    cmp ah, 0
    je SEND
    cmp ah, 1
    je RECEIVE
    jmp DriverLoop

SEND:
    xor si, si
send_client:
    mov al, [client + si]
wait_thr_send:
    in al, UART_LSR
    test al, THR_EMPTY
    jz wait_thr_send
    mov al, [client + si]
    out COM1_PORT, al
    inc si
    cmp si, 15
    jl send_client
    jmp DriverLoop

RECEIVE:
    xor si, si
receive_server:
    in al, COM1_PORT
    in al, UART_LSR
    test al, DATA_READY
    jz receive_server
    mov [server + si], al
    inc si
    cmp si, 15
    jl receive_server

    xor si, si
parse_data:
    mov al, [server + si]
    mov [Packet_Data + si], al
    inc si
    cmp si, 8
    jl parse_data

    xor si, si
parse_protocol:
    mov al, [server + 8 + si]
    mov [Packet_Protocol + si], al
    inc si
    cmp si, 4
    jl parse_protocol

    mov al, [server + 12]
    inc byte [Packet_ID]

    mov ax, [server + 13]
    mov [Packet_IP], ax

    jmp DriverLoop



