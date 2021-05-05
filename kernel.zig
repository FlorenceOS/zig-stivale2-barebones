const std = @import("std");
const puts = @import("root").puts;

fn spin() noreturn {
    while(true) {
        switch(comptime(std.builtin.arch)) {
            .x86_64 => asm volatile("pause"),
            .aarch64 => asm volatile("yield"),
            else => { },
        }
    }
}

pub fn panic(msg: []const u8, trace: ?*std.builtin.StackTrace) noreturn {
    puts("PANIC!\n");
    puts(msg);
    spin();
}

pub fn kmain() noreturn {
    puts("Hello, world!\n");
    spin();
}
