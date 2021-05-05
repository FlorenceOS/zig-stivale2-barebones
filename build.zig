const std = @import("std");
const Builder = std.build.Builder;

const sabaton = @import("extern/Sabaton/build.zig");

fn baremetal_target(exec: *std.build.LibExeObjStep, arch: std.builtin.Arch) void {
    var disabled_features = std.Target.Cpu.Feature.Set.empty;
    var enabled_feautres = std.Target.Cpu.Feature.Set.empty;

    switch(arch) {
        .x86_64 => {
            const features = std.Target.x86.Feature;
            disabled_features.addFeature(@enumToInt(features.mmx));
            disabled_features.addFeature(@enumToInt(features.sse));
            disabled_features.addFeature(@enumToInt(features.sse2));
            disabled_features.addFeature(@enumToInt(features.avx));
            disabled_features.addFeature(@enumToInt(features.avx2));

            enabled_feautres.addFeature(@enumToInt(features.soft_float));
            exec.code_model = .kernel;
        },
        .aarch64 => {
            const features = std.Target.aarch64.Feature;
            disabled_features.addFeature(@enumToInt(features.fp_armv8));
            disabled_features.addFeature(@enumToInt(features.crypto));
            disabled_features.addFeature(@enumToInt(features.neon));
            exec.code_model = .small;
        },
        else => unreachable,
    }

    exec.disable_stack_probing = true;
    exec.setTarget(.{
        .cpu_arch = arch,
        .os_tag = std.Target.Os.Tag.freestanding,
        .abi = std.Target.Abi.none,
        .cpu_features_sub = disabled_features,
        .cpu_features_add = enabled_feautres,
    });
}

fn stivale2_kernel(b: *Builder, arch: std.builtin.Arch) *std.build.LibExeObjStep {
    const kernel_filename = b.fmt("kernel_{s}.elf", .{@tagName(arch)});
    const kernel = b.addExecutable(kernel_filename, "stivale2.zig");

    kernel.addIncludeDir("extern/stivale/");
    kernel.setMainPkgPath(".");
    kernel.setOutputDir(b.cache_root);
    kernel.setBuildMode(.ReleaseSafe);
    kernel.install();

    baremetal_target(kernel, arch);
    kernel.setLinkerScriptPath("linker.ld");

    b.default_step.dependOn(&kernel.step);

    return kernel;
}

fn run_qemu_with_x86_bios_image(b: *Builder, image_path: []const u8) *std.build.RunStep {
    const cmd = &[_][]const u8 {
        "qemu-system-x86_64",
        "-cdrom", image_path,
        "-debugcon", "stdio",
        "-vga", "virtio",
        "-m", "4G",
        "-machine", "q35,accel=kvm:whpx:tcg",
    };

    const run_step = b.addSystemCommand(cmd);

    const run_command = b.step("run-x86_64-bios", "Run on x86_64 with Limine BIOS bootloader");
    run_command.dependOn(&run_step.step);

    return run_step;
}

fn run_qemu_with_x86_uefi_image(b: *Builder, image_path: []const u8) *std.build.RunStep {
    const cmd = &[_][]const u8 {
        "qemu-system-x86_64",
        "-cdrom", image_path,
        "-debugcon", "stdio",
        "-vga", "virtio",
        "-m", "4G",
        "-machine", "q35,accel=kvm:whpx:tcg",
        "-drive", b.fmt("if=pflash,format=raw,unit=0,file={s},readonly=on", .{std.os.getenv("OVMF_PATH").?}),
    };

    const run_step = b.addSystemCommand(cmd);

    const run_command = b.step("run-x86_64-uefi", "Run on x86_64 with Limine UEFI bootloader");
    run_command.dependOn(&run_step.step);

    return run_step;
}

fn run_qemu_with_sabaton(b: *Builder, kernel: *std.build.LibExeObjStep) *std.build.RunStep {
    const bootloader = sabaton.build_blob(b, .aarch64, "virt", "extern/Sabaton/") catch unreachable;

    const cmd = &[_][]const u8 {
        "qemu-system-aarch64",
        "-M", "virt,accel=kvm:whpx:tcg,gic-version=3",
        "-cpu", "cortex-a57",
        "-drive", b.fmt("if=pflash,format=raw,file={s},readonly=on", .{bootloader.output_path}),
        "-fw_cfg", b.fmt("opt/Sabaton/kernel,file={s}", .{kernel.getOutputPath()}),
        "-m", "4G",
        "-serial", "stdio",
        "-smp", "4",
        "-device", "ramfb",
    };

    const run_step = b.addSystemCommand(cmd);

    run_step.step.dependOn(&kernel.step);
    run_step.step.dependOn(&bootloader.step);

    const run_command = b.step("run-aarch64", "Run on aarch64 with Sabaton bootloader");
    run_command.dependOn(&run_step.step);

    return run_step;
}

fn build_limine_image(b: *Builder, kernel: *std.build.LibExeObjStep, image_path: []const u8) *std.build.RunStep {
    const img_dir = b.fmt("{s}/img_dir", .{b.cache_root});

    const cmd = &[_][]const u8 {
        "/bin/sh", "-c",
        std.mem.concat(b.allocator, u8, &[_][]const u8 {
            "rm ", image_path, " || true && ",
            "mkdir -p ", img_dir, "/EFI/BOOT && ",
            "cp ", kernel.getOutputPath(), " extern/limine/bin/limine{-eltorito-efi.bin,-cd.bin,.sys} limine.cfg ", img_dir, " && ",
            "cp extern/limine/bin/BOOTX64.EFI ", img_dir, "/EFI/BOOT/ && ",
            "make -C extern/limine && ",
            "xorriso ",
                "-as mkisofs ",
                "-b limine-cd.bin ",
                "-no-emul-boot -boot-load-size 4 -boot-info-table -eltorito-alt-boot ",
                "-e limine-eltorito-efi.bin ",
                img_dir, " -o ", image_path, " && ",
            "true"
        }) catch unreachable,
    };

    const image_step = b.addSystemCommand(cmd);
    image_step.step.dependOn(&kernel.step);
    b.default_step.dependOn(&image_step.step);

    const image_command = b.step("x86_64-universal-image", "Build the x86_64 universal (bios and uefi) image");
    image_command.dependOn(&image_step.step);

    return image_step;
}

fn build_x86(b: *Builder) void {
    const kernel = stivale2_kernel(b, .x86_64);
    const image_path = b.fmt("{s}/universal.iso", .{b.cache_root});
    const image = build_limine_image(b, kernel, image_path);

    const uefi_step = run_qemu_with_x86_uefi_image(b, image_path);
    uefi_step.step.dependOn(&image.step);

    const bios_step = run_qemu_with_x86_bios_image(b, image_path);
    bios_step.step.dependOn(&image.step);
}

pub fn build(b: *Builder) void {
    build_x86(b);

    // Just boots your kernel using sabaton, without a filesystem.
    _ = run_qemu_with_sabaton(b, stivale2_kernel(b, .aarch64));
}
