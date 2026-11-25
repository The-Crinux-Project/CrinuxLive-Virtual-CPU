# CrinuxLive-Virtual-CPU
A entire virtual computer with a CPU and RAM written in Lua using the AWESOME framework Love2D. NO AI!
Currently main.lua includes the assembler, and the CPU + memory. Next update will include a working version of a compiler for a low-level lanquage -> CASM. Eventually, once all 3 are done, they will be split into indiviual repos as I begin on my OS (that will be written in that low level lanquage).
main.casm is a template file in CASM for the Fibonacci sequence.
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
- POP r1 (Pops the top entry off the stack and moves it into r1)
- PUSH r1 (Pushes the data of r1 onto the stack)
- AND r1,r2,r3 (Bitwise operation, r2 AND r3 = r1)
- OR r1,r2,r3 (Bitwise operation, r2 OR r3 = r1)
- XOR r1,r2,r3 (Bitwise operation, r2 XOR r3 = r1)
- NOT r1 (Bitwise operation, r1 = NOT r1)

There are 16 registers that support 32 bit integers.

Also it uses the GNU General Public License to generally license the public
