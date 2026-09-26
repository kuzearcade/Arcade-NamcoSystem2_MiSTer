#!/usr/bin/env python3
"""Generate rtl/ns2_m740.sv, the C68's M37450 (Mitsubishi 740) core, from
MAME's own instruction descriptions (NS2-9):

    tools/ns2_740gen.py [MAME_SRC] > rtl/ns2_m740.sv

MAME_SRC defaults to ~/mame/src. The 740's opcode table is
devices/cpu/m6502/dm740.lst (512 entries: the T flag selects the second
half), and its instructions are om740.lst over om6502.lst: C-like bodies in
which every bus call (read_pc, read, read_arg, read_data, read_dummy, write,
write_data, prefetch) is one cycle. MAME's m6502make.py turns them into C++
that stops at each bus call; this turns them into a Verilog state machine
that does the same: each state completes one bus cycle, then runs the body's
statements up to the next bus call (blocking assignments, so the statements
keep C's order within the cycle) and presents that call's address.
Expressions are evaluated as C does, in 32-bit signed ints, and truncated to
the variable's width on assignment. The helpers (do_adc, set_nz, ...) are
hand transcriptions of m6502.cpp's and m740.cpp's (HELPERS below).
"""
import os, re, sys

MAME = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser('~/mame/src')
CPU = os.path.join(MAME, 'devices/cpu/m6502')

# ------------------------------------------------------------------ input
def bodies(fn):
    d, cur = {}, None
    for line in open(fn):
        if line.startswith('#'):
            continue
        if not line.strip():
            cur = None
            continue
        if not line[0].isspace():
            cur = line.split()[0]
            d[cur] = []
        elif cur:
            t = line.split('//')[0].strip()
            if t:
                d[cur].append(t)
    return d

B = bodies(os.path.join(CPU, 'om6502.lst'))
B.update(bodies(os.path.join(CPU, 'om740.lst')))
TABLE = []
for line in open(os.path.join(CPU, 'dm740.lst')):
    if not line.startswith('#'):
        TABLE += line.split()
TABLE, RESET = TABLE[:512], TABLE[512]
assert len(TABLE) == 512 and RESET == 'reset_m', (len(TABLE), RESET)

# ------------------------------------------------------------------ statements
def parse(lines):
    """a body -> statements, handling "} else {" by restructuring"""
    # normalise "} else {" into "}" + "else {"
    norm = []
    for s in lines:
        if s.startswith('} else'):
            norm.append('}')
            norm.append(s[1:].strip())
        else:
            norm.append(s)
    stmts, i = parse_block2(norm, 0)
    assert i == len(norm), (i, norm)
    return stmts


def parse_block2(lines, i):
    out = []
    while i < len(lines):
        s = lines[i]
        if s == '}':
            return out, i + 1
        m = re.match(r'(if|while)\s*\((.*)\)\s*(\{?)$', s)
        if m or s.startswith('for(;;)'):
            kind = 'for' if s.startswith('for') else m.group(1)
            cond = None if kind == 'for' else m.group(2)
            if s.endswith('{'):
                body, i = parse_block2(lines, i + 1)
            else:
                body, i = [('s', lines[i + 1])], i + 2
            els = []
            if kind == 'if' and i < len(lines) and lines[i].startswith('else'):
                if lines[i] == 'else {':
                    els, i = parse_block2(lines, i + 1)
                elif lines[i] == 'else':
                    els, i = [('s', lines[i + 1])], i + 2
                else:
                    raise ValueError(lines[i])
            out.append((kind, cond, body, els))
            continue
        out.append(('s', s))
        i += 1
    return out, i

# ------------------------------------------------------------------ linear code
BUS = r'\b(read_pc|read_arg|read_data|read_dummy|read|write_data|write|prefetch)\s*\('

def linearize(stmts):
    code, n = [], [0]
    def lab():
        n[0] += 1
        return 'L%d' % n[0]
    def go(ss):
        for st in ss:
            if st[0] == 's':
                s = st[1]
                if re.search(BUS, s):
                    code.append(('B', s))
                elif s.startswith('eat-all-cycles'):
                    code.append(('EAT',))
                else:
                    code.append(('S', s))
            elif st[0] == 'if':
                l_else, l_end = lab(), lab()
                code.append(('IFNOT', st[1], l_else))
                go(st[2])
                code.append(('GOTO', l_end))
                code.append(('LABEL', l_else))
                go(st[3])
                code.append(('LABEL', l_end))
            elif st[0] == 'while':
                l_top, l_end = lab(), lab()
                code.append(('LABEL', l_top))
                code.append(('IFNOT', st[1], l_end))
                go(st[2])
                code.append(('GOTO', l_top))
                code.append(('LABEL', l_end))
            elif st[0] == 'for':
                l_top = lab()
                code.append(('LABEL', l_top))
                go(st[2])
                code.append(('GOTO', l_top))
    go(stmts)
    return code

# ------------------------------------------------------------------ expressions
TOK = re.compile(r'\s*(0x[0-9a-fA-F]+|\d+|[A-Za-z_]\w*|<<=|>>=|\+\+|--|<<|>>|<=|>=|==|!=|&&|\|\||[-+*/%&|^~!<>=?:(),]|\+=|-=|&=|\|=|\^=)')

def tokens(s):
    out, i = [], 0
    s = s.strip()
    while i < len(s):
        m = TOK.match(s, i)
        if not m:
            raise ValueError('token at %r' % s[i:])
        out.append(m.group(1))
        i = m.end()
    return out

WIDTH = {'m_A': 8, 'm_X': 8, 'm_Y': 8, 'm_P': 8, 'm_IR': 8, 'm_TMP2': 8,
         'm_PC': 16, 'm_SP': 16, 'm_TMP': 16, 'm_irq_vector': 16,
         'm_irq_state': 1, 'm_irq_taken': 1, 'm_inst_state_base': 9, 'DIN': 8}
VNAME = {'m_irq_state': 'irq', 'm_irq_vector': 'irq_vector'}
FLAGS = {'F_N': 0x80, 'F_V': 0x40, 'F_E': 0x20, 'F_T': 0x20, 'F_B': 0x10, 'F_D': 0x08,
         'F_I': 0x04, 'F_Z': 0x02, 'F_C': 0x01}
FUNCS = {'set_h', 'set_l', 'page_changing', 'uint8_t', 'int8_t', 'uint16_t', 'do_clb', 'do_seb', 'do_rrf'}

def vname(v):
    return VNAME.get(v, v[2:] if v.startswith('m_') else v)

class P:
    """precedence climbing over C's operators; emits 32-bit signed Verilog"""
    BIN = [('||',), ('&&',), ('|',), ('^',), ('&',), ('==', '!='), ('<', '>', '<=', '>='), ('<<', '>>'), ('+', '-'), ('*', '/', '%')]

    def __init__(self, toks):
        self.t, self.i = toks, 0

    def peek(self):
        return self.t[self.i] if self.i < len(self.t) else None

    def take(self, x=None):
        v = self.peek()
        if x is not None and v != x:
            raise ValueError('expected %s got %s in %s' % (x, v, ' '.join(self.t)))
        self.i += 1
        return v

    def expr(self):
        c = self.binary(0)
        if self.peek() == '?':
            self.take('?')
            a = self.expr()
            self.take(':')
            b = self.expr()
            return '(((%s) != 0) ? (%s) : (%s))' % (c, a, b)
        return c

    def binary(self, lvl):
        if lvl == len(self.BIN):
            return self.unary()
        a = self.binary(lvl + 1)
        while self.peek() in self.BIN[lvl]:
            op = self.take()
            b = self.binary(lvl + 1)
            if op in ('==', '!=', '<', '>', '<=', '>='):
                a = 'b2i((%s) %s (%s))' % (a, op, b)
            elif op == '&&':
                a = 'b2i(((%s) != 0) && ((%s) != 0))' % (a, b)
            elif op == '||':
                a = 'b2i(((%s) != 0) || ((%s) != 0))' % (a, b)
            elif op == '>>':
                a = '((%s) >>> (%s))' % (a, b)
            else:
                a = '((%s) %s (%s))' % (a, op, b)
        return a

    def unary(self):
        v = self.peek()
        if v == '-':
            self.take()
            return '(-(%s))' % self.unary()
        if v == '~':
            self.take()
            return '(~(%s))' % self.unary()
        if v == '!':
            self.take()
            return 'b2i((%s) == 0)' % self.unary()
        return self.primary()

    def primary(self):
        v = self.take()
        if v == '(':
            e = self.expr()
            self.take(')')
            return e
        if re.match(r'0x[0-9a-fA-F]+$|\d+$', v):
            return "32'sd%d" % int(v, 0)
        if v in FLAGS:
            return "32'sd%d" % FLAGS[v]
        if v in ('true', 'false'):
            return "32'sd%d" % (v == 'true')
        if v in FUNCS:
            self.take('(')
            args = [self.expr()]
            while self.peek() == ',':
                self.take(',')
                args.append(self.expr())
            self.take(')')
            f = {'uint8_t': 'u8', 'int8_t': 's8', 'uint16_t': 'u16'}.get(v, 'f_' + v)
            return '%s(%s)' % (f, ', '.join(args))
        if v in WIDTH:
            w = WIDTH[v]
            return "$signed({%d'd0, %s})" % (32 - w, vname(v))
        raise ValueError('unknown %s' % v)


def expr(s):
    p = P(tokens(s))
    e = p.expr()
    if p.i != len(p.t):
        raise ValueError('trailing in %s' % s)
    return e

# ------------------------------------------------------------------ statements -> Verilog
HELPER_STMT = {'set_nz', 'do_adc', 'do_sbc', 'do_adct', 'do_sbct', 'do_cmp', 'do_bit'}
HELPER_RET = {'do_asl', 'do_lsr', 'do_rol', 'do_ror'}

def split_args(s):
    """'a, b(c, d)' -> ['a', 'b(c, d)']"""
    out, depth, cur = [], 0, ''
    for ch in s:
        if ch == ',' and depth == 0:
            out.append(cur)
            cur = ''
            continue
        depth += ch == '('
        depth -= ch == ')'
        cur += ch
    out.append(cur)
    return [a.strip() for a in out]


def call_span(s, start):
    """s[start] is '(' -> index after the matching ')'"""
    depth = 0
    for i in range(start, len(s)):
        depth += s[i] == '('
        depth -= s[i] == ')'
        if depth == 0:
            return i + 1
    raise ValueError(s)


def stmt(s):
    """a statement without a bus call -> Verilog lines"""
    s = s.rstrip(';').strip()
    if not s or s.startswith('logerror') or s.startswith('standard_irq_callback') or s.startswith('m_inst_state ='):
        return []
    if s in ('dec_SP()', 'inc_SP()'):
        return ["SP = 16'(f_set_l($signed({16'd0, SP}), $signed({16'd0, SP}) %s 32'sd1));" % ('-' if s[0] == 'd' else '+')]
    m = re.match(r'(\w+)\((.*)\)$', s)
    if m and m.group(1) in HELPER_STMT:
        return ['%s(%s);' % (m.group(1), ', '.join(expr(a) for a in split_args(m.group(2))))]
    m = re.match(r'(m_\w+)\s*(\+\+|--)$', s)
    if m:
        v, w = m.group(1), WIDTH[m.group(1)]
        return ["%s = %d'($signed({%d'd0, %s}) %s 32'sd1);" % (vname(v), w, 32 - w, vname(v), m.group(2)[0])]
    m = re.match(r'(m_\w+)\s*(=|\+=|-=|\|=|&=|\^=|<<=|>>=)\s*(.*)$', s)
    if m:
        v, op, rhs = m.group(1), m.group(2), m.group(3)
        w = WIDTH[v]
        r = re.match(r'(\w+)\((.*)\)$', rhs)
        if r and r.group(1) in HELPER_RET:
            assert op == '='
            return ['%s(%s);' % (r.group(1), expr(r.group(2))), "%s = %d'(RET);" % (vname(v), w)]
        e = expr(rhs)
        if op != '=':
            o = op[:-1]
            e = "(($signed({%d'd0, %s})) %s (%s))" % (32 - w, vname(v), '>>>' if o == '>>' else o, e)
        return ["%s = %d'(%s);" % (vname(v), w, e)]
    raise ValueError('statement %r' % s)


def bus(s):
    """a statement with one bus call -> (issue lines, completion statement text, kind)"""
    m = re.search(BUS, s)
    f = m.group(1)
    op = m.end() - 1
    end = call_span(s, op)
    args = split_args(s[op + 1:end - 1]) if s[op + 1:end - 1].strip() else []
    rest = (s[:m.start()] + 'DIN' + s[end:]).strip()
    if f == 'prefetch':
        return ["addr = PC; wr = 1'b0; sync = 1'b1; tap = 1'b0;"], None, 'fetch'
    if f == 'read_pc':
        issue = ["addr = PC; wr = 1'b0; sync = 1'b0; tap = 1'b0;"]
    elif f in ('write', 'write_data'):
        issue = ["addr = 16'(%s); dout = 8'(%s); wr = 1'b1; sync = 1'b0; tap = 1'b1;" % (expr(args[0]), expr(args[1]))]
        rest = ''
    else:
        # read_arg goes through MAME's opcode cache, unseen by its taps
        issue = ["addr = 16'(%s); wr = 1'b0; sync = 1'b0; tap = 1'b%d;" % (expr(args[0]), f != 'read_arg')]
    if re.match(r'DIN\s*;?$', rest):
        rest = ''
    return issue, rest, 'bus'

# ------------------------------------------------------------------ code generation
class Gen:
    def __init__(self):
        self.states = []        # (name, completion text, body name, code, index)
        self.ids = {}

    def state(self, body, code, i):
        key = (body, i)
        if key not in self.ids:
            self.ids[key] = len(self.states)
            self.states.append(key)
        return self.ids[key]

    def run(self, body, code, i, ind, seen=()):
        """Verilog for executing code[i:] until a bus call on every path"""
        out = []
        labels = {c[1]: k for k, c in enumerate(code) if c[0] == 'LABEL'}
        while True:
            if i >= len(code):
                raise ValueError('%s falls off its end' % body)
            c = code[i]
            if c[0] == 'S':
                out += [ind + x for x in stmt(c[1])]
                i += 1
            elif c[0] == 'LABEL':
                i += 1
            elif c[0] == 'GOTO':
                i = labels[c[1]]
                if i in seen:
                    # a loop back to a bus call already emitted: continue it
                    pass
            elif c[0] == 'IFNOT':
                out.append(ind + "if ((%s) == 0) begin" % expr(c[1]))
                out += self.run(body, code, labels[c[2]], ind + '\t', seen)
                out.append(ind + 'end else begin')
                out += self.run(body, code, i + 1, ind + '\t', seen)
                out.append(ind + 'end')
                return out
            elif c[0] == 'EAT':
                # MAME burns the timeslice while waiting: wait a cycle, test again
                sid = self.state(body, code, ('eat', i))
                out.append(ind + "addr = PC; wr = 1'b0; sync = 1'b0; tap = 1'b0; st = %d;  // %s: wait" % (sid, body))
                return out
            elif c[0] == 'B':
                issue, rest, kind = bus(c[1])
                out += [ind + x for x in issue]
                if kind == 'fetch':
                    # statements after the prefetch run after its interrupt
                    # check (cli, sei, plp: the 6502's delayed I flag)
                    tail = [x for x in code[i + 1:] if x[0] == 'S' and stmt(x[1])]
                    if tail:
                        sid = self.state(body, code, ('fetch', i))
                        out.append(ind + 'st = %d;' % sid)
                    else:
                        out.append(ind + 'st = S_FETCH;')
                else:
                    sid = self.state(body, code, i)
                    out.append(ind + 'st = %d;' % sid)
                return out
            else:
                raise ValueError(c)

    def completion(self, body, code, i):
        """the state after bus call code[i]: its result, then on"""
        if isinstance(i, tuple) and i[0] == 'fetch':
            out = ['\t\t\t\tfetch_end;']
            for x in code[i[1] + 1:]:
                if x[0] == 'S':
                    out += ['\t\t\t\t' + y for y in stmt(x[1])]
            return out + ['\t\t\t\tdispatch;']
        if isinstance(i, tuple):
            # a wait loop: re-evaluate the loop from its top
            k = i[1]
            while code[k][0] != 'LABEL':
                k -= 1
            return self.run(body, code, k, '\t\t\t\t')
        issue, rest, kind = bus(code[i][1])
        out = []
        if rest:
            out += ['\t\t\t\t' + x for x in stmt(rest)]
        out += self.run(body, code, i + 1, '\t\t\t\t')
        return out


def main():
    g = Gen()
    code = {n: linearize(parse(B[n])) for n in set(TABLE) | {RESET}}
    entry = {n: g.run(n, code[n], 0, '\t\t\t\t\t') for n in set(TABLE) | {RESET}}
    # the states: generate completions until no new state appears
    done, comp = 0, []
    while done < len(g.states):
        body, i = g.states[done]
        comp.append(g.completion(body, code[body], i))
        done += 1
    w = sys.stdout.write
    w(HEADER)
    w("\tlocalparam S_FETCH = %d, S_RESET = %d;\n" % (len(g.states), len(g.states) + 1))
    w("\treg [%d:0] st;\n" % (max(10, (len(g.states) + 2).bit_length()) - 1))
    w(HELPERS)
    w("\t// the prefetch's end: the opcode, then MAME's prefetch_end (the interrupt check)\n")
    w("\ttask fetch_end;\n\t\tbegin\n")
    w("\t\t\tIR = DIN;\n")
    w("\t\t\tif (irq && !P[2]) begin irq_taken = 1'b1; IR = 8'h00; end\n")
    w("\t\t\telse PC = PC + 16'd1;\n")
    w("\t\tend\n\tendtask\n")
    w("\t// the next instruction: its statements up to its first bus call\n")
    w("\ttask dispatch;\n\t\tbegin\n")
    w("\t\t\tcase ({inst_state_base[8], IR})\n")
    for op in range(512):
        n = TABLE[op]
        w("\t\t\t9'h%03x: begin // %s\n" % (op, n))
        for line in entry[n]:
            w(line.replace('\t\t\t\t\t', '\t\t\t\t', 1) + '\n')
        w("\t\t\tend\n")
    w("\t\t\tendcase\n")
    w("\t\tend\n\tendtask\n\n")
    w("\talways @(posedge clk) begin\n")
    w("\t\tif (rst) begin\n")
    w("\t\t\tA = 8'h00; X = 8'h80; Y = 8'h00; P = 8'h36; SP = 16'h01ff; PC = 16'h0000; TMP = 16'h0000; TMP2 = 8'h00;\n")
    w("\t\t\tIR = 8'h00; inst_state_base = 9'd0; irq_taken = 1'b0; wr = 1'b0; sync = 1'b0; tap = 1'b0; dout = 8'h00;\n")
    w("\t\t\t// MAME's STATE_RESET: reset_m from its start\n")
    for line in entry[RESET]:
        w(line.replace('\t\t\t\t\t', '\t\t\t', 1) + '\n')
    w("\t\tend else if (cen) begin\n")
    w("\t\t\tDIN = din;\n")
    w("\t\t\tcase (st)\n")
    for k, (body, i) in enumerate(g.states):
        w("\t\t\t%d: begin // %s %s\n" % (k, body, i))
        for line in comp[k]:
            w(line + '\n')
        w("\t\t\tend\n")
    w("\t\t\tS_FETCH: begin\n")
    w("\t\t\t\tfetch_end;\n")
    w("\t\t\t\tdispatch;\n")
    w("\t\t\tend\n")
    w("\t\t\tdefault: st = S_FETCH;\n")
    w("\t\t\tendcase\n")
    w("\t\tend\n")
    w("\tend\n")
    w("endmodule\n")
    sys.stderr.write('%d states, %d opcodes, %d bodies\n' % (len(g.states), len(TABLE), len(set(TABLE))))


HEADER = """// GENERATED by tools/ns2_740gen.py from MAME's devices/cpu/m6502
// (dm740.lst, om740.lst, om6502.lst; BSD-3-Clause, Olivier Galibert):
// do not edit. The Mitsubishi 740 core of the C68's M37450, cycle for
// cycle as MAME's m740 (NS2-9).
//
// One bus cycle per cen: addr, wr, dout and sync (an opcode fetch) are the
// cycle's, set by the previous cen; din is sampled at cen, when a write
// also lands. irq is MAME's m_irq_state (any enabled request), irq_vector
// its m_irq_vector; both are sampled at the opcode fetch, as MAME's
// prefetch_end. On reset the registers take MAME's power-on values and the
// core runs reset_m (the vector at 0xfffe).
module ns2_m740 (
	input             clk,
	input             rst,
	input             cen,
	input             irq,
	input      [15:0] irq_vector,
	output reg [15:0] addr,
	output reg [7:0]  dout,
	output reg        wr,
	output reg        sync,
	output reg        tap,            // MAME's taps see this access (not read_pc, read_arg or a fetch)
	input      [7:0]  din
);
	// MAME's registers (blocking: the statements between two bus cycles run
	// in C's order within one clock)
	reg [7:0]  A, X, Y, P, IR, TMP2, DIN, RET;
	reg [15:0] PC, SP, TMP;
	reg [8:0]  inst_state_base;
	reg        irq_taken;
"""

HELPERS = r"""
	// ---------------------------------------------------------------- C
	function signed [31:0] b2i(input c); b2i = c ? 32'sd1 : 32'sd0; endfunction
	function signed [31:0] u8(input signed [31:0] v); u8 = {24'd0, v[7:0]}; endfunction
	function signed [31:0] s8(input signed [31:0] v); s8 = {{24{v[7]}}, v[7:0]}; endfunction
	function signed [31:0] u16(input signed [31:0] v); u16 = {16'd0, v[15:0]}; endfunction
	// m6502: set_h, set_l, page_changing (uint16_t base, int delta)
	function signed [31:0] f_set_h(input signed [31:0] v, input signed [31:0] h);
		f_set_h = {16'd0, h[7:0], v[7:0]};
	endfunction
	function signed [31:0] f_set_l(input signed [31:0] v, input signed [31:0] l);
		f_set_l = {16'd0, v[15:8], l[7:0]};
	endfunction
	function signed [31:0] f_page_changing(input signed [31:0] b, input signed [31:0] d);
		reg signed [31:0] s;
		begin s = {16'd0, b[15:0]} + d; f_page_changing = b2i(((s ^ {16'd0, b[15:0]}) & 32'sh0000ff00) != 0); end
	endfunction
	// m740: do_clb, do_seb, do_rrf
	function signed [31:0] f_do_clb(input signed [31:0] v, input signed [31:0] b);
		f_do_clb = {24'd0, v[7:0] & ~(8'd1 << b[2:0])};
	endfunction
	function signed [31:0] f_do_seb(input signed [31:0] v, input signed [31:0] b);
		f_do_seb = {24'd0, v[7:0] | (8'd1 << b[2:0])};
	endfunction
	function signed [31:0] f_do_rrf(input signed [31:0] v);
		f_do_rrf = {24'd0, v[3:0], v[7:4]};
	endfunction

	// ---------------------------------------------------------------- m6502.cpp
	task set_nz(input signed [31:0] v);
		begin
			P = P & ~8'h82;
			if (v[7]) P = P | 8'h80;
			if (v[7:0] == 0) P = P | 8'h02;
		end
	endtask
	task do_adc(input signed [31:0] vi);
		reg [7:0] val, al, ah; reg c; reg [15:0] sum;
		begin
			val = vi[7:0];
			if (P[3]) begin
				// do_adc_d
				c = P[0];
				P = P & ~8'hc3;
				al = (A & 8'd15) + (val & 8'd15) + {7'd0, c};
				if (al > 8'd9) al = al + 8'd6;
				ah = {4'd0, A[7:4]} + {4'd0, val[7:4]} + {7'd0, al > 8'd15};
				if (8'(A + val + {7'd0, c}) == 8'd0) P = P | 8'h02;
				else if (ah[3]) P = P | 8'h80;
				if ((~(A ^ val) & (A ^ (ah << 4)) & 8'h80) != 0) P = P | 8'h40;
				if (ah > 8'd9) ah = ah + 8'd6;
				if (ah > 8'd15) P = P | 8'h01;
				A = (ah << 4) | (al & 8'd15);
			end else begin
				// do_adc_nd
				sum = {8'd0, A} + {8'd0, val} + {15'd0, P[0]};
				P = P & ~8'hc3;
				if (sum[7:0] == 8'd0) P = P | 8'h02;
				else if (sum[7]) P = P | 8'h80;
				if ((~(A ^ val) & (A ^ sum[7:0]) & 8'h80) != 0) P = P | 8'h40;
				if (sum[15:8] != 0) P = P | 8'h01;
				A = sum[7:0];
			end
		end
	endtask
	task do_sbc(input signed [31:0] vi);
		reg [7:0] val, al, ah; reg c; reg [15:0] diff;
		begin
			val = vi[7:0];
			if (P[3]) begin
				// do_sbc_d
				c = !P[0];
				P = P & ~8'hc3;
				diff = {8'd0, A} - {8'd0, val} - {15'd0, c};
				al = (A & 8'd15) - (val & 8'd15) - {7'd0, c};
				ah = {4'd0, A[7:4]} - {4'd0, val[7:4]} - {7'd0, al[7]};
				if (diff[7:0] == 8'd0) P = P | 8'h02;
				else if (diff[7]) P = P | 8'h80;
				if (((A ^ val) & (A ^ diff[7:0]) & 8'h80) != 0) P = P | 8'h40;
				if (diff[15:8] == 0) P = P | 8'h01;
				if (al[7]) al = al - 8'd6;
				if (ah[7]) ah = ah - 8'd6;
				A = (ah << 4) | (al & 8'd15);
			end else begin
				// do_sbc_nd
				diff = {8'd0, A} - {8'd0, val} - {15'd0, !P[0]};
				P = P & ~8'hc3;
				if (diff[7:0] == 8'd0) P = P | 8'h02;
				else if (diff[7]) P = P | 8'h80;
				if (((A ^ val) & (A ^ diff[7:0]) & 8'h80) != 0) P = P | 8'h40;
				if (diff[15:8] == 0) P = P | 8'h01;
				A = diff[7:0];
			end
		end
	endtask
	task do_cmp(input signed [31:0] v1, input signed [31:0] v2);
		reg [15:0] r;
		begin
			P = P & ~8'h83;
			r = {8'd0, v1[7:0]} - {8'd0, v2[7:0]};
			if (r == 16'd0) P = P | 8'h02;
			else if (r[7]) P = P | 8'h80;
			if (r[15:8] == 0) P = P | 8'h01;
		end
	endtask
	task do_bit(input signed [31:0] vi);
		begin
			P = P & ~8'hc2;
			if ((A & vi[7:0]) == 8'd0) P = P | 8'h02;
			if (vi[7]) P = P | 8'h80;
			if (vi[6]) P = P | 8'h40;
		end
	endtask
	task do_asl(input signed [31:0] vi);
		begin
			P = P & ~8'h83;
			RET = {vi[6:0], 1'b0};
			if (RET == 0) P = P | 8'h02;
			else if (RET[7]) P = P | 8'h80;
			if (vi[7]) P = P | 8'h01;
		end
	endtask
	task do_lsr(input signed [31:0] vi);
		begin
			P = P & ~8'h83;
			if (vi[0]) P = P | 8'h01;
			RET = {1'b0, vi[7:1]};
			if (RET == 0) P = P | 8'h02;
		end
	endtask
	task do_ror(input signed [31:0] vi);
		reg c;
		begin
			c = P[0];
			P = P & ~8'h83;
			if (vi[0]) P = P | 8'h01;
			RET = {c, vi[7:1]};
			if (RET == 0) P = P | 8'h02;
			else if (RET[7]) P = P | 8'h80;
		end
	endtask
	task do_rol(input signed [31:0] vi);
		reg c;
		begin
			c = P[0];
			P = P & ~8'h83;
			if (vi[7]) P = P | 8'h01;
			RET = {vi[6:0], c};
			if (RET == 0) P = P | 8'h02;
			else if (RET[7]) P = P | 8'h80;
		end
	endtask

	// ---------------------------------------------------------------- m740.cpp: T mode on m_TMP
	task do_adct(input signed [31:0] vi);
		reg [7:0] val, t, al, ah; reg c; reg [15:0] sum;
		begin
			val = vi[7:0]; t = TMP[7:0];
			if (P[3]) begin
				// do_adc_dt
				c = P[0];
				P = P & ~8'hc3;
				al = (t & 8'd15) + (val & 8'd15) + {7'd0, c};
				if (al > 8'd9) al = al + 8'd6;
				ah = {4'd0, t[7:4]} + {4'd0, val[7:4]} + {7'd0, al > 8'd15};
				if (8'(t + val + {7'd0, c}) == 8'd0) P = P | 8'h02;
				else if (ah[3]) P = P | 8'h80;
				if ((~(t ^ val) & (t ^ (ah << 4)) & 8'h80) != 0) P = P | 8'h40;
				if (ah > 8'd9) ah = ah + 8'd6;
				if (ah > 8'd15) P = P | 8'h01;
				TMP = {8'd0, (ah << 4) | (al & 8'd15)};
			end else begin
				// do_adc_ndt
				sum = {8'd0, t} + {8'd0, val} + {15'd0, P[0]};
				P = P & ~8'hc3;
				if (sum[7:0] == 8'd0) P = P | 8'h02;
				else if (sum[7]) P = P | 8'h80;
				if ((~(t ^ val) & (t ^ sum[7:0]) & 8'h80) != 0) P = P | 8'h40;
				if (sum[15:8] != 0) P = P | 8'h01;
				TMP = sum;
			end
		end
	endtask
	task do_sbct(input signed [31:0] vi);
		reg [7:0] val, t, al, ah; reg c; reg [15:0] diff;
		begin
			val = vi[7:0]; t = TMP[7:0];
			if (P[3]) begin
				// do_sbc_dt (the 740's: al's adjust before ah)
				c = !P[0];
				P = P & ~8'hc3;
				diff = TMP - {8'd0, val} - {15'd0, c};
				al = (t & 8'd15) - (val & 8'd15) - {7'd0, c};
				if (al[7]) al = al - 8'd6;
				ah = {4'd0, t[7:4]} - {4'd0, val[7:4]} - {7'd0, al[7]};
				if (diff[7:0] == 8'd0) P = P | 8'h02;
				else if (diff[7]) P = P | 8'h80;
				if (((t ^ val) & (t ^ diff[7:0]) & 8'h80) != 0) P = P | 8'h40;
				if (diff[15:8] == 0) P = P | 8'h01;
				if (ah[7]) ah = ah - 8'd6;
				TMP = {8'd0, (ah << 4) | (al & 8'd15)};
			end else begin
				// do_sbc_ndt
				diff = TMP - {8'd0, val} - {15'd0, !P[0]};
				P = P & ~8'hc3;
				if (diff[7:0] == 8'd0) P = P | 8'h02;
				else if (diff[7]) P = P | 8'h80;
				if (((t ^ val) & (t ^ diff[7:0]) & 8'h80) != 0) P = P | 8'h40;
				if (diff[15:8] == 0) P = P | 8'h01;
				TMP = diff;
			end
		end
	endtask

"""

if __name__ == '__main__':
    main()
