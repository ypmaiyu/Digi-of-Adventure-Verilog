# program.tcl - download the bitstream to a Nexys A7 connected by USB (JTAG).
#   vivado -mode batch -source vivado/program.tcl
set fpga [file normalize "[file dirname [info script]]/.."]
set bit [lindex [glob $fpga/build/vivado/digi.runs/impl_1/*.bit] 0]
open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices xc7a100t*] 0]
current_hw_device $dev
set_property PROGRAM.FILE $bit $dev
program_hw_devices $dev
puts "Programmed $bit"
