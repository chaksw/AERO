# C919 Throughput Optimization

## Slide 1: Ideas for Optimization (Cleanup & Logic)
### Cleanup Signals in IOI
* IOI is expensive. Do you need all of those IOI signals for the models? Can we reduce IOI signals?

### Move Logic to Slower Rates
* Is there any high rate model logic that can be moved to a slower rate?
* AF inner loop logic from 80/40hz to 10hz

### Remove Redundant Logic
* Is there any repeated conditional checks? Logic where the same condition is evaluated multiple times
* Is there operations calculated multiple times instead of being computed once and reused?

### Move Models to Hand-Code
* Is there any models that can be moved to hand code? On a previous program we moved complex selection logic from models to handcode.

---

## Slide 2: Ideas for Optimization (Cache Line Awareness - Struct Packing)
### Cache Line Awareness
* Cache lines is how the data is stored and accessed on a byte aligned boundary.
* Analyze if the data structures are aligned to cache line boundaries that minimize padding and fits within a single cache line of 64 bytes.
* Examples are structure packing which is arranging struct members to minimum padding to fit within cache lines.

```c
struct BadPackedExample {
    char a;       // 1 byte
                  // 3 bytes padding
    int b;        // 4 bytes
    double c;     // 8 bytes
}; // 16 Bytes in total

struct GoodPackedExample {
    double c;     // 8 bytes
    int b;        // 4 bytes
    char a;       // 1 byte
                  // 3 bytes padding (still needed, but less overall)
}; // 16 Bytes in total

```

---

## Slide 3: Ideas for Optimization (Cache Line Awareness - SoA vs AoS)
### Cache Line Awareness
* Another example is implementing structure of arrays (SoA) instead of array of structures (AoS). SoA is preferred in order to process one field across many objects.

```c
// Array of Structure (AoS)
struct Particle { float x, y, z; };
Particle particles[1000];

// Structure of Arrays (SoA)
float x[1000], y[1000], z[1000];
```

---

## Slide 4: Ideas for Optimization (Avoid Math on Constants)
### Avoid math operation on constant parameters
* It could be pre-calculated instead of calculating each execution frame

**Example:**
If the output is computed as below, where `coeff_1` is constant parameter:
`Output = Input * (sqrt (coeff_1 * Pi)) / 100`

Then `(sqrt (coeff_1 * Pi)) / 100` could be pre-calculated as `coeff_2`, the result of this calculation will be same each exec frame, so the output computation could change to:
`Output = Input * coeff_2`

---

## Slide 5: Ideas for Optimization (Initialization Tasks)
* Initialization tasks are performed prior the process is created and prior to start monitoring TBE (time budget exceeded)
    * It is assumed that the 'init' actions may take longer than time standardly allocated to process periodic phase
* Consolidation of conditioned tasks driven by the same condition instead of having the same if condition in each function
    * Eg `if (!initialized) do array initialization and set initialized to TRUE`

---

## Slide 6: Optimization categories
### Categorization from the optimization subject point of view
* **Order of Complexity Optimizations**
    * Optimizations based on reducing the algorithm complexity (example: using lower precision mathematical functions)
* **Factor Optimizations**
    * No change to algorithm. (example: replacing logical operators with bitwise)

### Categorization from the development process point of view
* **Design level**
    * Optimization enabled by a design decision. (example: design of FC I/O infrastructure)
* **Source code level**
    * Optimization done during coding. (example: HAM optimizations)
* **Compile level**
    * Compiler optimizations

---

## Slide 7: FC IO routines design
### Optimization:
* A design optimization
* The aim is to minimize data copying
* Uses buffer aliases to avoid data copying
* Leverages rate monotonic process priority assignments to avoid data copying

### Issues:
* Portability

> Note: The description of the previous program's IO infrastructure is beyond the scope of this presentation

---

## Slide 8: Small Data Area
### Optimization:
* Basically a big structure.
* Variables are addressed as offset from the middle of the SDA region.
* One register is reserved to hold address of the middle of the SDA region (PPC r13, MIPS $28).
* Saves one instruction per memory access
* Biggest advantage for software with large number of primitive variables.

### Issues:
* Only 64K of memory available.
* Relatively painless if all variables, possibly a subset selected by a simple rule (e.g. all variables up to 32 bits large) fits into SDA.
* If not, case by case variable selection for SDA inclusion/exclusion can be problematic especially when introduced late in the development.

**Code Example:**
```c
// C-code
foo_in_sda     = 0x600D;
bar_not_in_sda = 0xBEEF;
```
```assembly
// PPC assembler (GHS compiler)
li r12, 24589
stw r12, %sdaoff(foo_in_sda)(r13)

lis r12, 1
lis r11, %hiadj(bar_not_in_sda)
addi r12, r12, 16657
stw r12, %lo(bar_not_in_sda)(r11)
```

**Memory Mapping Diagram:**
```text
       Memory
   |------------|
   |            |
   |============|
   |    SDA     |
   |-- region --| <--- SDA base address
   |            |
   |============|
   |            |
   |------------|
```

---

## Slide 9: Symbol aliasing
### Usage:
* Allows to create alias symbols for variables or buffer location
* Allows to avoid "glue code" or pointers for buffer binding (e.g. sampling port binding)
* Allows to use SDA optimization on buffer bindings
* Allows to decouple functional code from the IO code. The fact that a signal resides in a buffer (e.g. sampling port, xrate buffer) or it is a primitive variable, does not affect the code that uses it.

### Issues:
* May depend on the tools (i.e. assembler)

**Object symbols (gnm output):**
```text
[Index] Value Size Type Bind Other Shndx Name
[8]         2    2 OBJT GLOB 0     .sdata bar
[9]         1    1 OBJT GLOB 0     .sdata x
[10]        0    4 OBJT GLOB 0     .sdata f
[11]        0    4 OBJT GLOB 0     .sdata foo
```

**Code Implementation:**
```c
// H-file
extern uint32_T foo;
extern uint16_T bar;
extern uint8_T x;
extern real_T f;

// C-file
uint32_T foo = 0;
#pragma asm
    .global bar
    bar .equ foo+2
    .type bar,@object
    .size bar,2

    .global x
    x .equ foo+1
    .type x,@object
    .size x,1

    .global f
    f .equ foo+0
    .type f,@object
    .size f,4
#pragma endasm
```

**Aliases Memory Overlay Diagram:**
```text
+----------+-----------------------------------+
|          |              Aliases              |
|          +----------+----------+-------------+
|          |          |          |             |
|   foo    |          +----------+      f      |
| (buffer) |          |    x     |             |
|          +----------+----------+             |
|          |          |          |             |
|          |   bar    |          |             |
+----------+----------+----------+-------------+
```

---

## Slide 10: Fast math routines
### Optimization:
* Faster math routines with lower precision used to replace standard math library functions:
    * `FAST_ASIN.C`
    * `FAST_COS.C`
    * `FAST_EXP.C`
    * `FAST_FLOOR_CEIL.C`
    * `FAST_SIN.C`
    * `FAST_TAN.C`

### Issues:
* None if one can live with the lower precession
* Mixing the higher and lower precession routines can be problematic to setup

---

## Slide 11: Logical versus Bitwise operators
### Optimization:
* Logical AND and OR operators are replaced with bitwise operators
* Eliminates a couple of instructions per operator. -> significant saving if software contains large number of logical operators (e.g. majority of PF signals are booleans accompanied by some 62000 logical operators in auto generated code)

### Issues:
* Operands must have value 1 or 0 otherwise the concept falls apart.
* May need to use external tool to enforce the valid values (i.e. strong type checking).
* Logical and bitwise operators have different precedence.
* V&V issue with code coverage.

### Measurement:
* PF Improvement cca 15% COM, 8% MON on tput measurement "number".

**Code Example:**
```c
// C-code
if (a || b)
    do_something();

if (c | d)
    do_something();
```
```assembly
// PPC assembler (GHS compiler)
lis r12, %hiadj(a)
lbz r12, %lo(a)(r12)
cmpwi r12, 0
bne .L5
lis r12, %hiadj(b)
lbz r12, %lo(b)(r12)
cmpwi r12, 0
beq .L4
.L5:
bl do_something
.L4:

lis r11, %hiadj(c)
lis r12, %hiadj(d)
lbz r11, %lo(c)(r11)
lbz r12, %lo(d)(r12)
or. r12, r11, r12
beq .L2
bl do_something
.L2:
```

---

## Slide 12: Improvement of data cache usage
### Optimization:
* Organize data to reduce cache line misses
    * Pack data more tightly so that more data fits into cache -> fewer cache line misses.
* Many examples in FCM software, primarily in FCU:
    * IO tables
    * X-rate tables
    * PF bit packing routines

### Issues:
* Optimization can make the code harder to read and maintain

---

## Slide 13: Improvement of data cache usage (examples)
### Xrate tables init struct and old design equivalent
```c
/* Initialization buffer formats */
typedef struct
{
    void*  source;
    void*  sourceEnd;
    void*  destination;
    void*  tempBuffer;
} XRateBufferingRec_In;
```
* **16 bytes per entry**
> Note: The old design did not have the temp buffers

### Xrate tables
```c
/* real-time buffer formats */
typedef struct
{
    uint16_T source;
    uint16_T count;
    uint16_T destination;
    uint16_T tempBuffer;
} XRateBufferingRec;
```
* **8 bytes per entry**

---

## Slide 14: Improvement of data cache usage (examples)
### IO table initial design
```c
typedef struct
{
    uint8_T   frameRate;
    uint8_T   startFrame;
    uint16_T  action;
    void      *src;
    void      *dst;
    uint32_T  numBytes;
} IO_Table_Entry_t;
```
* **1 entry 16 bytes**
* **Table size n x 16**

### Compressed IO table
```c
typedef struct
{
    uint32_T  ModeWord;
} IO_Table_Entry_mode;
// entry 4 bytes

typedef struct
{
    uint32_T:2   mode;
    uint32_T:30  numbytes;
    void         *src;
    void         *dst;
} IO_Table_Entry_long;
// entry 12 bytes

typedef struct
{
    uint32_T:2   mode;
    int32_T:15   src_offset;
    int32_T:15   dst_offset;
} IO_Table_Entry_short;
// entry 4 bytes
```
* Different entry sizes
* Table size depends on source and destination memory locations
* Not considering the general memcopy IO table action
* All too far: `4 x ceil(n/16) + n x 12`
* All within +/- 16k: `4 x ceil(n/16) + n x 4`
* **Saving 23% - 73% of the original table size**

> **Graph Summary (Memory saving with respect to 16 bytes per record [%]):**
> * **Upper Bound (Within +/- 16k):** Rapidly reaches and plateaus at ~73% memory saving as the number of table entries increases.
> * **Lower Bound (Too far apart):** Rises and stabilizes at ~23% memory saving.

---

## Slide 15: Improvement of data cache usage (examples)
### Binary search optimization in SP PCM processing
* Three column conversion table split into two tables
* Binary search performed on the first column
* 8 values fit into cache line
* The alignment to 8 bytes of the second two columns ensures that there will be at most one cache line miss after the desired row is determined

**Code Example:**
```c
real_T pcm_C_to_Rthm_Table1[C_TO_RTHM_ROWS] = {
    pcm_C_to_Rthm_Table_Min,
    0.940500557103f,
    0.984372303207f,
    1.02907558671f,
    1.07494333015f,
    ...
};

#pragma alignvar(8) /* make sure each word pair of pcm_C_to_Rthm_Table2 is in the same cache-line */
theC_to_RthmType pcm_C_to_Rthm_Table2[C_TO_RTHM_ROWS] = {
    {23.3855810939f, -45.994152047f},
    {22.7937132393f, -45.4375f},
    {22.3697214531f, -45.0201342289f},
    {21.8018137585f, -44.4357142848f},
    ...
};
```

---

## Slide 16: Improvement of instruction cache usage
### Optimization:
* Organize functions to reduce "normal path" size
    * Move functionality that is rarely needed into a separate function. This way the code is not loaded into cache unless the functionality is needed.
* Examples in FCM software:
    * Error handling in a separate function. (Not all partitions adhere to this)
    * CSW memcopy routines.

**Code Example:**
```c
void handle_error(errorNumber_T errorNumber, Char_T* desc, uint32_T descLenght)
{
    ...
}

...
GET_PARTITION_STATUS(&PartitionStatus, &ret);
if (ret != NO_ERROR)
    handle_error(OS_CALL_ERROR, "main(): GET_PARTITION_STATUS() call failed", strlen("main(): GET_PARTITION_STATUS() call failed"));
...
```

---

## Slide 17: Constant propagation
### Optimization:
* A compiler optimization
* Source code can be written to enable constant propagation
* Related to HAM - Inline parameters optimization

### Issues:
* Effectiveness may depend on the compiler

---

## Slide 18: Constant propagation (PF IMB unpacking example)
* An interesting example of using inline function instead of table driven algorithm
* If the function parameter that is used to control the switch inside the ReadIMB() is constant, the compiler can eliminate the unused switch cases.

**Pros:**
* Can still used SDA optimization. Not possible for table driven algorithm
* No need to load conversion parameters a data table (e.g. pointers, bit positions...)

**Cons:**
* The resultant code will be larger
* CTP may be a bit problematic depending on the V&V team

### PF IMB unpacking example
```c
inline void ReadIMB( uint32_T* packetOffset,
                     type_ImbParam imbDataType,
                     uint16_T wordOffset,
                     uint16_T lsb,
                     uint16_T msb,
                     real_T scaleFactor,
                     void* pOutput)
// Function contains large switch that switches on imbDataType

void PF080_IMB_RMT_SREU_Processing( void )
{
    ReadIMB(&offset_label_0x4D45, eDIS, 14, 0, 0, NO_SCALING, (void*)&splr_14_reu_valid_reu_t);
    ReadIMB(&offset_label_0x4D45, eDIS, 14, 1, 1, NO_SCALING, (void*)&splr_14_com_mon_f_unl_reu_t);
    ReadIMB(&offset_label_0x4D45, eDIS, 14, 3, 3, NO_SCALING, (void*)&splr_14_parity_f_l_reu_t);
    ...
}
```

### PPC assembler
```assembly
lhz     r8, 34(r9)
lis     r11, %hiadj(splr_14_reu_valid_reu_t)
rlwinm  r12, r8, 0, 31, 31
stb     r12, %lo(splr_14_reu_valid_reu_t)(r11)

// Note: common part (e.g. loading offset_label_0x4D45, IMB pointer loading) omitted.
```

---

## Slide 19: Fast RAM usage
### Optimization:
* Capitalize on special hardware resources
* FCM contains 256 Kbytes of general-purpose SRAM with single-bit ECC correction. This memory has a faster access.
* MON lane utilizes this memory to hold data sections (e.g. PF .sbss, .SP_fast_data)

### Measurement:
* Improvement for `.SP_fast_data` in MON 2.5% on tput measurement "number".

---

## Slide 20: Poor man's shared library aka Common L2 cache locked routines
### Optimization:
* Utilize L2 cache as fast memory

### Implementation:
* INTEGRITY 178B does not support shared libraries
* Custom solution is necessary

### Issues:
* A bit fragile implementation
* Routines placed into L2 cache cannot use data sections (e.g. .data)
* Need to split modules into init part and runtime part

> Note: A detailed description is beyond the scope of this presentation.

### Memory Mapping Diagram
```text
      Partition memory                           L2 locked memory
    +------------------+                       +------------------+
    |                  |    Call L2 routine    |                  |
    |  Fixed virtual   |---------------------->|    Jump table    |
    |  address --+     |                       +------------------+
    |            |     |                       |                  |
    +------------v-----+                       |                  |
    |                  |                       |                  |
    |  Partition copy  |                       |     Routines     |
    |  of .bss data    | L2 .bss region        |                  |
    |  for L2 locked   |                       |                  |
    |  routines        |                       |                  |
    +------------------+                       +------------------+
    |                  |
    +------------------+
```

---

## Slide 21: Code tweaks
### Optimization:
* C code is written such that the resultant assembly is more effective.
* Examples in FCM software:
    * Many examples in FCU and S-functions code

### Issues:
* Very fragile optimization
* May need to be developed by trial and error
* Compiler and compiler settings dependant
* Can make the code harder to read
* Makes the code harder to maintain (the effect of the code tweak has to be evaluated after every code modification)

---

## Slide 22: Code tweak example from FAST_TAN.C
```c
const real_T tan_table[TAN_TABLE_SIZE+1] =
{
    0, 0.024548622f, 0.04912685f, 0.073764432f, 0.098491403f,
    ...
    1.0f
};

real64_T tan(real64_T angle)
{
    real_T const_one;
    ...
    const_one = *(volatile real_T *)&tan_table[TAN_TABLE_SIZE];
    ...
    negate_tan = -const_one;
}
```
* The compiler with current setting normally creates a separate constant for 1 as well as for -1 and loads them from memory.
* Adding the `volatile` modifier causes the compiler to lose confidence with optimizations.
* The constant 1 is loaded from the table, which also takes care of loading the pointer to the table into register for all later accesses.
* The constant -1 is obtained by negation the constant 1, which is already in register.
* Overall it saves couple of instructions including some memory load instructions.

---

## Slide 23: RTW - Loop rolling
### Optimization:
* Loops are rolled -> code size reduction and improvement of instruction cache utilization.

**Loop rolling turned off (C919_FCE_NOTPBWIP):**
```c
/* Gain: '<S107>/Gain_1' incorporates:
 *  Inport: '<Root>/inFloat10'
 *  Inport: '<Root>/inFloat11'
 *  Constant: '<S103>/Constant_1'
 */
modell_bus_B_Gain_1[0] = inFloat10 * 2.0;
modell_bus_B_Gain_1[1] = inFloat11 * 2.0;
modell_bus_B_Gain_1[2] = modell_bus_P_Constant_1_Value[0] * 2.0;
modell_bus_B_Gain_1[3] = modell_bus_P_Constant_1_Value[1] * 2.0;
```

**Loop rolling turned on (C919LOOP_NOTPBWIP):**
```c
{
  /* local block i/o variables */
  real_T rtb_dbl_U[4];
  int32_T i1;
  ...
  /* Mux: '<S110>/999' */
  rtb_dbl_U[0] = inFloat10;
  rtb_dbl_U[1] = inFloat11;
  rtb_dbl_U[2] = modell_bus_P.Constant_1_Value[0];
  rtb_dbl_U[3] = modell_bus_P.Constant_1_Value[1];

  for(i1 = 0; i1 < 4; i1++) {
    /* Gain: '<S107>/Gain_1' incorporates:
     *  Constant: '<S103>/Constant_1'
     *  Inport: '<Root>/inFloat11'
     *  Inport: '<Root>/inFloat10'
     */
    modell_bus_B_Gain_1[i1] = rtb_dbl_U[i1] * 2.0;
  }
  ...
}
```

---

## Slide 24: HAM - Moving global variables to local scope
### Optimization:
* Not an RTW optimization
* Signals from model "B" structure moved as local variables into model step function -> higher chance to use CPU registers

**Remove HAM global variables turned on (C919_FCE_NOTPBWIP):**
```c
/* Gain: '<S107>/Gain_1' incorporates:
 *  Inport: '<Root>/inFloat10'
 *  Inport: '<Root>/inFloat11'
 *  Constant: '<S103>/Constant_1'
 */
modell_bus_B_Gain_1[0] = inFloat10 * 2.0;
modell_bus_B_Gain_1[1] = inFloat11 * 2.0;
modell_bus_B_Gain_1[2] = modell_bus_P.Constant_1_Value[0] * 2.0;
modell_bus_B_Gain_1[3] = modell_bus_P.Constant_1_Value[1] * 2.0;

/* Sum: '<S123>/Sum_1' */
out35[0] = modell_bus_B_Gain_1[2] - modell_bus_B_Gain_1[0];
out35[1] = modell_bus_B_Gain_1[3] - modell_bus_B_Gain_1[1];
```

**Remove HAM global variables turned off (C919_FCE_NOSTPBWIP):**
```c
/* Gain: '<S107>/Gain_1' incorporates:
 *  Inport: '<Root>/inFloat10'
 *  Inport: '<Root>/inFloat11'
 *  Constant: '<S103>/Constant_1'
 */
modell_bus_B.Gain_1[0] = inFloat10 * 2.0;
modell_bus_B.Gain_1[1] = inFloat11 * 2.0;
modell_bus_B.Gain_1[2] = modell_bus_P.Constant_1_Value[0] * 2.0;
modell_bus_B.Gain_1[3] = modell_bus_P.Constant_1_Value[1] * 2.0;

/* Sum: '<S123>/Sum_1' */
out35[0] = modell_bus_B.Gain_1[2] - modell_bus_B.Gain_1[0];
out35[1] = modell_bus_B.Gain_1[3] - modell_bus_B.Gain_1[1];
```

---

## Slide 25: HAM - Inline parameters
### Optimization:
* Not an RTW optimization
* Improves constant folding

**Inline parameters turned on (C919_FCE_NOTPBWIP):**
```c
/* Gain: '<S153>/qfgain_1' incorporates:
 *  Gain: '<S153>/F'
 *  Gain: '<S153>/K'
 *  Sum: '<S153>/8'
 */
modell_bus_B_qfgain_1 = (modell_bus_B_d_BusFloat1 - rtb_r64_temp547 * 3.950625) - rtb_p_4 * -7.99875 * 2.4687548217867611E-001;

/* Sum: '<S153>/quadFilter_1' incorporates:
 *  Gain: '<S153>/A'
 *  Gain: '<S153>/B'
 *  Gain: '<S153>/C'
 */
out70 = (modell_bus_B_qfgain_1 * 2.0056249999999998E+000 + rtb_p_4 * -3.99875) + rtb_r64_temp547 * 1.9956250000000002E+000;
```

**Inline parameters turned off (C919_FCE_NOTPBW):**
```c
/* Gain: '<S153>/qfgain_1' incorporates:
 *  Gain: '<S153>/F'
 *  Gain: '<S153>/K'
 *  Sum: '<S153>/8'
 */
modell_bus_B_qfgain_1 = (modell_bus_B_d_BusFloat1 - rtb_r64_temp547 * modell_bus_P.F_Gain) - rtb_p_4 * modell_bus_P.K_Gain * modell_bus_P.qfgain_1_Gain;

/* Sum: '<S153>/quadFilter_1' incorporates:
 *  Gain: '<S153>/A'
 *  Gain: '<S153>/B'
 *  Gain: '<S153>/C'
 */
out70 = (modell_bus_B_qfgain_1 * modell_bus_P.A_Gain + rtb_p_4 * modell_bus_P.B_Gain) + rtb_r64_temp547 * modell_bus_P.C_Gain;
```

---

## Slide 26: Some tips
* Minimize the use of global variables.
* Floating point multiplication is often faster than division - use `val * 0.5` instead of `val / 2.0`.
* If you have to use a big `if..else..` statement, test the most likely cases first.
* Put structure members that are often accessed first.

---

## Slide 27: Conclusion
* Optimization are specific to platform/compiler. It is difficult to make any general suggestions
    * For example, loop unrolling is generally considered to improve performance. However on some platforms, the opposite is true.
* Do you really need to optimize?
* Early optimization, not supported by any analysis should be avoided.
    * There is no point to spent any effort to eliminate a couple of instructions from a function that gets called once per execution frame.
* On the other hand, if one can anticipate optimizations in particular area it is better to prepare for it.
    * Logical operator replacement was in SP initially implemented without the AND/OR macros which had to be fixed later.

---
