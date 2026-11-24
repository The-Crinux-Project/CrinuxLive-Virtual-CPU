# CrinuxLive-Virtual-CPU
A entire virtual computer with a CPU and RAM written in Lua using the AWESOME framework Love2D. NO AI!
Currently main.lua includes a beta stage of the assembler and CPU and memory.
main.casm is a template file in my WIP language for the Fibonacci sequence.
Currently the ISA supports:

- MOV r1, 67 (set a register to a integer)
- CPY r2, r1 (set a register to a register)
- START: (a label used for jumping and later functions. CPU runs START: label to run the program, starting code must be inside that.)
- JMP START (jump up a label)
- END (ends execution, also auto-ends at the end of a file)
- ADD r3,r1,r2 (adds registers. in this case it adds r1 and r2 and outputs into r3)
- SUB r3,r1,r2 (subs registers. in this case it subs r1 and r2 and outputs into r3)
- SYS PRINT r1 (system call, currently only 1: PRINT. prints a register)
- CMP r1,0 (compares 2 integers or registers. value 1 - value 2 = output, if output is zero set zero flag, if negative raise negative flag)
- JZ START (jump to a label IF zero flag is raised)
- JZF START (jump to a label IF zero flag is NOT raised)
- JN START (jump to a label IF negative flag is raised)
- JNF START (jump to a label IF negative flag is NOT raised)
- CALL START (jmp, but treats it as a function and sets return adr)
- RET (return from a function, set program counter to return adr + 1)
- MLOAD r1,r2 (load a value (second argument) into a memory address (first argument))
- MREAD r1,r2 (read a address (first argument) and put it into a register (r2))
- Both MLOAD and MREAD support integers or registers for every argument except the second one on MREAD


There are 16 registers that support 32 bit integers.

Next update:
I dont know its pretty close

Also it uses the GNU General Public License to generally license the public
