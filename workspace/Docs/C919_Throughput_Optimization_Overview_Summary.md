# C919 Throughput Optimization: Overview and Summary
--CN--
## 1. 各幻灯片内容概述

*   **Slide 1: 逻辑与清理**。探讨减少冗余IOI信号、将高频逻辑降频执行、移除重复的条件判断，以及将复杂模型转为手写代码的思路[cite: 1]。
*   **Slide 2: 缓存行感知（结构体对齐）**。介绍通过优化C语言结构体成员的排列顺序（Struct Packing）来减少内存填充（Padding），使其更好地适应 64 bytes 的缓存行[cite: 2]。
*   **Slide 3: 缓存行感知（SoA vs AoS）**。建议使用“数组结构（SoA）”替代“结构体数组（AoS）”，以提高跨对象处理单一字段时的缓存命中率[cite: 3]。
*   **Slide 4: 避免常量数学运算**。建议将含有常量的数学计算结果提前算好并存储，避免在每个执行周期重复计算[cite: 4]。
*   **Slide 5: 初始化任务优化**。强调在进程创建和TBE（时间预算超出）监控开始前完成耗时的初始化任务，并整合相同条件的判断[cite: 5]。
*   **Slide 6: 优化分类**。将优化按“对象”（算法复杂度优化 vs 因子优化）和“开发阶段”（设计级、源码级、编译级）进行分类[cite: 6]。
*   **Slide 7: FC IO 路由设计**。介绍通过使用缓冲区别名和速率单调分配来减少数据拷贝的架构设计，但存在可移植性问题[cite: 7]。
*   **Slide 8: SDA (Small Data Area)**。讲解如何利用单个基址寄存器加偏移量来访问小数据区，以节省内存访问指令，但也指出了 64K 内存大小的限制[cite: 8]。
*   **Slide 9: 符号别名 (Symbol Aliasing)**。展示如何通过汇编层面的内存映射（Overlay），在不使用指针或胶水代码的情况下，实现底层缓冲区与变量的复用解耦[cite: 9]。
*   **Slide 10: 快速数学函数**。使用低精度的自定义数学库（如 `FAST_SIN`、`FAST_COS`）替代标准数学库来提升计算速度[cite: 10]。
*   **Slide 11: 逻辑运算符 vs 位运算符**。建议在满足操作数为 0 或 1 的前提下，用位运算（`&`, `|`）替代逻辑运算（`&&`, `||`）以精简指令数[cite: 12]。
*   **Slide 12-14: 提升数据缓存使用率**。通过紧凑的数据打包降低缓存未命中率。举例说明了重构 X-rate 表（从16字节降至8字节）[cite: 13, 14] 以及压缩 IO 表（节省了23%-73%的内存）[cite: 15] 的收益。
*   **Slide 15: 二分查找优化**。在处理 SP PCM 数据时，通过拆分表格并对齐缓存行，确保在查表时最多只发生一次缓存未命中[cite: 16]。
*   **Slide 16: 提升指令缓存使用率**。建议将极少执行的逻辑（如错误处理）分离为独立函数，从而缩减“常态执行路径”的体积，避免无效的缓存加载[cite: 17]。
*   **Slide 17-18: 常量传播 (Constant Propagation)**。讲解通过内联函数传入常量参数，让编译器在编译期自动剔除冗余的分支代码（如 `switch..case`）以提升执行效率[cite: 18, 19]。
*   **Slide 19: 快速 RAM 利用**。介绍将某些特定数据段（如 `.SP_fast_data`）放入拥有单比特 ECC 纠错且访问速度更快的 256KB SRAM 中[cite: 20]。
*   **Slide 20: 共享库替代方案（L2 Cache 锁定）**。在不支持共享库的 INTEGRITY 178B 系统上，通过将通用代码锁定进 L2 缓存来实现快速执行的自制方案[cite: 21]。
*   **Slide 21-22: 代码微调 (Code Tweaks)**。介绍通过针对特定编译器的代码写法（如 `FAST_TAN.C` 中用 `volatile` 和负号复用常量 1）来榨取极限性能，但警告这种做法极度脆弱且难以维护[cite: 23, 24]。
*   **Slide 23: RTW 循环展开 (Loop Rolling)**。探讨在 Simulink/RTW 自动生成代码时，展开循环以缩减代码体积并提升指令缓存命中率[cite: 25]。
*   **Slide 24: HAM 全局变量局部化**。将结构体里的信号提取为局部变量，以增加其被分配至 CPU 高速寄存器的概率[cite: 26]。
*   **Slide 25: HAM 内联参数**。开启内联参数功能，从而在自动生成代码阶段更好地实现常量折叠计算[cite: 27]。
*   **Slide 26: 编码建议汇总**。给出了具体的编程 Tips：减少全局变量、用乘以 0.5 替代除以 2.0、在大的 `if-else` 中优先判断高频分支、常用结构体成员放最前面[cite: 28]。
*   **Slide 27: 结论**。总结优化具有强烈的平台/编译器依赖性；呼吁避免“无数据支撑的过早优化”；但对于明确的性能瓶颈，应尽早在架构上做好准备[cite: 29]。

---

## 2. 核心思想总结

本文件是一份**面向航空嵌入式系统（C919 飞控项目）的深度性能优化指南**。

它系统性地梳理了在算力与资源严格受限的硬实时环境（Hard Real-time System）中，如何通过各种手段榨取系统吞吐量（Throughput）。其核心优化逻辑可以归结为以下几个维度：

1.  **内存与缓存压榨**：深入理解 CPU Cache 机制，通过数据结构对齐、数组结构化（SoA）、甚至锁定 L2 Cache 等物理手段，极力降低内存访问延迟和 Cache Miss 概率[cite: 2, 3, 13, 21]。
2.  **编译器特性利用**：巧妙利用甚至“欺骗”编译器（GHS 编译器），比如使用常量传播、符号别名（Symbol Aliasing）和 `volatile` 微调，以生成最短的 PPC 汇编指令[cite: 9, 18, 19, 24]。
3.  **算法与逻辑降维**：使用低精度近似计算（Fast Math）、位运算替代逻辑运算、提前计算常量，以及优化自动生成代码（RTW/HAM）的执行结构[cite: 4, 10, 12, 25]。

**最终传达的方法论是**：极致的性能优化往往会以牺牲代码的可读性、可移植性和可维护性为代价（如 Code Tweaks）。因此，优化必须建立在测量之上，**反对盲目且过早的优化，但在关键架构层面必须提前做好设计防范**[cite: 23, 29]。
--CN--

--EN--
## 1. Slide-by-Slide Overview

*   **Slide 1: Cleanup & Logic**. Discusses reducing expensive IOI signals, moving high-rate logic to slower rates, removing redundant conditional checks, and moving complex models to hand-code [cite: 1].
*   **Slide 2: Cache Line Awareness (Struct Packing)**. Introduces optimizing the arrangement of C structure members to minimize padding, allowing them to better fit within a 64-byte cache line [cite: 2].
*   **Slide 3: Cache Line Awareness (SoA vs. AoS)**. Recommends implementing Structure of Arrays (SoA) instead of Array of Structures (AoS) to improve cache hit rates when processing a single field across multiple objects [cite: 3].
*   **Slide 4: Avoiding Math on Constants**. Advises pre-calculating math operations that involve constant parameters instead of computing them during every execution frame [cite: 4].
*   **Slide 5: Initialization Tasks**. Emphasizes performing time-consuming initialization tasks before the process is created and TBE (time budget exceeded) monitoring begins, alongside consolidating conditioned tasks [cite: 5].
*   **Slide 6: Optimization Categories**. Categorizes optimizations by subject (order of complexity vs. factor optimizations) and by development phase (design, source code, and compile level) [cite: 6].
*   **Slide 7: FC IO Routines Design**. Introduces a design optimization that minimizes data copying using buffer aliases and rate monotonic process priority assignments, while noting potential portability issues [cite: 7].
*   **Slide 8: Small Data Area (SDA)**. Explains using a single base register plus an offset to address variables in a small data area, which saves instructions per memory access but is limited to 64K of memory [cite: 8].
*   **Slide 9: Symbol Aliasing**. Demonstrates how to map memory overlays at the assembly level to decouple functional code from IO buffers without relying on pointers or "glue code" [cite: 9].
*   **Slide 10: Fast Math Routines**. Replaces standard math library functions with lower-precision, customized fast math routines (e.g., `FAST_SIN`, `FAST_COS`) to increase execution speed [cite: 10].
*   **Slide 11: Logical vs. Bitwise Operators**. Suggests replacing logical operators (`&&`, `||`) with bitwise operators (`&`, `|`) to eliminate extra instructions, provided the operands are strictly 0 or 1 [cite: 12].
*   **Slides 12-14: Improvement of Data Cache Usage**. Focuses on reducing cache line misses through tight data packing. Examples include restructuring X-rate tables (reducing entry size from 16 to 8 bytes) [cite: 13, 14] and compressing IO tables (yielding 23% to 73% memory savings) [cite: 15].
*   **Slide 15: Binary Search Optimization**. Splits a conversion table into two and aligns them to 8-byte cache lines, ensuring at most one cache line miss occurs during binary searches in SP PCM processing [cite: 16].
*   **Slide 16: Improvement of Instruction Cache Usage**. Recommends moving rarely needed functionality (like error handling) into separate functions to reduce the "normal path" size, avoiding unnecessary cache loads [cite: 17].
*   **Slides 17-18: Constant Propagation**. Explains how passing constant parameters into inline functions allows the compiler to eliminate unused switch cases at compile time, improving execution efficiency [cite: 18, 19].
*   **Slide 19: Fast RAM Usage**. Highlights utilizing specific hardware resources, such as placing data sections (e.g., `.SP_fast_data`) into a 256KB general-purpose SRAM with single-bit ECC for faster access [cite: 20].
*   **Slide 20: Poor Man's Shared Library (L2 Cache Locked)**. Details a custom solution for INTEGRITY 178B (which lacks shared library support) to lock common routines into the L2 cache for rapid execution [cite: 21].
*   **Slides 21-22: Code Tweaks**. Discusses writing C code specifically to trick the compiler into generating more efficient assembly (e.g., using `volatile` in `FAST_TAN.C` to negate a constant '1' instead of loading '-1' from memory). Warns that this approach is highly fragile and hard to maintain [cite: 23, 24].
*   **Slide 23: RTW - Loop Rolling**. Explores rolling loops in Simulink/RTW auto-generated code to reduce code size and improve instruction cache utilization [cite: 25].
*   **Slide 24: HAM - Moving Global Variables to Local Scope**. Moves signals from model structures into local variables within the step function, increasing the probability of them being assigned to CPU registers [cite: 26].
*   **Slide 25: HAM - Inline Parameters**. Enables inline parameters to improve constant folding during the code auto-generation phase [cite: 27].
*   **Slide 26: Coding Tips**. Provides practical coding tips: minimize global variables, use `* 0.5` instead of `/ 2.0`, evaluate the most likely cases first in `if-else` blocks, and place frequently accessed struct members at the beginning [cite: 28].
*   **Slide 27: Conclusion**. Concludes that optimizations are highly platform and compiler-dependent. Warns against premature optimization without profiling, but encourages preparing the architecture early for anticipated bottlenecks [cite: 29].


## 2. Core Philosophy Summary

This document serves as an **in-depth performance optimization guide for the C919 flight control embedded system**.

It systematically outlines how to maximize system throughput within a hard real-time environment characterized by strictly limited computing power and hardware resources. The core optimization strategies can be categorized into three main dimensions:

1.  **Memory & Cache Exploitation**: Deeply leveraging CPU cache mechanisms to minimize memory access latency and cache misses. This involves physical data alignments such as Struct Packing, Structure of Arrays (SoA), and advanced hardware utilization like locking the L2 cache [cite: 2, 3, 13, 21].
2.  **Compiler Feature Utilization**: Cleverly manipulating (and sometimes "tricking") the compiler (e.g., the GHS compiler). Techniques include constant propagation, symbol aliasing, and code tweaks using `volatile` modifiers to force the generation of the absolute minimum PPC assembly instructions [cite: 9, 18, 19, 24].
3.  **Algorithm & Logic Reduction**: Implementing low-precision calculations (Fast Math), replacing logical operations with bitwise operations, pre-calculating constants, and restructuring the execution flow of auto-generated code (via RTW/HAM settings) [cite: 4, 10, 12, 25].

**The Ultimate Methodology**: Extreme performance tuning often comes at the expense of code readability, portability, and maintainability (as seen in "Code Tweaks"). Therefore, optimizations must be strictly driven by actual measurement. The presentation strongly **advocates against blind and premature optimization, while insisting that critical structural and architectural optimizations must be prepared for early in the design phase** [cite: 23, 29].
--EN--

---