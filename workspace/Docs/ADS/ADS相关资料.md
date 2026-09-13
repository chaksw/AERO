## Books
### ADS
1. 《Aircraft Systems: Mechanical, Electrical, and Avionics Subsystems Integration》 - Ian Moir & Allan Seabridge 2023 - Chapter 6 
2. 《Introduction to Avionics Systems》 - R.P.G. Collinson, 2021版 - Chapter 4
3. 《飞行大气数据系统及关键技术》（梁应剑，谭向军，黄巧平）
### FCS
1. 《Design and Development of Aircraft Systems》（Ian Moir & Allan Seabridge, 2022版）- Chapter 9
2. 《民航飞机电子系统》
## Courses
1. 中国大学MOOC《航空电子系统》（北京航空航天大学，2024）- Module 3
2. Coursera《Aerospace Engineering: Airplane Performance》（Delft University, 2023）
## Domain Knowledge and Document
1. SAE International《DO-178C Training》
2. SAE AIR6110 (定义ADS传感器布局规范（如L型探头排布）与数据校验逻辑（三余度表决算法）)
3. RTCA DO-178C 航空软件认证核心标准，需结合《DO-178C and DO-331: A Practical Guide》理解ADS软件的DAL-B级开发流程
## Open-Source Project
1. FlightGear（GitHub）- 开源飞行模拟器，提供ADIRU模块的C++源码，可研究静压信号滤波与高度解算算法
2. ArduPilot - 开源飞控项目，集成大气数据融合代码（如AP_Airspeed库），支持Pixhawk硬件实时验证
3. MATLAB Aerospace Toolbox - 提供标准大气模型函数（atmosisa）、空速计算工具（airspeed），支持Simulink控制律原型开发
## Influencer
1. 知乎专栏“航空工业”
2. 微信公众号“适航思维”
## Project
1. ADS算法开发 - 基于MATLAB实现ISA模型下的气压高度计算，并加入温度漂移补偿（参考网页1的公式推导）
2. 适航文档编写 - 参照DO-178C模板撰写ADS软件需求规格书（SRS），包含故障模式与影响分析（FMEA）