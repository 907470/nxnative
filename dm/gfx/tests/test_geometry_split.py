"""Run the production splitter with recursive draws reusing its caller's record."""
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

NVN = Path(__file__).resolve().parents[1] / 'nvn'


def split_source():
    source = (NVN / 'nvn_geometry.inc').read_text()
    start = source.index('static int geo_split(')
    at = source.index('{', start); depth = 1; end = at + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}'); end += 1
    return source[start:end]


HARNESS = r'''
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define MLOG(...) ((void)0)
#define MIN(a,b) ((a) < (b) ? (a) : (b))
#define MAX(a,b) ((a) > (b) ? (a) : (b))
typedef struct { int unused; } NvProg;
static struct { struct { int on; } restart; } S;
enum { GEO_RUN_PRIMS = 4096 };
static const uint64_t GEO_RUN_SPAN = 64ull << 20;
static int g_geo_split_depth;
static p_draw shared_draw;
static p_draw_idx shared_indexed;
static int primitive_count, instance_count, indexed, leaves;
static uint64_t original_indices;
static void geo_draw(NvProg *, const p_draw *, const p_draw_idx *);
__SPLITTER__
static void check(int condition, const char *what) {
    if (!condition) { fprintf(stderr, "split leaf %d: %s (indexed=%d, primitives=%d, instances=%d)\n", leaves, what, indexed, primitive_count, instance_count); exit(1); }
}
static void geo_draw(NvProg *pr, const p_draw *dw, const p_draw_idx *di) {
    // geo_prep reuses the same job for every child draw. Its copied descriptor
    // is also the parent's borrowed input: reproduce that ownership exactly.
    if (dw) shared_draw = *dw; else shared_indexed = *di;
    dw = dw ? &shared_draw : NULL; di = di ? &shared_indexed : NULL;
    int count = dw ? dw->count : di->count;
    if (count > 3 * GEO_RUN_PRIMS) {
        check(geo_split(pr, dw, di, count, 1, (uint32_t)(dw ? dw->base_instance : di->base_instance)), "recursive instance split refused");
        return;
    }
    int chunks = (primitive_count + GEO_RUN_PRIMS - 1) / GEO_RUN_PRIMS;
    int first = (leaves % chunks) * GEO_RUN_PRIMS;
    int expected = MIN(primitive_count - first, GEO_RUN_PRIMS) * 3;
    check(count == expected, "primitive count changed");
    check((dw ? dw->base_instance : di->base_instance) == 7 + leaves / chunks, "instance changed");
    check((dw ? dw->instances : di->instances) == 1, "instance count changed");
    if (di) {
        check(di->ibuf == original_indices + ((uint64_t)first * 3 << di->itype), "index base drifted after job reuse");
        check(di->base_vertex == -5, "base vertex changed");
    } else check(dw->first == 17 + first * 3, "first vertex drifted after job reuse");
    leaves++;
}
int main(void) {
    const int sizes[] = {2 * GEO_RUN_PRIMS + 7, 129032};
    for (unsigned s = 0; s < sizeof sizes / sizeof *sizes; s++) for (indexed = 0; indexed < 4; indexed++) for (instance_count = 1; instance_count <= 2; instance_count++) {
        primitive_count = sizes[s]; leaves = 0;
        int count = primitive_count * 3, type = indexed ? indexed - 1 : 0, bytes = 1 << type;
        uint8_t *indices = calloc((size_t)count * 8, (size_t)bytes);
        if (!indices) return 2;
        for (int i = 0; i < count * 8; i++) { uint32_t value = (uint32_t)(5 + i % 200); memcpy(indices + (size_t)i * bytes, &value, (size_t)bytes); }
        original_indices = (uint64_t)(uintptr_t)indices;
        shared_draw = (p_draw){.prim=4, .first=17, .count=count, .instances=instance_count, .base_instance=7};
        shared_indexed = (p_draw_idx){.prim=4, .itype=type, .count=count, .instances=instance_count, .base_instance=7, .base_vertex=-5, .ibuf=original_indices};
        check(geo_split(NULL, indexed ? NULL : &shared_draw, indexed ? &shared_indexed : NULL, count, instance_count, 7), "split refused");
        check(leaves == instance_count * ((primitive_count + GEO_RUN_PRIMS - 1) / GEO_RUN_PRIMS), "draws lost");
        check(g_geo_split_depth == 0, "split depth leaked");
        free(indices);
    }
    puts("geometry split: 16 recursive record-lifetime cases passed"); return 0;
}
'''


class GeometrySplit(unittest.TestCase):
    @unittest.skipUnless(shutil.which('clang'), 'requires a C compiler')
    def test_child_job_reuse_preserves_original_draw_range(self):
        types = (NVN / 'nvn_obj.h').read_text()
        records = []
        for name in ('p_draw', 'p_draw_idx'):
            match = re.search(r'typedef struct \{[^{}]*\} ' + name + r';', types)
            assert match is not None, name
            records.append(match[0])
        source = HARNESS.replace('static p_draw shared_draw;', '\n'.join(records) + '\nstatic p_draw shared_draw;').replace('__SPLITTER__', split_source())
        with tempfile.TemporaryDirectory() as td:
            c, binary = Path(td) / 'split.c', Path(td) / 'split'
            c.write_text(source)
            subprocess.run(['clang', '-std=c11', '-O1', '-Wall', '-Werror', str(c), '-o', str(binary)], check=True, capture_output=True)
            result = subprocess.run([str(binary)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
