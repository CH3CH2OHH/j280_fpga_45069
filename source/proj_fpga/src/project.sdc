//Copyright (C)2014-2024 Gowin Semiconductor Corporation.
//All rights reserved.
//File Title: Timing Constraints file
//Tool Version: V1.9.10.02
//Part Number: GW2A-LV55PG484C8/I7
//Device: GW2A-55
//Device Version: C
//Created Time: Fri Oct 23 16:19:52 2026

create_clock -name clk_50m -period 20 -waveform {0 10} [get_ports {clk_50m}]

set_false_path -from [get_ports {key_rst_n}]
set_false_path -from [get_ports {key[*]}]
set_false_path -from [get_ports {ad_d[*]}]
set_false_path -from [get_ports {ad_otr}]
set_false_path -from [get_ports {enc_a}]
set_false_path -from [get_ports {enc_b}]
set_false_path -from [get_ports {rxd}]

# 拓展板按键 / 编码器：异步输入，模块内部有 1 ms 消抖 + 两级同步
set_false_path -from [get_ports {sw1_s}]
set_false_path -from [get_ports {sw1_a}]
set_false_path -from [get_ports {sw1_b}]
set_false_path -from [get_ports {sw2_s}]
set_false_path -from [get_ports {sw2_a}]
set_false_path -from [get_ports {sw2_b}]
set_false_path -from [get_ports {sw3_s}]
set_false_path -from [get_ports {sw4_s}]
set_false_path -from [get_ports {sw5_s}]
set_false_path -from [get_ports {sw6_s}]
set_false_path -from [get_ports {sw7_s}]
