const std = @import("std");

/// Centralized configuration for the SCONE Enumerator
/// Pruning Configuration
pub const use_pruning = false;

/// Evaluation Grid Configuration
/// These are the structured boundary values used to evaluate expressions.
/// Every combination (x, y, z) of these values will be tested.
pub const core_numbers = [_]u32{ 0, 1, 2, 3, 4, 8, 16, 31, 32 };
pub const bit_patterns = [_]u32{ 0xFFFF, 0x55555555, 0xAAAAAAAA };

pub const base_edge_cases = blk: {
    var cases: [core_numbers.len * 2 + bit_patterns.len + 3]u32 = undefined;
    var idx = 0;

    // 1. Core numbers
    for (core_numbers) |n| {
        cases[idx] = n;
        idx += 1;
    }

    // 2. Negative counterparts (two's complement -n)
    for (core_numbers) |n| {
        if (n != 0) {
            cases[idx] = 0 -% n;
            idx += 1;
        }
    }

    // 3. Integer boundaries
    const int_min: u32 = 0x80000000;
    const int_max: u32 = 0x7FFFFFFF;
    cases[idx] = int_min;
    idx += 1;
    cases[idx] = int_max;
    idx += 1;
    cases[idx] = int_min +% 1;
    idx += 1;
    cases[idx] = int_max -% 1;
    idx += 1;

    // 4. Bit patterns
    for (bit_patterns) |p| {
        cases[idx] = p;
        idx += 1;
    }

    break :blk cases[0..idx].*;
};

pub const num_edge_cases = base_edge_cases.len;
pub const edge_grid_samples = num_edge_cases * num_edge_cases * num_edge_cases;
pub const num_random_samples = edge_grid_samples; // 1:1 ratio of structured to random
pub const total_samples = edge_grid_samples + num_random_samples;

/// CEGIS Configuration
pub const counterexamples_file = "counterexamples.txt";
pub const verification_export_file = "classes.txt";
pub const max_classes_to_export = 50_000;

/// AST Generation Configuration
/// These are the 13 constants that form the base of the search space at Cost 0.
pub const search_constants = [_]u32{ 0, 1, 2, 3, 4, 8, 16, 31, 32, 0xFFFFFFFF, 0x80000000, 0x7FFFFFFF, 0xFFFF };
