%ifndef VM86_INC
%define VM86_INC 1

%macro VM86 1
pushfd
or dword [esp], 0x00020000
popfd
%1
%endmacro

%endif
