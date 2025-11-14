org 0x130
resb 65335
db FF
org 0x200
mov es, 0x130
mov di, 0
copy:
lodsb
cmp al, FF
je done
cmp al, 8F
je ReadMessage
cmp al, 9F
je GetService
cmp al, 02
je ClearShared
cmp al, 0F
je WriteMessage
ReadMessage:
push di
push [es:di+bx]
pop bx
jmp copy
CallService:
push es
push di
mov es, 0x900
mov di, 0
search:
lodsw
cmp ah, dl
je CopyService
add di, 2
jne search
CopyService:
mov cx, ah
pop es
pop di
jmp copy
ClearShared:
mov cx, 65335
mov ds, seg 0x130
mov si, 0
mov al, 0
loop:
mov [ds:si], al
add si, 1
loop loop
jmp copy
WriteMessage:
mov [0x400], [esp + 2)
jmp copy





