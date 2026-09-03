import sys
import z3

# A simple recursive descent parser for the AST format
class Parser:
    def __init__(self, s):
        self.tokens = s.replace('(', ' ( ').replace(')', ' ) ').split()
        self.pos = 0

    def parse(self):
        token = self.tokens[self.pos]
        self.pos += 1
        if token == '(':
            # binary op is printed as (lhs op rhs)
            lhs = self.parse()
            op = self.tokens[self.pos]
            self.pos += 1
            rhs = self.parse()
            self.pos += 1 # skip ')'
            return (op, lhs, rhs)
        elif token.startswith('select('):
            pass
        elif token in ['neg', 'not', 'clz', 'ctz', 'popcount']:
            self.pos += 1 # skip '('
            expr = self.parse()
            self.pos += 1 # skip ')'
            return (token, expr)
        else:
            return token

def to_z3(ast, x, y, z):
    if isinstance(ast, tuple):
        if len(ast) == 3:
            op, lhs, rhs = ast
            l = to_z3(lhs, x, y, z)
            r = to_z3(rhs, x, y, z)
            if op == 'add': return l + r
            if op == 'sub': return l - r
            if op == 'mul': return l * r
            if op == 'and_op': return l & r
            if op == 'or_op': return l | r
            if op == 'xor': return l ^ r
            if op == 'shl': return l << (r & 31)
            if op == 'lshr': return z3.LShR(l, r & 31)
            if op == 'ashr': return l >> (r & 31)
            if op == 'ult': return z3.If(z3.ULT(l, r), z3.BitVecVal(1, 32), z3.BitVecVal(0, 32))
            if op == 'ule': return z3.If(z3.ULE(l, r), z3.BitVecVal(1, 32), z3.BitVecVal(0, 32))
            if op == 'slt': return z3.If(l < r, z3.BitVecVal(1, 32), z3.BitVecVal(0, 32))
            if op == 'sle': return z3.If(l <= r, z3.BitVecVal(1, 32), z3.BitVecVal(0, 32))
            if op == 'eq': return z3.If(l == r, z3.BitVecVal(1, 32), z3.BitVecVal(0, 32))
    else:
        if ast == 'x': return x
        if ast == 'y': return y
        if ast == 'z': return z
        if ast == 'INT_MIN': return z3.BitVecVal(-2147483648, 32)
        if ast == 'INT_MAX': return z3.BitVecVal(2147483647, 32)
        return z3.BitVecVal(int(ast), 32)

def check_class(class_id, exprs, ce_writer):
    if not exprs: return True
    x = z3.BitVec('x', 32)
    y = z3.BitVec('y', 32)
    z = z3.BitVec('z', 32)
    
    base_ast = Parser(exprs[0]).parse()
    base_z3 = to_z3(base_ast, x, y, z)
    
    for expr_str in exprs[1:]:
        ast = Parser(expr_str).parse()
        expr_z3 = to_z3(ast, x, y, z)
        
        solver = z3.Solver()
        # prove they are equal: search for a counterexample where they are NOT equal
        solver.add(base_z3 != expr_z3)
        if solver.check() == z3.sat:
            print(f"MISTAKE FOUND IN CLASS {class_id}!")
            print(f"Expr 1: {exprs[0]}")
            print(f"Expr 2: {expr_str}")
            m = solver.model()
            xv = m[x].as_signed_long() if m[x] is not None else 0
            yv = m[y].as_signed_long() if m[y] is not None else 0
            zv = m[z].as_signed_long() if m[z] is not None else 0
            print(f"Counterexample: [x = {xv}, y = {yv}, z = {zv}]")
            
            # Write to counterexamples.txt
            ce_writer.write(f"{xv},{yv},{zv}\n")
            return False
    return True

def main():
    classes = []
    current_class = None
    current_exprs = []

    try:
        with open('classes.txt') as f:
            for line in f:
                line = line.strip()
                if not line: continue
                if line.startswith('Class'):
                    if current_class is not None:
                        classes.append((current_class, current_exprs))
                    current_class = line.split(':')[0]
                    current_exprs = []
                else:
                    current_exprs.append(line)
        if current_class is not None:
            classes.append((current_class, current_exprs))
    except FileNotFoundError:
        print("classes.txt not found yet.")
        sys.exit(1)

    mistakes = 0
    with open('counterexamples.txt', 'a') as ce_writer:
        for cid, exprs in classes:
            if not check_class(cid, exprs, ce_writer):
                mistakes += 1

    print(f"Verified {len(classes)} classes. Mistakes found: {mistakes}")

if __name__ == '__main__':
    main()
