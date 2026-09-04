const std = @import("std");

pub var active: Config = .{};

pub const Config = struct {
    is_perf_mode: bool = false,
    use_pruning: bool = true,
    enable_unary: bool = true,
    enable_select: bool = true,
    use_cartesian_grid: bool = false,
    num_random_samples: usize = 4096,
    max_classes_to_export: usize = 50_000,
    max_classes_to_verify: usize = 500_000,
    max_counterexamples_per_iter: usize = 5000,
    z3_timeout_ms: u32 = 1000,
    
    out_dir: []const u8 = "out",
    counterexamples_file: []const u8 = "out/counterexamples.txt",
    telemetry_file: []const u8 = "out/telemetry.jsonl",
    verification_export_file: []const u8 = "out/classes.txt",
};

pub const chunk_size = 512;
pub const q_size = 131072;

pub const core_numbers = [_]u32{ 0, 1, 2, 3, 4, 8, 16, 31, 32 };
pub const bit_patterns = [_]u32{ 0xFFFF, 0x55555555, 0xAAAAAAAA };

pub const base_edge_cases = blk: {
    var cases: [core_numbers.len * 2 + bit_patterns.len + 3]u32 = undefined;
    var idx = 0;
    for (core_numbers) |n| { cases[idx] = n; idx += 1; }
    for (core_numbers) |n| { if (n != 0) { cases[idx] = 0 -% n; idx += 1; } }
    const int_min: u32 = 0x80000000;
    const int_max: u32 = 0x7FFFFFFF;
    cases[idx] = int_min; idx += 1;
    cases[idx] = int_max; idx += 1;
    cases[idx] = int_min +% 1; idx += 1;
    cases[idx] = int_max -% 1; idx += 1;
    for (bit_patterns) |p| { cases[idx] = p; idx += 1; }
    break :blk cases[0..idx].*;
};

pub const num_edge_cases = base_edge_cases.len;
pub const search_constants = [_]u32{ 0, 1, 2, 3, 4, 8, 16, 31, 32, 0xFFFFFFFF, 0x80000000, 0x7FFFFFFF, 0xFFFF };
