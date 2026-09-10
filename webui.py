import http.server
import socketserver
import sqlite3
import json
import urllib.parse
from pathlib import Path

PORT = 8080
DB_PATH = "scone.db"

HTML_CONTENT = """
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>SCONE WebUI</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <script src="https://unpkg.com/vue@3/dist/vue.global.js"></script>
    <link href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.0.0/css/all.min.css" rel="stylesheet">
</head>
<body class="bg-gray-900 text-gray-100 font-sans antialiased">
    <div id="app" class="container mx-auto p-6 max-w-6xl">
        <header class="flex justify-between items-center mb-8 border-b border-gray-700 pb-4">
            <div>
                <h1 class="text-4xl font-bold text-transparent bg-clip-text bg-gradient-to-r from-blue-400 to-purple-500">
                    <i class="fa-solid fa-bolt mr-2"></i>SCONE Explorer
                </h1>
                <p class="text-gray-400 mt-2">SIMD Superoptimizer Equivalence Database</p>
            </div>
            <div class="text-right flex gap-4">
                <div class="bg-gray-800 p-3 rounded-lg border border-gray-700 shadow-lg text-center min-w-[120px]">
                    <div class="text-sm text-gray-400 uppercase tracking-wider">Max Cost</div>
                    <div class="text-2xl font-bold text-blue-400">{{ metrics.max_cost }}</div>
                </div>
                <div class="bg-gray-800 p-3 rounded-lg border border-gray-700 shadow-lg text-center min-w-[120px]">
                    <div class="text-sm text-gray-400 uppercase tracking-wider">Classes</div>
                    <div class="text-2xl font-bold text-green-400">{{ metrics.total_classes }}</div>
                </div>
                <div class="bg-gray-800 p-3 rounded-lg border border-gray-700 shadow-lg text-center min-w-[120px]">
                    <div class="text-sm text-gray-400 uppercase tracking-wider">Counterexamples</div>
                    <div class="text-2xl font-bold text-purple-400">{{ metrics.total_ces }}</div>
                </div>
            </div>
        </header>

        <main>
            <div class="bg-gray-800 rounded-xl shadow-xl border border-gray-700 overflow-hidden flex flex-col h-[70vh]">
                <div class="p-4 bg-gray-800 border-b border-gray-700 flex justify-between items-center">
                    <h2 class="text-xl font-semibold"><i class="fa-solid fa-sitemap mr-2 text-blue-400"></i>Equivalence Classes</h2>
                    <div class="relative w-64">
                        <input type="text" v-model="searchQuery" @input="fetchClasses" placeholder="Search expressions..." class="w-full bg-gray-900 border border-gray-600 rounded-lg py-2 px-4 pl-10 text-sm focus:outline-none focus:border-blue-500 transition-colors">
                        <i class="fa-solid fa-search absolute left-3 top-2.5 text-gray-500"></i>
                    </div>
                </div>
                
                <div class="overflow-auto flex-1 p-0">
                    <table class="w-full text-left border-collapse">
                        <thead class="bg-gray-900 sticky top-0 z-10 shadow-md">
                            <tr>
                                <th class="p-4 font-semibold text-gray-300 w-24">Class ID</th>
                                <th class="p-4 font-semibold text-gray-300">Canonical Expression</th>
                                <th class="p-4 font-semibold text-gray-300 w-32">Hash High</th>
                                <th class="p-4 font-semibold text-gray-300 w-32">Hash Low</th>
                            </tr>
                        </thead>
                        <tbody class="divide-y divide-gray-700">
                            <tr v-for="cls in classes" :key="cls.id" class="hover:bg-gray-750 transition-colors group cursor-pointer" @click="toggleExpand(cls.id)">
                                <td class="p-4 font-mono text-gray-400">#{{ cls.id }}</td>
                                <td class="p-4">
                                    <div class="font-mono text-blue-300 bg-gray-900 px-3 py-1 rounded inline-block shadow-inner border border-gray-800">
                                        {{ formatExpr(cls.canonical) }}
                                    </div>
                                    
                                    <div v-if="expandedClass === cls.id" class="mt-4 p-4 bg-gray-900 rounded-lg border border-gray-700 shadow-inner">
                                        <h4 class="text-sm text-gray-400 mb-2 uppercase tracking-wider font-semibold">Equivalent Expressions</h4>
                                        <div class="flex flex-col gap-2 max-h-64 overflow-y-auto pr-2 custom-scrollbar">
                                            <div v-for="expr in cls.expressions" class="font-mono text-sm text-gray-300 bg-gray-800 px-3 py-1.5 rounded border border-gray-700 hover:border-gray-500 transition-colors">
                                                {{ formatExpr(expr) }}
                                            </div>
                                        </div>
                                    </div>
                                </td>
                                <td class="p-4 font-mono text-xs text-gray-500 truncate" :title="cls.hash_high">{{ cls.hash_high }}</td>
                                <td class="p-4 font-mono text-xs text-gray-500 truncate" :title="cls.hash_low">{{ cls.hash_low }}</td>
                            </tr>
                            <tr v-if="classes.length === 0">
                                <td colspan="4" class="p-12 text-center text-gray-500">
                                    <i class="fa-solid fa-ghost text-4xl mb-3 block opacity-50"></i>
                                    No classes found in database.
                                </td>
                            </tr>
                        </tbody>
                    </table>
                </div>
                
                <div class="p-3 bg-gray-900 border-t border-gray-700 flex justify-between items-center text-sm text-gray-400">
                    <div>Showing {{ classes.length }} results</div>
                    <div class="flex gap-2">
                        <button @click="page--" :disabled="page <= 1" class="px-3 py-1 bg-gray-800 rounded hover:bg-gray-700 disabled:opacity-50 transition-colors"><i class="fa-solid fa-chevron-left"></i></button>
                        <span class="px-3 py-1 font-mono">Page {{ page }}</span>
                        <button @click="page++" :disabled="classes.length < 50" class="px-3 py-1 bg-gray-800 rounded hover:bg-gray-700 disabled:opacity-50 transition-colors"><i class="fa-solid fa-chevron-right"></i></button>
                    </div>
                </div>
            </div>
        </main>
    </div>

    <style>
        .custom-scrollbar::-webkit-scrollbar { width: 6px; }
        .custom-scrollbar::-webkit-scrollbar-track { background: #1f2937; border-radius: 4px; }
        .custom-scrollbar::-webkit-scrollbar-thumb { background: #4b5563; border-radius: 4px; }
        .custom-scrollbar::-webkit-scrollbar-thumb:hover { background: #6b7280; }
        .hover\:bg-gray-750:hover { background-color: rgba(55, 65, 81, 0.5); }
    </style>

    <script>
        const { createApp } = Vue;

        createApp({
            data() {
                return {
                    metrics: { max_cost: 0, total_classes: 0, total_ces: 0 },
                    classes: [],
                    searchQuery: '',
                    page: 1,
                    expandedClass: null
                }
            },
            methods: {
                formatExpr(expr) {
                    if (!expr) return "unknown";
                    if (expr.tag === "variable") return ["x", "y", "z"][expr.c1] || "var";
                    if (expr.tag === "constant") return expr.c1.toString();
                    if (expr.tag === "unary") {
                        const ops = ["-", "~"];
                        return `(${ops[expr.c1]}${this.formatExpr(expr.left)})`;
                    }
                    if (expr.tag === "binary") {
                        const ops = ["+", "-", "*", "<<", ">>", "==", "<", "<=", "<s", "<=s", "&", "|", "^"];
                        return `(${this.formatExpr(expr.left)} ${ops[expr.c1]} ${this.formatExpr(expr.right)})`;
                    }
                    if (expr.tag === "select") {
                        return `(${this.formatExpr(expr.cond)} ? ${this.formatExpr(expr.left)} : ${this.formatExpr(expr.right)})`;
                    }
                    return "???";
                },
                async fetchMetrics() {
                    const res = await fetch('/api/metrics');
                    this.metrics = await res.json();
                },
                async fetchClasses() {
                    const res = await fetch(`/api/classes?q=${encodeURIComponent(this.searchQuery)}&page=${this.page}`);
                    this.classes = await res.json();
                },
                async toggleExpand(id) {
                    if (this.expandedClass === id) {
                        this.expandedClass = null;
                        return;
                    }
                    
                    // Find class
                    const cls = this.classes.find(c => c.id === id);
                    if (!cls.expressions) {
                        const res = await fetch(`/api/expressions?class_id=${id}`);
                        cls.expressions = await res.json();
                    }
                    this.expandedClass = id;
                }
            },
            watch: {
                page() { this.fetchClasses(); }
            },
            mounted() {
                this.fetchMetrics();
                this.fetchClasses();
                setInterval(this.fetchMetrics, 5000); // Poll metrics
            }
        }).mount('#app');
    </script>
</body>
</html>
"""

def build_ast(expr_id, expr_dict):
    if expr_id not in expr_dict: return None
    row = expr_dict[expr_id]
    expr = {"id": row['id'], "tag": row['tag'], "c1": row['c1']}
    if row['tag'] in ["unary", "binary", "select"]:
        expr["left"] = build_ast(row['c2'], expr_dict)
    if row['tag'] in ["binary", "select"]:
        expr["right"] = build_ast(row['c3'], expr_dict)
    if row['tag'] == "select":
        expr["cond"] = build_ast(row['c1'], expr_dict)
        expr["c1"] = 0 # No direct op for select
        expr["left"] = build_ast(row['c2'], expr_dict)
        expr["right"] = build_ast(row['c3'], expr_dict)
    return expr

class SconeUIHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        parsed_url = urllib.parse.urlparse(self.path)
        path = parsed_url.path
        query = dict(urllib.parse.parse_qsl(parsed_url.query))
        
        if not Path(DB_PATH).exists():
            self.send_response(500)
            self.end_headers()
            self.wfile.write(b"scone.db not found. Run SCONE first!")
            return

        try:
            conn = sqlite3.connect(DB_PATH)
            conn.row_factory = sqlite3.Row
            cursor = conn.cursor()

            if path == "/":
                self.send_response(200)
                self.send_header("Content-type", "text/html")
                self.end_headers()
                self.wfile.write(HTML_CONTENT.encode('utf-8'))
                
            elif path == "/api/metrics":
                max_cost = cursor.execute("SELECT value FROM meta WHERE key='max_cost'").fetchone()
                total_cls = cursor.execute("SELECT count(*) FROM classes").fetchone()
                total_ces = cursor.execute("SELECT count(*) FROM counterexamples").fetchone()
                
                self.send_response(200)
                self.send_header("Content-type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps({
                    "max_cost": max_cost[0] if max_cost else 0,
                    "total_classes": total_cls[0] if total_cls else 0,
                    "total_ces": total_ces[0] if total_ces else 0
                }).encode('utf-8'))

            elif path == "/api/classes":
                page = int(query.get('page', 1))
                offset = (page - 1) * 50
                
                classes = cursor.execute("SELECT * FROM classes LIMIT 50 OFFSET ?", (offset,)).fetchall()
                
                # We need all expressions referenced by these classes
                expr_ids = [c['canonical_expr_id'] for c in classes]
                
                # Fetch all expressions (we fetch everything for simplicity in this demo to build the trees)
                # In production, we'd do a recursive CTE, but fetching 50k rows in sqlite locally is instantaneous.
                all_exprs = cursor.execute("SELECT * FROM expressions").fetchall()
                expr_dict = {e['id']: dict(e) for e in all_exprs}
                
                results = []
                for cls in classes:
                    results.append({
                        "id": cls['id'],
                        "hash_high": str(cls['hash_high']),
                        "hash_low": str(cls['hash_low']),
                        "canonical": build_ast(cls['canonical_expr_id'], expr_dict)
                    })

                self.send_response(200)
                self.send_header("Content-type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps(results).encode('utf-8'))
                
            elif path == "/api/expressions":
                class_id = int(query.get('class_id', 0))
                
                all_exprs = cursor.execute("SELECT * FROM expressions").fetchall()
                expr_dict = {e['id']: dict(e) for e in all_exprs}
                
                # Find all expressions belonging to this class
                class_exprs = [e for e in all_exprs if e['class_id'] == class_id]
                
                results = []
                for e in class_exprs:
                    results.append(build_ast(e['id'], expr_dict))
                    
                self.send_response(200)
                self.send_header("Content-type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps(results).encode('utf-8'))

            else:
                self.send_response(404)
                self.end_headers()
                self.wfile.write(b"Not Found")
                
            conn.close()
        except Exception as e:
            self.send_response(500)
            self.end_headers()
            self.wfile.write(str(e).encode('utf-8'))

if __name__ == "__main__":
    with socketserver.TCPServer(("", PORT), SconeUIHandler) as httpd:
        print(f"SCONE WebUI running at http://localhost:{PORT}")
        httpd.serve_forever()
