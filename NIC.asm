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

DriverLoop:
    cmp ah, 0
    je do_send
    cmp ah, 1
    je do_receive
    jmp DriverLoop

do_send:
    mov eax, dword [Packet_Data]
    mov ebx, dword [Packet_Data+4]

    mov ecx, 4
    mov edx, eax
send_dword1:
    in al, UART_LSR
    test al, THR_EMPTY
    jz send_dword1
    out COM1_PORT, dl
    shr edx, 8
    loop send_dword1

    mov ecx, 4
    mov edx, ebx
send_dword2:
    in al, UART_LSR
    test al, THR_EMPTY
    jz send_dword2
    out COM1_PORT, dl
    shr edx, 8
    loop send_dword2

    mov eax, [Packet_Protocol]
    mov ecx, 4
send_protocol:
    mov dl, al
    in al, UART_LSR
    test al, THR_EMPTY
    jz send_protocol
    out COM1_PORT, dl
    shr eax, 8
    loop send_protocol

    mov al, [Packet_ID]
send_id:
    in al, UART_LSR
    test al, THR_EMPTY
    jz send_id
    mov al, [Packet_ID]
    out COM1_PORT, al

    mov ax, [Packet_IP]
send_ip:
    mov dl, al
    in al, UART_LSR
    test al, THR_EMPTY
    jz send_ip
    out COM1_PORT, dl
    mov dl, ah
    in al, UART_LSR
    test al, THR_EMPTY
    jz send_ip
    out COM1_PORT, dl

    jmp DriverLoop

do_receive:
    xor esi, esi
receive_loop:
    in al, COM1_PORT
    in al, UART_LSR
    test al, DATA_READY
    jz receive_loop
    mov [server + esi], al
    inc esi
    cmp esi, 15
    jl receive_loop

    mov esi, server
    mov eax, [esi]
    mov [Packet_Data], eax
    mov eax, [esi+4]
    mov [Packet_Data+4], eax
    mov eax, [esi+8]
    mov [Packet_Protocol], eax
    mov al, [esi+12]
    inc byte [Packet_ID]
    mov ax, [esi+13]
    mov [Packet_IP], ax

    jmp DriverLoop


