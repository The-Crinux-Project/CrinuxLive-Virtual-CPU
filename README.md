# CrinuxLive-Virtual-CPU
A entire virtual computer with a CPU and RAM written in Lua using the AWESOME framework Love2D. NO AI!
Currently main.lua includes a beta stage of the assembler and CPU and memory.
main.casm is a template file in my WIP language for the Fibonacci sequence. 
Currently the ISA supports:
MOV r1, 67 (set a register to a integer)
CPY r2, r1 (set a register to a register)
START: (a label used for jumping and later functions. CPU runs START: label to run the program, starting code must be inside that.)
JMP START (jump up a label)
END (ends execution, also auto-ends at the end of a file)
ADD r3,r1,r2 (adds registers. in this case it adds r1 and r2 and outputs into r3)
SUB r3,r1,r2 (subs registers. in this case it subs r1 and r2 and outputs into r3)
SYS PRINT r1 (system call, currently only 1: PRINT. prints a register)
CMP r1,0 (compares 2 integers or registers. value 1 - value 2 = output, if output is zero set zero flag, if negative raise negative flag)
JZ START (jump to a label IF zero flag is raised)
JZF START (jump to a label IF zero flag is NOT raised)
JN START (jump to a label IF negative flag is raised)
JNF START (jump to a label IF negative flag is NOT raised)


There are 16 registers that support either 16 or 32 bit integers, I forgot.
But each part of the instruction can only be 8-bit, so you have to add to get the full size. Will be fixed in later optimization updates.

Next update:
Uping the instruction size and adding optimizations like better error detection and probaly memory managment

Also it uses the GNU General Public License to generally license the public


 
