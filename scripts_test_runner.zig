const script_adversarial_detection_gate = @import("scripts/adversarial_detection_gate.zig");
const script_matrix_collect = @import("scripts/matrix_collect.zig");
const script_matrix_ga = @import("scripts/matrix_ga.zig");
const script_matrix_run = @import("scripts/matrix_run.zig");
const script_matrix_run_remote = @import("scripts/matrix_run_remote.zig");
const script_release_bundle = @import("scripts/release_bundle.zig");
const script_release_gate = @import("scripts/release_gate.zig");
const script_test_behavioral_matrix = @import("scripts/test_behavioral_matrix.zig");
const script_vm_check_prereqs = @import("scripts/vm/check_prereqs.zig");
const script_vm_create_linux = @import("scripts/vm/create_linux_vm.zig");
const script_vm_ga_collect_and_bundle = @import("scripts/vm/ga_collect_and_bundle.zig");
const script_vm_image_sources = @import("scripts/vm/image_sources.zig");
const script_vm_init_lab = @import("scripts/vm/init_lab.zig");
const script_vm_register_host = @import("scripts/vm/register_host.zig");
const script_vm_run_linux_matrix = @import("scripts/vm/run_linux_matrix.zig");
const script_vm_run_remote_matrix = @import("scripts/vm/run_remote_matrix.zig");
const script_vm_start_linux = @import("scripts/vm/start_linux.zig");
const script_vm_qemu_create = @import("scripts/vm_qemu_create.zig");
const script_vm_qemu_list = @import("scripts/vm_qemu_list.zig");
const script_vm_qemu_start = @import("scripts/vm_qemu_start.zig");

test "script entrypoint modules compile under zig build test" {
    _ = .{
        script_adversarial_detection_gate.main,
        script_matrix_collect.main,
        script_matrix_ga.main,
        script_matrix_run.main,
        script_matrix_run_remote.main,
        script_release_bundle.main,
        script_release_gate.main,
        script_test_behavioral_matrix.main,
        script_vm_check_prereqs.main,
        script_vm_create_linux.main,
        script_vm_ga_collect_and_bundle.main,
        script_vm_image_sources.main,
        script_vm_init_lab.main,
        script_vm_register_host.main,
        script_vm_run_linux_matrix.main,
        script_vm_run_remote_matrix.main,
        script_vm_start_linux.main,
        script_vm_qemu_create.main,
        script_vm_qemu_list.main,
        script_vm_qemu_start.main,
    };
}
