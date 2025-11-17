USB_DATA1 EQU 0x27
USB_DATA2 EQU 0x28
section .bss
USBBuffer: resb 1048575
cmp ah, 0
je write
cmp ah, 1
je read
Write:
OUT 0x27, AX
OUT 0x28, EAX
Read:
IN AX, 0x27
MOV [USBBuffer], AX
IN EAX, 0x28
MOV [USBBuffer], EAX

