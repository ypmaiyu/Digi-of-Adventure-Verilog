# build.tcl - create the Vivado project for Digi of Adventure on the Nexys A7-100T and (optionally) build it.
#
#   cd <repo>/fpga
#   vivado -mode batch -source vivado/build.tcl                 ;# project + synthesis + implementation + bitstream
#   vivado -mode batch -source vivado/build.tcl -tclargs create ;# only create build/vivado/digi.xpr (open it in the GUI)
#
# Before the first build run the asset / UI generators (see README.md): they write fpga/mem/*.mem and fpga/rtl/gen/*.vh.
set mode [expr {[llength $argv] > 0 ? [lindex $argv 0] : "all"}]
set here [file normalize [file dirname [info script]]]
set fpga [file normalize "$here/.."]
set part xc7a100tcsg324-1

create_project digi "$fpga/build/vivado" -part $part -force
set_property target_language Verilog [current_project]

# RTL (Verilog-2001) and the generated include files
set srcs [concat [glob $fpga/rtl/top/*.v] [glob $fpga/rtl/core/*.v] [glob $fpga/rtl/video/*.v] [glob $fpga/rtl/shared/*.v] \
                 [glob $fpga/rtl/flow/*.v] [glob $fpga/rtl/stage1/*.v] [glob $fpga/rtl/stage2/*.v] [glob $fpga/rtl/stage3/*.v]]
add_files -norecurse $srcs
set hdrs [concat [glob $fpga/rtl/gen/*.vh] [glob $fpga/rtl/video/*.vh] [glob $fpga/rtl/shared/*.vh]]
add_files -norecurse $hdrs
foreach h $hdrs { set_property file_type {Verilog Header} [get_files $h] }
set_property include_dirs [list "$fpga/rtl/gen" "$fpga/rtl/video" "$fpga/rtl/shared"] [current_fileset]

# ROM contents read with $readmemh / $readmemb (file names without a path)
foreach m [glob $fpga/mem/*.mem] {
    add_files -norecurse $m
    set_property file_type {Memory Initialization Files} [get_files $m]
}

# board constraints (pins copied from the Digilent Nexys-A7-100T-Master.xdc)
add_files -fileset constrs_1 -norecurse "$fpga/constraints/nexys_a7_100t.xdc"
set_property top nexys_a7_top [current_fileset]
update_compile_order -fileset sources_1

if {$mode eq "create"} { puts "Project created: $fpga/build/vivado/digi.xpr"; return }

launch_runs synth_1 -jobs 4
wait_on_run synth_1
open_run synth_1
report_utilization -file "$fpga/build/vivado/utilization_synth.txt"
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
open_run impl_1
report_utilization -file "$fpga/build/vivado/utilization_impl.txt"
report_timing_summary -file "$fpga/build/vivado/timing_impl.txt"
puts "Bitstream: [glob -nocomplain $fpga/build/vivado/digi.runs/impl_1/*.bit]"
