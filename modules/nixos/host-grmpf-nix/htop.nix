{
  home-manager.users.grmpf.programs.htop = {
    enable = true;
    settings = {
      detailed_cpu_time = true;
      hide_userland_threads = true;
      highlight_base_name = true;
      show_cpu_frequency = true;
      show_program_path = false;
      column_meters_0 = [ "LeftCPUs" "Memory" "Swap" ];
      column_meters_1 = [ "RightCPUs" "Tasks" "LoadAverage" "Uptime" "NetworkIO" ];
      column_meter_modes_0 = [ 0 0 0 ];
      column_meter_modes_1 = [ 0 0 0 0 0 ];
      # column_meter_modes_2 = [ 0 0 0 0 0 ];
      "screen:I/O" = [ "PID" "USER" "IO_PRIORITY" "IO_RATE" "IO_READ_RATE" "IO_WRITE_RATE" "PERCENT_SWAP_DELAY" "PERCENT_IO_DELAY" "Command" ];
      "screen:Main" = [ "PID" "USER" "PRIORITY" "NICE" "M_VIRT" "M_RESIDENT" "M_SHARE" "STATE" "PERCENT_CPU" "PERCENT_MEM" "TIME" "Command" ];
    };
  };
}

