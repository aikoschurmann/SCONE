const ast = @import("ast.zig");
const arena = @import("arena.zig");

pub fn is_pruned_depth1(op: ast.BinOp, e1: ast.ExprId, e2: ast.ExprId, c1: usize, c2: usize, expr_arena: *const arena.ExpressionArena) bool {
    const is_comm = op == .add or op == .mul or op == .and_op or op == .or_op or op == .xor or op == .eq;
    if (is_comm and c1 == c2 and e1 > e2) return true;
    
    const node1 = expr_arena.get(e1);
    const node2 = expr_arena.get(e2);
    
    const e1_is_0 = (node1 == .constant and node1.constant == 0);
    const e2_is_0 = (node2 == .constant and node2.constant == 0);
    const e1_is_1 = (node1 == .constant and node1.constant == 1);
    const e2_is_1 = (node2 == .constant and node2.constant == 1);
    
    if (e1 == e2) {
        if (op == .sub or op == .xor) return true; 
    }
    
    switch (op) {
        .add => if (e1_is_0 or e2_is_0) return true,
        .sub => if (e2_is_0) return true,
        .mul => if (e1_is_1 or e2_is_1) return true,
        else => {}
    }
    
    return false;
}
